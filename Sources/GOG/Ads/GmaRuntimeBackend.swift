#if canImport(UIKit) && canImport(ObjectiveC) && !os(watchOS)
import UIKit
import ObjectiveC

/// The only file that touches Google Mobile Ads — `GmaInterstitial.kt`'s counterpart — and it
/// does so without importing it.
///
/// Android can compile against GMA and leave it out of the `.aar` (`compileOnly`). Swift has no
/// equivalent for a prebuilt XCFramework: importing GMA would make it a hard link-time
/// dependency of every game. So this drives the Objective-C surface by name, which has been
/// stable across GMA 10–12 (v12 renamed only the Swift names). Any piece of it that is missing
/// resolves as `.incompatible`, i.e. `exception:<type>` — a no-ad, never a crash.
///
/// ⚠️ **Never compiled on Linux**, and never exercised in `swift test`: the pipeline above it
/// (`GogAdmob.run`) is what the tests cover. First compiled by `xcodebuild` for iOS.
///
/// Threading: GMA documents that its completion handlers and full-screen delegate callbacks
/// arrive on the main thread. Every entry from GMA still goes through `onMain`, because a
/// Swift 6 main-actor assumption that turned out wrong would trap — inside somebody else's game.
@MainActor
final class GmaRuntimeBackend: AdmobBackend {

    static let shared = GmaRuntimeBackend()

    private var initStarted = false
    /// GMA holds its full-screen delegate WEAKLY (Android's callback object is strong), and
    /// expects the app to keep the ad alive while it is on screen. Both live here until the
    /// outcome is delivered. At most one interstitial is on screen at a time.
    private var live: (ad: NSObject, delegate: GmaFullScreenDelegate)?

    var isSDKPresent: Bool {
        NSClassFromString("GADMobileAds") != nil
            && NSClassFromString("GADInterstitialAd") != nil
            && NSClassFromString("GADRequest") != nil
    }

    var hasAppId: Bool {
        let id = Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String
        return !(id ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load(adUnitId: String, completion: @escaping @MainActor @Sendable (AdmobLoadOutcome) -> Void) {
        startIfNeeded()

        let selector = NSSelectorFromString("loadWithAdUnitID:request:completionHandler:")
        guard let adClass = NSClassFromString("GADInterstitialAd"),
              let requestClass = NSClassFromString("GADRequest") as? NSObject.Type,
              let method = class_getClassMethod(adClass, selector) else {
            GogLog.warn("Google Mobile Ads is present but has no "
                        + "+[GADInterstitialAd loadWithAdUnitID:request:completionHandler:] — noAd.")
            completion(.incompatible("NoSuchMethodError"))
            return
        }

        typealias LoadIMP = @convention(c) (
            AnyClass, Selector, NSString, NSObject,
            @escaping @convention(block) (NSObject?, NSError?) -> Void
        ) -> Void
        let loadIMP = unsafeBitCast(method_getImplementation(method), to: LoadIMP.self)

        loadIMP(adClass, selector, adUnitId as NSString, requestClass.init()) { @Sendable ad, error in
            onMain(UncheckedPair(ad, error)) { result in
                if let ad = result.first {
                    completion(.loaded(AdmobLoadedAd(handle: ad)))
                } else {
                    let error = result.second
                    completion(.failed(code: error?.code ?? -1,
                                       message: error?.localizedDescription ?? "no ad and no error"))
                }
            }
        }
    }

    func show(_ ad: AdmobLoadedAd, completion: @escaping @MainActor @Sendable (AdmobShowOutcome) -> Void) {
        guard let ad = ad.handle as? NSObject else {
            completion(.incompatible("ClassCastException"))
            return
        }
        let setDelegate = NSSelectorFromString("setFullScreenContentDelegate:")
        let present = NSSelectorFromString("presentFromRootViewController:")
        guard ad.responds(to: setDelegate), ad.responds(to: present) else {
            GogLog.warn("Google Mobile Ads interstitial has no fullScreenContentDelegate / "
                        + "presentFromRootViewController: — noAd.")
            completion(.incompatible("NoSuchMethodError"))
            return
        }
        guard let host = UIKitAdPresenter.topViewController() else {
            completion(.hostGone)
            return
        }

        let delegate = GmaFullScreenDelegate { [weak self] outcome in
            self?.live = nil
            completion(outcome)
        }
        live = (ad, delegate)
        _ = ad.perform(setDelegate, with: delegate)
        _ = ad.perform(present, with: host)
    }

    /// GMA queues a load behind its own initialization, so there is no need to wait — the same
    /// reasoning as `MobileAds.initialize(...) {}` on Android.
    private func startIfNeeded() {
        guard !initStarted else { return }
        initStarted = true
        let sharedInstance = NSSelectorFromString("sharedInstance")
        let start = NSSelectorFromString("startWithCompletionHandler:")
        guard let mobileAds = NSClassFromString("GADMobileAds") as AnyObject?,
              mobileAds.responds(to: sharedInstance),
              let instance = mobileAds.perform(sharedInstance)?.takeUnretainedValue(),
              instance.responds(to: start) else {
            GogLog.warn("Google Mobile Ads could not be started explicitly; relying on its "
                        + "lazy start on first load.")
            return
        }
        _ = instance.perform(start, with: nil)
    }
}

/// `GADFullScreenContentDelegate`, implemented by selector.
///
/// The protocol is adopted at runtime when GMA is loaded, so a `conformsToProtocol:` check on
/// GMA's side still passes; the three selectors are what it actually calls.
private final class GmaFullScreenDelegate: NSObject, @unchecked Sendable {

    // Main-thread only: every mutation happens inside an `onMain` hop.
    private var shown = false
    private var finished = false
    private let onFinish: @MainActor (AdmobShowOutcome) -> Void

    private static let adoptProtocol: Void = {
        if let proto = objc_getProtocol("GADFullScreenContentDelegate") {
            class_addProtocol(GmaFullScreenDelegate.self, proto)
        }
    }()

    init(onFinish: @escaping @MainActor (AdmobShowOutcome) -> Void) {
        _ = Self.adoptProtocol
        self.onFinish = onFinish
        super.init()
    }

    /// Android's `onAdShowedFullScreenContent`.
    @objc func adWillPresentFullScreenContent(_ ad: NSObject) {
        onMain(self) { $0.shown = true }
    }

    @objc func adDidDismissFullScreenContent(_ ad: NSObject) {
        onMain(self) { $0.finish(.dismissed(shown: $0.shown)) }
    }

    @objc(ad:didFailToPresentFullScreenContentWithError:)
    func adDidFailToPresent(_ ad: NSObject, error: NSError) {
        let failure = AdmobShowOutcome.failed(code: error.code, message: error.localizedDescription)
        onMain(self) { $0.finish(failure) }
    }

    @MainActor
    private func finish(_ outcome: AdmobShowOutcome) {
        guard !finished else { return }
        finished = true
        onFinish(outcome)
    }
}

private struct UncheckedPair<A, B>: @unchecked Sendable {
    let first: A
    let second: B
    init(_ first: A, _ second: B) { self.first = first; self.second = second }
}

/// Runs `body` on the main actor: inline when already there, otherwise hopped.
private func onMain<T>(_ value: T, _ body: @escaping @MainActor (T) -> Void) {
    let hop = UncheckedPair(value, body)
    if Thread.isMainThread {
        MainActor.assumeIsolated { hop.second(hop.first) }
    } else {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { hop.second(hop.first) }
        }
    }
}
#endif
