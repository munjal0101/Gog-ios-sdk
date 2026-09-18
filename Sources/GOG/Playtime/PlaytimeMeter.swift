import Foundation

/// One metered slice of play, as a DELTA — never a running total.
///
/// Deltas are what the server ingests (`engagement.playtime`), and they are bounded there:
/// `active_ms` and `idle_ms` must each be a non-negative integer no greater than one hour.
/// The SDK banks roughly once a minute, so a legitimate slice is ~60s; the bound tolerates a
/// device dozing through its own timers while making "one event claims a week of play"
/// impossible.
struct PlaytimeDelta: Sendable, Equatable {
    let activeMs: Int64
    let idleMs: Int64
    let touches: Int64

    var isEmpty: Bool { activeMs == 0 && idleMs == 0 && touches == 0 }

    /// The server's own bound, applied here too. Sending a slice the server will reject is
    /// a silently lost measurement — it answers 4xx, which the uploader treats as delivered.
    static let maxSliceMs: Int64 = 60 * 60 * 1000
    var isWithinServerBounds: Bool {
        activeMs >= 0 && idleMs >= 0 && touches >= 0
            && activeMs <= Self.maxSliceMs && idleMs <= Self.maxSliceMs
    }
}

/// Accrues foreground time, split into ACTIVE and IDLE by whether the player has touched the
/// screen recently.
///
/// A direct port of the Android `PlaytimeMeter`, including the cutover arithmetic in
/// `settle`, because the two platforms must produce comparable numbers — an iOS meter that
/// counted idle time slightly differently would show up as a platform difference in the
/// engagement dashboards and be blamed on players rather than on the meter.
///
/// Pure and clock-injected: every millisecond comes in as a parameter, so the whole thing is
/// testable with no timers, no lifecycle, and no device.
struct PlaytimeMeter: Sendable {

    /// After this long without input, foreground time counts as IDLE rather than ACTIVE.
    static let idleTimeoutMs: Int64 = 40_000

    private let idleTimeout: Int64
    private var foreground = false
    private var idle = false
    private var segmentStartMs: Int64 = 0
    private var lastTouchMs: Int64 = 0
    private var activeMs: Int64 = 0
    private var idleMs: Int64 = 0
    private var touches: Int64 = 0

    init(idleTimeoutMs: Int64 = PlaytimeMeter.idleTimeoutMs) { self.idleTimeout = idleTimeoutMs }

    var isForeground: Bool { foreground }
    var isIdle: Bool { idle }

    mutating func onForeground(_ nowMs: Int64) {
        guard !foreground else { return }
        foreground = true
        idle = false
        segmentStartMs = nowMs
        lastTouchMs = nowMs
    }

    /// One or more input events observed at `nowMs`.
    ///
    /// `count` exists because iOS delivers input to an actor-isolated meter, so the hook
    /// coalesces a burst rather than paying an actor hop per event at the display refresh
    /// rate. The COUNT is still exact — batched, never sampled — because `touches` feeds the
    /// same engagement table as Android's, where every dispatch is counted individually.
    mutating func onTouch(_ nowMs: Int64, count: Int64 = 1) {
        guard foreground, count > 0 else { return }
        settle(nowMs)
        idle = false
        lastTouchMs = nowMs
        touches += count
    }

    mutating func onTick(_ nowMs: Int64) { settle(nowMs) }

    mutating func onBackground(_ nowMs: Int64) {
        guard foreground else { return }
        settle(nowMs)
        foreground = false
    }

    /// Take everything accrued so far and reset the counters. `nil` when nothing accrued —
    /// an empty delta is not worth an event.
    mutating func drain(_ nowMs: Int64) -> PlaytimeDelta? {
        settle(nowMs)
        let delta = PlaytimeDelta(activeMs: activeMs, idleMs: idleMs, touches: touches)
        activeMs = 0; idleMs = 0; touches = 0
        return delta.isEmpty ? nil : delta
    }

    /// Milliseconds until the active→idle cutover, or -1 when it does not apply. Drives the
    /// idle watchdog so the transition is recorded at the moment it happens rather than
    /// whenever the next tick lands.
    func msUntilIdle(_ nowMs: Int64) -> Int64 {
        guard foreground, !idle else { return -1 }
        let remaining = lastTouchMs + idleTimeout - nowMs
        return remaining > 0 ? remaining : 0
    }

    /// Advance the accrual to `nowMs`, splitting the segment at the idle cutover if it falls
    /// inside. The clock going BACKWARDS is handled by rebasing rather than accruing negative
    /// time.
    private mutating func settle(_ nowMs: Int64) {
        guard foreground else { return }
        guard nowMs > segmentStartMs else {
            if nowMs < segmentStartMs { segmentStartMs = nowMs }
            return
        }
        if idle {
            idleMs += nowMs - segmentStartMs
            segmentStartMs = nowMs
            return
        }
        let cutoverMs = lastTouchMs + idleTimeout
        if nowMs >= cutoverMs {
            if cutoverMs > segmentStartMs { activeMs += cutoverMs - segmentStartMs }
            idleMs += nowMs - max(cutoverMs, segmentStartMs)
            idle = true
        } else {
            activeMs += nowMs - segmentStartMs
        }
        segmentStartMs = nowMs
    }
}
