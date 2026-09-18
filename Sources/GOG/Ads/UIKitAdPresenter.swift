#if canImport(UIKit) && !os(watchOS)
import UIKit
import QuartzCore   // CAShapeLayer/CATransaction; UIKit re-exports it, but say so rather than rely on it

/// The house-ad overlay.
///
/// ⚠️ **This is the one file in the package that has never been compiled.** Everything else
/// builds and is tested on Linux CI; UIKit exists only on an iOS target, so this file is
/// compiled for the first time by `xcodebuild -destination 'generic/platform=iOS'`. It is
/// deliberately written with only long-stable UIKit API and no clever layout, to keep that
/// first compile boring. If it fails, it fails alone and obviously.
///
/// Because it cannot be trusted until then, nothing else depends on it being correct: the
/// pipeline in `GogAds` bounds the presentation itself (see `withFailsafe`), so even a total
/// failure here cannot hang the game.
///
/// Behaviour mirrors `GogAdOverlay.cs` clause by clause:
/// - fullscreen creative, aspect-fit on black
/// - the close control appears only after `forcedViewSeconds`, with a countdown ring
/// - both clocks count FOREGROUND time only — see `ForegroundTimeline`
/// - a 90s failsafe tears the surface down and resolves `.shown`
/// - tapping the creative opens an http(s) `clickURL` and does NOT dismiss
/// - anything that goes wrong resolves `.noAd` rather than throwing or hanging (I7)
@MainActor
final class UIKitAdPresenter: AdPresenter {

    /// The live surface, so `teardown()` can reach it. At most one ad exists at a time — the
    /// pipeline's `inFlight` guard enforces that — so a single reference is the whole registry.
    private static var live: AdOverlayController?

    func present(imageData: Data, clickURL: URL?, forcedViewSeconds: Int) async -> GogAdOutcome {
        guard let image = UIImage(data: imageData) else {
            GogLog.warn("ad creative bytes could not be decoded as an image — noAd.")
            return .noAd
        }
        guard let host = Self.topViewController() else {
            GogLog.warn("no view controller available to present an interstitial — noAd.")
            return .noAd
        }

        return await withCheckedContinuation { continuation in
            let controller = AdOverlayController(image: image,
                                                 clickURL: clickURL,
                                                 forcedViewSeconds: max(0, forcedViewSeconds),
                                                 hostOrientations: host.supportedInterfaceOrientations) { outcome, controller in
                if Self.live === controller { Self.live = nil }
                continuation.resume(returning: outcome)
            }
            Self.live = controller
            controller.modalPresentationStyle = .fullScreen
            controller.modalTransitionStyle = .crossDissolve
            // .fullScreen is not interactively dismissible, so the forced view cannot be
            // swiped away. viewDidDisappear still guards the case anyway — see there.
            controller.isModalInPresentation = true
            host.present(controller, animated: true)
        }
    }

    /// Mirrors `GogAdOverlay.Teardown()`: safe when nothing is showing, safe twice, resolves
    /// a live ad as `.noAd`.
    ///
    /// Already on the main actor — the type is `@MainActor`, and an isolated `async` method is
    /// a legal witness for the protocol's nonisolated `async` requirement, so the caller hops
    /// here rather than this hopping itself.
    func teardown() async {
        let controller = Self.live
        Self.live = nil
        controller?.finish(.noAd)
    }

    /// The frontmost view controller of the foreground-active scene.
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first

        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene?.windows.first?.rootViewController else { return nil }

        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

@MainActor
private final class AdOverlayController: UIViewController {

    private let image: UIImage
    private let clickURL: URL?
    private let forcedViewSeconds: TimeInterval
    private let hostOrientations: UIInterfaceOrientationMask
    private let onFinish: @MainActor (GogAdOutcome, AdOverlayController) -> Void

    /// Foreground-only clocks, exactly as Android gates `Update()` on `_paused`. A player who
    /// taps the creative and reads the advertiser's page for a minute must come back to the
    /// same countdown they left, not to a dismissible ad they never watched — and must not
    /// trip the failsafe.
    private var timeline = ForegroundTimeline(startedAt: ProcessInfo.processInfo.systemUptime)
    private var ticker: Timer?

    private let closeControl = UIView()
    private let closeLabel = UILabel()
    private let ring = CAShapeLayer()

    /// The forced-view window has elapsed. **Only `true` here makes `.shown` truthful** —
    /// see `finish` and `viewDidDisappear`.
    private var closeReady = false
    /// Exactly-once (I2). Every exit — the close control, the failsafe, a dismissal, a
    /// teardown — routes through `finish`, which is idempotent on this.
    private var finished = false

    private static let tickInterval: TimeInterval = 1.0 / 30.0

    init(image: UIImage, clickURL: URL?, forcedViewSeconds: Int,
         hostOrientations: UIInterfaceOrientationMask,
         onFinish: @escaping @MainActor (GogAdOutcome, AdOverlayController) -> Void) {
        self.image = image
        self.clickURL = clickURL
        self.forcedViewSeconds = TimeInterval(forcedViewSeconds)
        self.hostOrientations = hostOrientations
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var prefersStatusBarHidden: Bool { true }

    /// 🔴 Inherit the game's orientations rather than allowing all of them.
    ///
    /// A fullscreen presented controller decides its own rotation, so returning `.all` lets the
    /// ad rotate to portrait inside a landscape-only game and snap back on dismissal. Android
    /// cannot have this bug — its overlay is a Canvas *inside* the game, so it always matches —
    /// and mirroring that behaviour means deferring to whoever presented us.
    ///
    /// Captured at init rather than read from `presentingViewController`, which is not yet set
    /// the first time UIKit asks.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { hostOrientations }

    // MARK: - Build

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)

        // A plain view rather than a UIButton: the button APIs for padding are either
        // deprecated (contentEdgeInsets) or iOS 15 configuration objects, and this file gets
        // exactly one chance to compile cleanly. 44pt is Apple's minimum touch target.
        closeControl.translatesAutoresizingMaskIntoConstraints = false
        closeControl.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        closeControl.layer.cornerRadius = 22
        closeControl.isAccessibilityElement = true
        closeControl.accessibilityTraits = .button
        view.addSubview(closeControl)

        closeLabel.translatesAutoresizingMaskIntoConstraints = false
        closeLabel.textColor = .white
        closeLabel.textAlignment = .center
        closeLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        closeControl.addSubview(closeLabel)

        // Countdown ring, mirroring Android's radial fill. Cosmetic: if it fails to draw, the
        // numeral still counts down and the control still becomes tappable on time.
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        ring.lineWidth = 2
        ring.lineCap = .round
        // Start at 12 o'clock and sweep clockwise, like the Unity Image fill.
        ring.path = UIBezierPath(arcCenter: CGPoint(x: 22, y: 22), radius: 20,
                                 startAngle: -.pi / 2, endAngle: 1.5 * .pi,
                                 clockwise: true).cgPath
        ring.strokeEnd = forcedViewSeconds > 0 ? 1 : 0
        closeControl.layer.addSublayer(ring)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            closeControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                              constant: 12),
            closeControl.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                                                   constant: -12),
            closeControl.widthAnchor.constraint(equalToConstant: 44),
            closeControl.heightAnchor.constraint(equalToConstant: 44),

            closeLabel.centerXAnchor.constraint(equalTo: closeControl.centerXAnchor),
            closeLabel.centerYAnchor.constraint(equalTo: closeControl.centerYAnchor),
        ])

        closeControl.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(closeTapped)))
        if clickURL != nil {
            imageView.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(creativeTapped)))
        }

        observeLifecycle()
        refreshCloseControl(elapsed: 0)
        startTicking()
    }

    // MARK: - Clocks

    /// The two notifications that bracket a real background transition. Polling
    /// `applicationState` from the ticker is not enough on its own: the ticker itself stops
    /// once the app is suspended, so the span has to be CLOSED at the moment of leaving or the
    /// whole away period gets counted on return.
    private func observeLifecycle() {
        let centre = NotificationCenter.default
        centre.addObserver(self, selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        centre.addObserver(self, selector: #selector(appWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        // Cover the (unlikely) case of being built while already backgrounded.
        if UIApplication.shared.applicationState == .background {
            timeline.enterBackground(at: ProcessInfo.processInfo.systemUptime)
        }
    }

    @objc private func appDidEnterBackground() {
        guard !finished else { return }
        timeline.enterBackground(at: ProcessInfo.processInfo.systemUptime)
        stopTicking()
    }

    @objc private func appWillEnterForeground() {
        guard !finished else { return }
        timeline.enterForeground(at: ProcessInfo.processInfo.systemUptime)
        startTicking()
    }

    private func startTicking() {
        guard ticker == nil, !finished else { return }
        // 🔴 `Timer(timeInterval:...)` then `add(forMode:)`, NOT `Timer.scheduledTimer` then
        // `add`. `scheduledTimer` already registers the timer on the current run loop in
        // `.default`; adding it again to `.common` — a mode SET that contains `.default` —
        // registers it a second time in that same mode, so it fires twice per interval. The
        // countdown survives it (elapsed comes from the timeline, not a tick count), but it is
        // double the work at 30fps for nothing, and it is the kind of thing that reads as
        // correct forever.
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` so the clock keeps running while a scroll view or menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard !finished else { return }
        let elapsed = timeline.elapsed(at: ProcessInfo.processInfo.systemUptime)

        if !closeReady { refreshCloseControl(elapsed: elapsed) }

        if elapsed >= GogAds.presentationFailsafeSeconds {
            GogLog.error(
                "the ad overlay hit its \(Int(GogAds.presentationFailsafeSeconds))s failsafe "
                + "and was torn down. The close control was never used, which usually means "
                + "touch input is not reaching it — check for a view or window presented above "
                + "the overlay.")
            // By 90s on screen the forced-view window (max 30s) has necessarily elapsed, so
            // the player did see the ad: .shown is the truthful outcome. Matches Android.
            closeReady = true
            finish(.shown)
        }
    }

    private func refreshCloseControl(elapsed: TimeInterval) {
        let remaining = forcedViewSeconds - elapsed
        if remaining > 0 {
            closeLabel.text = "\(Int(remaining.rounded(.up)))"
            closeControl.accessibilityLabel = "Ad closes in \(Int(remaining.rounded(.up))) seconds"
            // Disable implicit animation: at 30fps CALayer would smear every step.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.strokeEnd = max(0, min(1, remaining / forcedViewSeconds))
            CATransaction.commit()
        } else {
            closeReady = true
            closeLabel.text = "✕"
            closeControl.accessibilityLabel = "Close ad"
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ring.strokeEnd = 0
            CATransaction.commit()
        }
    }

    // MARK: - Input

    @objc private func creativeTapped() {
        guard !finished, let clickURL else { return }
        // Defence in depth. The admin API enforces https on write and the pipeline filters the
        // scheme before we ever see it; never hand an arbitrary scheme to the system anyway.
        let scheme = clickURL.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" else {
            GogLog.warn("ignoring a non-http(s) ad click URL.")
            return
        }
        // Tapping does NOT dismiss. `open` backgrounds the game; on return the ad should still
        // be there with its clock intact, and the player dismisses deliberately. Auto-dismiss
        // would drop them back into gameplay disoriented and make an accidental tap
        // destructive. Matches Android.
        UIApplication.shared.open(clickURL, options: [:], completionHandler: nil)
    }

    @objc private func closeTapped() {
        guard !finished, closeReady else { return }
        finish(.shown)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Covers a dismissal that did not come from the close control: the host tearing its
        // own presentation down, a scene disconnect, a `dismiss(animated:)` from game code.
        //
        // 🔴 The outcome is NOT unconditionally `.shown`. `.shown` is what gets counted as an
        // impression, and on Android the ONLY paths to it are the close control (which
        // requires `_closeReady`) and the 90s failsafe (which implies it) — so `.shown` there
        // always means the forced-view window elapsed. Reporting `.shown` for an ad that was
        // yanked off screen after 200ms would credit an impression nobody saw, and would do it
        // silently, in the direction that flatters us.
        finish(closeReady ? .shown : .noAd)
    }

    // MARK: - Exit

    /// The one exit. Idempotent, so a double-tap, a failsafe racing a close, or a shutdown
    /// racing either cannot double-deliver.
    fileprivate func finish(_ outcome: GogAdOutcome) {
        guard !finished else { return }
        finished = true                      // set BEFORE anything that could re-enter
        stopTicking()
        NotificationCenter.default.removeObserver(self)
        onFinish(outcome, self)
        if presentingViewController != nil { dismiss(animated: true) }
    }
}
#endif
