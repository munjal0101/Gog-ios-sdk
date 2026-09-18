import Foundation

/// AdMob interstitial entry point — the iOS twin of android-core's `GogAdmob`.
///
/// Google Mobile Ads is an OPTIONAL dependency of the game, not of this framework: the SDK is
/// shipped as one prebuilt XCFramework, so it cannot know at build time whether the game will
/// link GMA. It therefore never imports it. `GmaRuntimeBackend` probes for the SDK by class name
/// and drives it through the Objective-C runtime; a game built without GMA gets
/// `gma_missing`, never a crash (contract I7) — the same shape as Android's `compileOnly`
/// dependency plus `Class.forName` probe.
///
/// Parity notes, clause by clause with `GogAdmob.kt` / `GmaInterstitial.kt`:
/// - the SDK-presence and app-id guards run first, before anything touches GMA (GMA terminates
///   the app when started without `GADApplicationIdentifier`, as it does on Android without
///   `APPLICATION_ID`)
/// - `timeout` caps the LOAD only; once the ad is on screen the player closes it
/// - a fill that lands after the timeout is dropped, not shown
/// - the reason tokens are identical, so both platforms aggregate in one report
///
/// Not wired into `GogAds` yet, for the same reason it is not on Android: the Unity binding's
/// `GogAds` still resolves an `admob` directive to `noAd`. Wiring it is one call in each.
public enum GogAdmob {

    /// Load and show one interstitial for `adUnitId` over the frontmost view controller.
    ///
    /// Always returns, exactly once, whatever happens.
    @MainActor
    public static func showInterstitial(adUnitId: String, timeout: TimeInterval) async -> GogAdmobResult {
        await run(adUnitId: adUnitId, timeout: timeout, backend: defaultBackend())
    }

    @MainActor
    static func run(adUnitId: String,
                    timeout: TimeInterval,
                    backend: any AdmobBackend,
                    sleep: @escaping @Sendable (TimeInterval) async -> Void = GogAdmob.sleep) async -> GogAdmobResult {
        guard backend.isSDKPresent else { return GogAdmobResult(shown: false, reason: "gma_missing") }
        guard backend.hasAppId else { return GogAdmobResult(shown: false, reason: "app_id_missing") }

        return await withCheckedContinuation { continuation in
            let attempt = AdmobAttempt(continuation)
            let timer = Task { @MainActor in
                await sleep(timeout)
                guard !Task.isCancelled else { return }
                attempt.timedOut = true
                attempt.deliver(false, "load_timeout")
            }
            backend.load(adUnitId: adUnitId) { outcome in
                timer.cancel()
                // A fill that lands after the timeout is dropped: the game has already moved
                // on, and showing it now would interrupt play.
                guard !attempt.timedOut else { return }
                switch outcome {
                case .failed(let code, let message):
                    attempt.deliver(false, "load_failed:\(code) \(message)")
                case .incompatible(let type):
                    attempt.deliver(false, "exception:\(type)")
                case .loaded(let ad):
                    backend.show(ad) { shown in
                        switch shown {
                        case .dismissed(let shown):
                            attempt.deliver(shown, shown ? "" : "dismissed_unshown")
                        case .failed(let code, let message):
                            attempt.deliver(false, "show_failed:\(code) \(message)")
                        case .hostGone:
                            attempt.deliver(false, "activity_gone")
                        case .incompatible(let type):
                            attempt.deliver(false, "exception:\(type)")
                        }
                    }
                }
            }
        }
    }

    static let sleep: @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    @MainActor
    private static func defaultBackend() -> any AdmobBackend {
        #if canImport(UIKit) && canImport(ObjectiveC) && !os(watchOS)
        return GmaRuntimeBackend.shared
        #else
        return UnavailableAdmobBackend()
        #endif
    }
}

/// Outcome of one AdMob interstitial opportunity — Android's `GogAdmobCallback.onResult`.
public struct GogAdmobResult: Sendable, Equatable {
    /// True only when the ad actually went full screen and has since been dismissed.
    public let shown: Bool
    /// Empty on a shown ad; otherwise a stable token for logging — `gma_missing`,
    /// `app_id_missing`, `load_failed:<code> <message>`, `load_timeout`,
    /// `show_failed:<code> <message>`, `activity_gone`, `exception:<type>` — never
    /// player-facing copy.
    public let reason: String

    public init(shown: Bool, reason: String) {
        self.shown = shown
        self.reason = reason
    }
}

/// A loaded ad, opaque to everything but the backend that produced it.
struct AdmobLoadedAd: @unchecked Sendable {
    let handle: AnyObject
}

enum AdmobLoadOutcome: Sendable {
    case loaded(AdmobLoadedAd)
    case failed(code: Int, message: String)
    /// The SDK is present but does not have the shape this code drives — Android's
    /// `exception:<type>` from a `NoSuchMethodError`.
    case incompatible(String)
}

enum AdmobShowOutcome: Sendable {
    case dismissed(shown: Bool)
    case failed(code: Int, message: String)
    /// No view controller to present from — Android's `activity_gone`.
    case hostGone
    case incompatible(String)
}

/// The Google Mobile Ads seam. Everything above it — guards, ordering, the timeout race,
/// exactly-once delivery, the reason tokens — is compiled and tested on every platform.
@MainActor
protocol AdmobBackend: AnyObject, Sendable {
    var isSDKPresent: Bool { get }
    var hasAppId: Bool { get }
    func load(adUnitId: String, completion: @escaping @MainActor @Sendable (AdmobLoadOutcome) -> Void)
    func show(_ ad: AdmobLoadedAd, completion: @escaping @MainActor @Sendable (AdmobShowOutcome) -> Void)
}

/// Used where Google Mobile Ads cannot exist (Linux/CI, macOS).
@MainActor
final class UnavailableAdmobBackend: AdmobBackend {
    var isSDKPresent: Bool { false }
    var hasAppId: Bool { false }
    func load(adUnitId: String, completion: @escaping @MainActor @Sendable (AdmobLoadOutcome) -> Void) {
        completion(.incompatible("Unavailable"))
    }
    func show(_ ad: AdmobLoadedAd, completion: @escaping @MainActor @Sendable (AdmobShowOutcome) -> Void) {
        completion(.incompatible("Unavailable"))
    }
}

/// Exactly-once guard around the continuation — load, timeout and dismiss can race.
@MainActor
private final class AdmobAttempt {
    var timedOut = false
    private var continuation: CheckedContinuation<GogAdmobResult, Never>?

    init(_ continuation: CheckedContinuation<GogAdmobResult, Never>) {
        self.continuation = continuation
    }

    func deliver(_ shown: Bool, _ reason: String) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: GogAdmobResult(shown: shown, reason: reason))
    }
}
