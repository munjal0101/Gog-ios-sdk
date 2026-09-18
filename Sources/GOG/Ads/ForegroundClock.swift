import Foundation

/// Is the host app on screen right now?
///
/// Exists so that "pause the clock while the player is away" is a decision this package can
/// make, test and reason about on any platform — including Linux CI, where there is no
/// application lifecycle at all.
///
/// `.inactive` (app switcher, incoming call, Control Centre pulled down) counts as
/// foreground. Only a real background counts as away, which is exactly where Android's
/// `OnApplicationPause(true)` fires.
protocol ForegroundMonitor: Sendable {
    func isForeground() async -> Bool
}

/// Everywhere without an application lifecycle. Always on screen.
struct AlwaysForeground: ForegroundMonitor {
    func isForeground() async -> Bool { true }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Reads `UIApplication.applicationState`.
///
/// Polled rather than notification-driven on purpose. A notification-driven version has to get
/// the ordering right across `didEnterBackground` / `willEnterForeground` / scene connection
/// and correctly handle arriving *already* backgrounded; a poll cannot be wrong about the
/// current state, and the failsafe it serves ticks at half a second, where the cost is nothing.
struct UIKitForegroundMonitor: ForegroundMonitor {
    func isForeground() async -> Bool {
        await MainActor.run { UIApplication.shared.applicationState != .background }
    }
}
#endif

/// Accumulates FOREGROUND time only.
///
/// Split out from both places that need it — the pipeline failsafe in `GogAds` and the
/// forced-view countdown in the overlay — because it is the one piece of that behaviour worth
/// testing, and one of those two files can never be compiled here.
///
/// Monotonic by construction: it only ever measures differences of a caller-supplied clock
/// that is `ProcessInfo.systemUptime` in production. A player who moves the wall clock cannot
/// shorten a forced view or trip a failsafe.
struct ForegroundTimeline {
    /// Foreground seconds banked from completed on-screen spans.
    private(set) var banked: TimeInterval = 0
    /// When the current on-screen span began, or nil while backgrounded.
    private(set) var spanStart: TimeInterval?

    init(startedAt: TimeInterval) { spanStart = startedAt }

    /// Foreground seconds so far.
    func elapsed(at now: TimeInterval) -> TimeInterval {
        guard let spanStart else { return banked }
        // max(0,) so a clock that goes backwards can never subtract banked time.
        return banked + max(0, now - spanStart)
    }

    /// The player left. Bank the open span and stop the clock.
    mutating func enterBackground(at now: TimeInterval) {
        guard let spanStart else { return }          // already backgrounded — idempotent
        banked += max(0, now - spanStart)
        self.spanStart = nil
    }

    /// The player came back. Start a new span.
    mutating func enterForeground(at now: TimeInterval) {
        guard spanStart == nil else { return }       // already foreground — idempotent
        spanStart = now
    }

    /// Fold `isForeground` in at `now`, whichever way it changed.
    mutating func observe(isForeground: Bool, at now: TimeInterval) {
        if isForeground { enterForeground(at: now) } else { enterBackground(at: now) }
    }
}

/// Suspend for `seconds` of FOREGROUND time, then return.
///
/// Returns early — and reports `false` — on cancellation.
///
/// Why not `Task.sleep`: the common way an ad is on screen for a long time is that the player
/// TAPPED it, went to Safari, and read something. A wall-clock failsafe punishes exactly the
/// engagement the ad exists to produce, and worse, fires while the overlay is still up: the
/// caller resumes, the game carries on, and a fullscreen ad is left orphaned over it.
@discardableResult
func sleepForegroundSeconds(_ seconds: TimeInterval,
                            monitor: any ForegroundMonitor,
                            tick: TimeInterval = 0.5,
                            monotonic: @Sendable () -> TimeInterval = {
                                ProcessInfo.processInfo.systemUptime
                            }) async -> Bool {
    guard seconds > 0 else { return true }
    var timeline = ForegroundTimeline(startedAt: monotonic())
    while true {
        do { try await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000)) }
        catch { return false }                       // cancelled
        if Task.isCancelled { return false }
        let now = monotonic()
        timeline.observe(isForeground: await monitor.isForeground(), at: now)
        if timeline.elapsed(at: now) >= seconds { return true }
    }
}
