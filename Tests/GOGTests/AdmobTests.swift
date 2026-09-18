import XCTest
@testable import GOG

/// Scripted stand-in for Google Mobile Ads. Holds the completions it is handed so a test can
/// fire them late, twice, or never — the three shapes the real SDK can produce.
@MainActor
final class ScriptedAdmobBackend: AdmobBackend {
    var isSDKPresent = true
    var hasAppId = true

    enum LoadScript { case fill, fail(Int, String), incompatible(String), never }
    var loadScript: LoadScript = .fill
    var showScript: [AdmobShowOutcome] = [.dismissed(shown: true)]

    private(set) var loadedUnits: [String] = []
    private(set) var showCalls = 0
    private(set) var pendingLoad: (@MainActor @Sendable (AdmobLoadOutcome) -> Void)?

    func load(adUnitId: String, completion: @escaping @MainActor @Sendable (AdmobLoadOutcome) -> Void) {
        loadedUnits.append(adUnitId)
        switch loadScript {
        case .fill: completion(.loaded(AdmobLoadedAd(handle: NSObject())))
        case .fail(let code, let message): completion(.failed(code: code, message: message))
        case .incompatible(let type): completion(.incompatible(type))
        case .never: pendingLoad = completion
        }
    }

    func show(_ ad: AdmobLoadedAd, completion: @escaping @MainActor @Sendable (AdmobShowOutcome) -> Void) {
        showCalls += 1
        for outcome in showScript { completion(outcome) }
    }
}

/// Parity with `GogAdmob.kt` / `GmaInterstitial.kt` (android-core, a67616a): same guards, same
/// ordering, same reason tokens. Every outcome must arrive exactly once — a second resume of
/// the continuation would crash the test process, which is itself the assertion.
@MainActor
final class AdmobTests: XCTestCase {

    private func run(_ backend: ScriptedAdmobBackend, timeout: TimeInterval = 30) async -> GogAdmobResult {
        await GogAdmob.run(adUnitId: "ca-app-pub-3940256099942544/4411468910",
                           timeout: timeout, backend: backend)
    }

    func testMissingSdkIsNoAdAndNeverLoads() async {
        let backend = ScriptedAdmobBackend()
        backend.isSDKPresent = false
        let result = await run(backend)
        XCTAssertEqual(result, GogAdmobResult(shown: false, reason: "gma_missing"))
        XCTAssertTrue(backend.loadedUnits.isEmpty)
    }

    /// GMA terminates the app when started without GADApplicationIdentifier, so the guard must
    /// run before anything touches the SDK.
    func testMissingAppIdIsNoAdAndNeverLoads() async {
        let backend = ScriptedAdmobBackend()
        backend.hasAppId = false
        let result = await run(backend)
        XCTAssertEqual(result, GogAdmobResult(shown: false, reason: "app_id_missing"))
        XCTAssertTrue(backend.loadedUnits.isEmpty)
    }

    func testShownAdReportsShownWithEmptyReason() async {
        let backend = ScriptedAdmobBackend()
        let result = await run(backend)
        XCTAssertEqual(result, GogAdmobResult(shown: true, reason: ""))
        XCTAssertEqual(backend.loadedUnits, ["ca-app-pub-3940256099942544/4411468910"])
        XCTAssertEqual(backend.showCalls, 1)
    }

    func testLoadFailureCarriesCodeAndMessage() async {
        let backend = ScriptedAdmobBackend()
        backend.loadScript = .fail(1, "Request Error: No ad to show.")
        let result = await run(backend)
        XCTAssertEqual(result, GogAdmobResult(shown: false, reason: "load_failed:1 Request Error: No ad to show."))
        XCTAssertEqual(backend.showCalls, 0)
    }

    func testSlowFillResolvesAsLoadTimeout() async {
        let backend = ScriptedAdmobBackend()
        backend.loadScript = .never
        let result = await run(backend, timeout: 0.05)
        XCTAssertEqual(result, GogAdmobResult(shown: false, reason: "load_timeout"))
    }

    /// The game has already moved on; showing now would interrupt play.
    func testFillArrivingAfterTheTimeoutIsDroppedNotShown() async {
        let backend = ScriptedAdmobBackend()
        backend.loadScript = .never
        _ = await run(backend, timeout: 0.05)
        backend.pendingLoad?(.loaded(AdmobLoadedAd(handle: NSObject())))
        XCTAssertEqual(backend.showCalls, 0)
    }

    func testFillBeforeTheTimeoutIsNotAlsoReportedAsTimeout() async throws {
        let backend = ScriptedAdmobBackend()
        let result = await run(backend, timeout: 0.05)
        XCTAssertEqual(result.shown, true)
        // Outlive the timer: a late "load_timeout" would double-resume and crash here.
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    /// Dismissed without ever going full screen is not a credited impression.
    func testDismissedWithoutPresentingIsDismissedUnshown() async {
        let backend = ScriptedAdmobBackend()
        backend.showScript = [.dismissed(shown: false)]
        let result = await run(backend)
        XCTAssertEqual(result, GogAdmobResult(shown: false, reason: "dismissed_unshown"))
    }

    func testPresentationFailureCarriesCodeAndMessage() async {
        let backend = ScriptedAdmobBackend()
        backend.showScript = [.failed(code: 18, message: "Ad has already been used.")]
        let result = await run(backend)
        XCTAssertEqual(result, GogAdmobResult(shown: false, reason: "show_failed:18 Ad has already been used."))
    }

    /// Android's `activity_gone`: nothing on screen to present from. Same token, so the two
    /// platforms aggregate in one report.
    func testNoHostToPresentFromIsActivityGone() async {
        let backend = ScriptedAdmobBackend()
        backend.showScript = [.hostGone]
        let result = await run(backend)
        XCTAssertEqual(result, GogAdmobResult(shown: false, reason: "activity_gone"))
    }

    /// Android's catch-all `exception:<type>` — here, a GMA whose Objective-C surface no longer
    /// matches what the runtime lookup expects.
    func testIncompatibleSdkIsAnExceptionToken() async {
        let backend = ScriptedAdmobBackend()
        backend.loadScript = .incompatible("NoSuchMethodError")
        let result = await run(backend)
        XCTAssertEqual(result, GogAdmobResult(shown: false, reason: "exception:NoSuchMethodError"))
    }

    /// Load, timeout and dismiss can race; GMA can also report failure and dismissal for the
    /// same ad. The first outcome wins and the rest are ignored.
    func testOnlyTheFirstOutcomeIsDelivered() async {
        let backend = ScriptedAdmobBackend()
        backend.showScript = [.failed(code: 18, message: "Ad has already been used."),
                              .dismissed(shown: false)]
        let result = await run(backend)
        XCTAssertEqual(result.reason, "show_failed:18 Ad has already been used.")
    }

    /// Off-Apple builds (Linux CI) have no GMA at all: the public entry point must still
    /// answer rather than trap.
    func testPublicEntryPointAnswersWithoutGma() async {
        #if !canImport(UIKit)
        let result = await GogAdmob.showInterstitial(adUnitId: "unit", timeout: 1)
        XCTAssertEqual(result, GogAdmobResult(shown: false, reason: "gma_missing"))
        #endif
    }
}
