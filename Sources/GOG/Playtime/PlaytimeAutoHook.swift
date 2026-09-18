import Foundation

/// A stable per-install identifier for analytics.
///
/// A persisted UUID rather than `identifierForVendor`: the vendor id changes when the last
/// app from a vendor is deleted, which would silently split one player's history into two
/// devices. Not an advertising identifier and not linked to an account.
enum GogDeviceId {
    static let key = "com.gog.sdk.device_id"

    static func resolve(_ defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: key)
        return fresh
    }
}

#if canImport(UIKit)
import UIKit
// 🔴 REQUIRED for `InputObserverRecognizer` below, and easy to miss because nothing here
// hints at it. Apple: *"Subclasses of UIGestureRecognizer must import ... the
// UIKit.UIGestureRecognizerSubclass module (for Swift). This file declares all the methods
// and properties a subclass must either override, call, or reset."*
//
// `touchesBegan/Moved/Ended/Cancelled(_:with:)`, `pressesBegan(_:with:)` and `reset()` are
// declared in THAT module, not on the base class. Without this import all five overrides fail
// with "does not override any method from its superclass" — the whole input path, dead on the
// first Xcode build.
import UIKit.UIGestureRecognizerSubclass

/// Drives `GogPlaytime` from app lifecycle and input, so no game code participates —
/// matching Android, where `registerActivityLifecycleCallbacks` does the same job.
///
/// ⚠️ **Never compiled here.** UIKit exists only on an iOS target, so this file, like
/// `UIKitAdPresenter`, is first compiled by `xcodebuild -destination 'generic/platform=iOS'`.
/// Deliberately plain: notifications, one gesture recognizer, one timer.
@MainActor
final class PlaytimeAutoHook: NSObject, UIGestureRecognizerDelegate {

    private let playtime: GogPlaytime
    private var ticker: Timer?
    private var observers: [NSObjectProtocol] = []
    private weak var observedWindow: UIWindow?

    /// 🔴 Coalescing window for input. Android's `TouchTapCallback` ticks the meter once per
    /// dispatched event, on the same thread the meter lives on — its own comment insists that
    /// path "must stay trivial: it runs on the main thread inside the input path, potentially
    /// at the display refresh rate." Here the meter is behind an actor, so the same design
    /// would spawn a Task per event at 120Hz.
    ///
    /// So the per-event work stays two field writes, and the hop happens at most every 100ms
    /// carrying the exact batched count. The meter's `lastTouchMs` is then at most 100ms
    /// stale against a 40,000ms idle window — 0.25% — while `touches` stays exact.
    private static let inputCoalesceMs: Int64 = 100

    private var pendingInputs: Int64 = 0
    private var lastInputMs: Int64 = 0
    private var lastForwardedMs: Int64 = 0
    /// Tail of the serial chain of actor hops — see `forward`.
    private var forwardTask: Task<Void, Never>?

    init(playtime: GogPlaytime) {
        self.playtime = playtime
        super.init()
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forward { await $0.onForeground() } }
            // Re-attach: the key window can change (a new scene, a game that swaps windows),
            // and an observer on a window nobody is touching sees nothing. Android re-installs
            // on every onActivityResumed for the same reason, guarded by the same
            // already-installed check.
            MainActor.assumeIsolated { self?.attachInputObserver() }
        })

        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forward { await $0.onBackground() } } })

        attachInputObserver()

        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushInput()                      // any residue the coalescer is holding
                self.forward { await $0.tick() }       // ...and it lands BEFORE the tick
            }
        }

        // The app is already active when the SDK initialises, so the first foreground never
        // arrives as a notification.
        if UIApplication.shared.applicationState == .active {
            forward { await $0.onForeground() }
        }
    }

    func stop() {
        ticker?.invalidate(); ticker = nil
        forwardTask = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        detachInputObserver()
    }

    // MARK: - Input

    private func attachInputObserver() {
        guard let window = Self.keyWindow() else { return }
        guard window !== observedWindow else { return }   // same window, already observed

        // 🔴 Detach from the PREVIOUS window first. `didBecomeActive` fires on every return to
        // the foreground, and the key window can change between them — a new scene, or a game
        // that swaps windows. Without this the old window keeps its observer, still firing into
        // `self`, while the new one gets a second: every input counted twice, in a metric
        // nobody would think to sanity-check.
        detachInputObserver()

        // Idempotent by type as well, mirroring Android's `existing is TouchTapCallback` guard,
        // in case something else already attached one to this window.
        if !(window.gestureRecognizers ?? []).contains(where: { $0 is InputObserverRecognizer }) {
            let observer = InputObserverRecognizer { [weak self] in
                MainActor.assumeIsolated { self?.sawInput() }
            }
            observer.delegate = self
            window.addGestureRecognizer(observer)
        }
        observedWindow = window
    }

    private func detachInputObserver() {
        guard let window = observedWindow else { return }
        for recognizer in window.gestureRecognizers ?? []
        where recognizer is InputObserverRecognizer {
            window.removeGestureRecognizer(recognizer)
        }
        observedWindow = nil
    }

    /// Runs inside the input path. Keep it to field writes.
    ///
    /// 🔴 The timestamp comes from `playtime.clockMs`, never from a clock of this type's own.
    /// These values are handed straight to the meter, which also stamps `onForeground` /
    /// `onBackground` from that clock — two different sources would put `lastTouchMs` and
    /// `segmentStartMs` in different epochs, and the difference between wall-clock millis and
    /// uptime millis is five orders of magnitude. Every slice would blow past the server bounds
    /// and be dropped: playtime would record nothing at all, silently. Reading the one clock is
    /// what makes that unrepresentable.
    private func sawInput() {
        pendingInputs += 1
        lastInputMs = playtime.clockMs()
        if lastInputMs - lastForwardedMs >= Self.inputCoalesceMs { flushInput() }
    }

    private func flushInput() {
        guard pendingInputs > 0 else { return }
        let count = pendingInputs
        let at = lastInputMs
        pendingInputs = 0
        lastForwardedMs = at
        forward { await $0.onInput(count: count, atMs: at) }
    }

    /// 🔴 Every hop to the playtime actor goes through here, and they arrive IN ORDER.
    ///
    /// Independent `Task { }`s reach an actor in no particular order. That is fine for
    /// unrelated work and wrong for this: the meter's `settle` clamps a timestamp older than
    /// the open segment by rewinding the segment start, so a touch delivered after a later
    /// tick rewinds the accounting and re-credits an interval that was already banked. Two
    /// touch batches swapped are milder — `lastTouchMs` lands on the earlier one and the idle
    /// cutover fires early — but both are silent.
    ///
    /// Android never had to think about this: its meter is called from the main thread, so
    /// submission order IS execution order. Chaining each task on the previous one restores
    /// exactly that property.
    private func forward(_ work: @escaping @Sendable (GogPlaytime) async -> Void) {
        let previous = forwardTask
        forwardTask = Task { [playtime] in
            _ = await previous?.value
            await work(playtime)
        }
    }

    /// Observe alongside everything else; never win, never block.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}

/// Observes every input event and recognises nothing.
///
/// 🔴 **Why not `UITapGestureRecognizer`,** which is what this was. Android hooks
/// `Window.Callback.dispatchTouchEvent`, so it sees every event — including every single
/// `ACTION_MOVE` sample — and its `touches` counter is a count of *dispatches*. A tap
/// recognizer is a different thing entirely: it fires once per COMPLETED tap and not at all
/// during a drag. Two things broke as a result:
///
/// 1. **`touches` meant different things on the two platforms** while feeding the same
///    `engagement.playtime` column — dispatches on Android, completed taps on iOS, orders of
///    magnitude apart. iOS players would have read as far less engaged than they are.
/// 2. **Worse, a dragging player looked idle.** Someone panning a strategy map or holding a
///    slider never completes a tap, so nothing ticked the meter and the 40-second cutover
///    fired on a player whose finger was on the glass the whole time. That is active play
///    recorded as idle — the same class of silent mis-measurement as the cutover bug.
///
/// A recognizer that never leaves `.possible` recognises nothing, so it cannot cancel, delay
/// or consume the game's own input — it only observes. `pressesBegan` covers the controller
/// and keyboard path, which Android counts through `dispatchKeyEvent`.
private final class InputObserverRecognizer: UIGestureRecognizer {

    private let onEvent: @Sendable () -> Void

    init(onEvent: @escaping @Sendable () -> Void) {
        self.onEvent = onEvent
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    // One call per EVENT, not per touch point — `dispatchTouchEvent` is likewise one call per
    // MotionEvent however many pointers it carries.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { onEvent() }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { onEvent() }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { onEvent() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { onEvent() }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) { onEvent() }

    // `state` is never set, so this never recognises and UIKit resets it after each sequence.
    // Nothing calls `require(toFail:)` on it, so staying `.possible` is inert.
}
#endif
