import XCTest
@testable import GOG

// ─────────────────────────────────────────────────────────────────────────────
// Doubles
// ─────────────────────────────────────────────────────────────────────────────

/// A presenter that never resolves on its own — the exact failure `withFailsafe` exists for.
/// Resolves `.noAd` if, and only if, someone calls `teardown()`, like the real overlay.
actor HangingPresenter: AdPresenter {
    private var continuation: CheckedContinuation<GogAdOutcome, Never>?
    private(set) var teardowns = 0
    private(set) var presents = 0

    func present(imageData: Data, clickURL: URL?, forcedViewSeconds: Int) async -> GogAdOutcome {
        presents += 1
        return await withCheckedContinuation { self.continuation = $0 }
    }

    func teardown() async {
        teardowns += 1
        let c = continuation
        continuation = nil
        c?.resume(returning: .noAd)
    }
}

/// A presenter that resolves immediately and counts teardowns, to prove the failsafe branch
/// did NOT run on the happy path.
actor PromptPresenter: AdPresenter {
    private(set) var teardowns = 0
    private(set) var lastClickURL: URL?
    private(set) var sawClickURLKey = false
    private var outcome: GogAdOutcome = .shown

    func setOutcome(_ o: GogAdOutcome) { outcome = o }

    func present(imageData: Data, clickURL: URL?, forcedViewSeconds: Int) async -> GogAdOutcome {
        lastClickURL = clickURL
        sawClickURLKey = true
        return outcome
    }

    func teardown() async { teardowns += 1 }
}

/// Foreground state under the test's control.
actor ScriptedForeground: ForegroundMonitor {
    private var value: Bool
    init(foreground: Bool) { value = foreground }
    func set(_ v: Bool) { value = v }
    func isForeground() async -> Bool { value }
}

private actor ResultBox<T: Sendable> {
    private var value: T?
    func set(_ v: T) { value = v }
    func get() -> T? { value }
}

/// Runs `work` unstructured and reports what it produced within `seconds`, or nil.
///
/// Deliberately not a `withTaskGroup` race: a group awaits its children at scope exit, so
/// against work that never finishes the helper itself would hang — and "this never finishes"
/// is precisely what half of these tests need to assert.
private func outcome<T: Sendable>(of work: @escaping @Sendable () async -> T,
                                  within seconds: TimeInterval) async -> T? {
    let box = ResultBox<T>()
    let task = Task { await box.set(await work()) }
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    let value = await box.get()
    task.cancel()
    return value
}

// ─────────────────────────────────────────────────────────────────────────────

final class AdFailsafeTests: XCTestCase {

    // MARK: - ForegroundTimeline (pure logic, the part the overlay cannot test)

    func testTimelineCountsOnlyForegroundTime() {
        var t = ForegroundTimeline(startedAt: 0)
        t.enterBackground(at: 10)          // 10s banked
        t.enterForeground(at: 100)         // 90s away, not counted
        XCTAssertEqual(t.elapsed(at: 105), 15, accuracy: 0.0001,
                       "10s on screen + 5s on screen; the 90s in Safari must not count")
    }

    func testTimelineIsIdempotentInBothDirections() {
        var t = ForegroundTimeline(startedAt: 0)
        t.enterBackground(at: 10)
        t.enterBackground(at: 50)          // a second didEnterBackground must not re-bank
        XCTAssertEqual(t.elapsed(at: 60), 10, accuracy: 0.0001)

        t.enterForeground(at: 60)
        t.enterForeground(at: 90)          // a second willEnterForeground must not restart
        XCTAssertEqual(t.elapsed(at: 100), 50, accuracy: 0.0001)
    }

    func testTimelineNeverGoesBackwards() {
        var t = ForegroundTimeline(startedAt: 100)
        XCTAssertEqual(t.elapsed(at: 50), 0, accuracy: 0.0001,
                       "a clock that jumped backwards must not produce negative elapsed time")
        t.enterBackground(at: 50)
        XCTAssertEqual(t.elapsed(at: 200), 0, accuracy: 0.0001,
                       "nor may it subtract from banked time")
    }

    /// The bug this whole mechanism prevents, stated as arithmetic: a player taps the ad at
    /// 5s, spends four minutes on the advertiser's page, comes back. Wall clock says 245s —
    /// well past both the 30s forced view and the 90s failsafe. Foreground time says 5s.
    @MainActor
    func testTappingThroughAndReadingForFourMinutesAdvancesNeitherClock() {
        var t = ForegroundTimeline(startedAt: 0)
        t.enterBackground(at: 5)
        t.enterForeground(at: 245)
        let elapsed = t.elapsed(at: 245)
        XCTAssertEqual(elapsed, 5, accuracy: 0.0001)
        XCTAssertLessThan(elapsed, 30, "the forced view must still have time left to run")
        XCTAssertLessThan(elapsed, GogAds.presentationFailsafeSeconds,
                          "and the failsafe must be nowhere near firing")
    }

    // MARK: - The constant itself

    @MainActor
    func testFailsafeBudgetMatchesAndroid() {
        // GogAdOverlay.cs: internal const float FailsafeMaxLifetimeSeconds = 90f;
        XCTAssertEqual(GogAds.presentationFailsafeSeconds, 90)
    }

    // MARK: - sleepForegroundSeconds

    func testForegroundSleepCompletesWhenOnScreen() async {
        let monitor = ScriptedForeground(foreground: true)
        let done = await outcome(of: { await sleepForegroundSeconds(0.15, monitor: monitor,
                                                                   tick: 0.01) },
                                 within: 2.0)
        XCTAssertEqual(done, true)
    }

    /// 🔴 Negative control for the test above. Same budget, same tick, same generous window —
    /// only the foreground state differs. If this ever returns non-nil the pause is not
    /// working, and the test above would be passing for the wrong reason.
    func testForegroundSleepDoesNotCompleteWhileBackgrounded() async {
        let monitor = ScriptedForeground(foreground: false)
        let done = await outcome(of: { await sleepForegroundSeconds(0.15, monitor: monitor,
                                                                   tick: 0.01) },
                                 within: 2.0)
        XCTAssertNil(done, "a backgrounded app must not accumulate forced-view or failsafe time")
    }

    // MARK: - The pipeline guard

    private static let creative = "https://cdn.example.com/ad.jpg"

    private static func house(clickURL: String = "null", forcedView: Int = 10) -> String {
        """
        {"type":"house","impression_id":"70f7c8c3-c601-445f-b718-d9209a75385c",
         "creative":{"id":"5cae7180-06bf-42c8-a556-0d55d2274894",
                     "image_url":"\(creative)","click_url":\(clickURL),
                     "forced_view_seconds":\(forcedView)},
         "expires_at":"2026-08-27T09:52:03.268Z","expires_in":300}
        """
    }

    private static func transport(_ directive: String) -> MockTransport {
        MockTransport { request, _ in
            if request.url.path.contains("/ads/next") {
                return (Data(directive.utf8), GogWireResponse(status: 200, headers: [:]))
            }
            return (Data(repeating: 0xFF, count: 128), GogWireResponse(status: 200, headers: [:]))
        }
    }

    @MainActor
    private static func ads(_ t: MockTransport, presenter: any AdPresenter,
                     foreground: ScriptedForeground = ScriptedForeground(foreground: true),
                     seconds: TimeInterval = 0.25, tick: TimeInterval = 0.01) -> GogAds {
        GogAds(configuration: TestSupport.configuration(), transport: t,
               indexStore: MemoryIndexStore(), presenter: presenter,
               foreground: foreground, failsafeSeconds: seconds, failsafeTick: tick)
    }

    /// 🔴 The hang, made impossible. Without `withFailsafe` this test does not fail — it
    /// never finishes, which is exactly what a player sees.
    func testAPresenterThatNeverResolvesStillReturnsToTheCaller() async throws {
        let presenter = HangingPresenter()
        let sut = await Self.ads(Self.transport(Self.house()), presenter: presenter)

        let result = await outcome(of: { try? await sut.showInterstitial() }, within: 3.0)
        XCTAssertEqual(result??.outcome, .shown,
                       "by 90s on screen the forced view has necessarily elapsed, so Android "
                       + "reports Shown and so must we")

        let teardowns = await presenter.teardowns
        XCTAssertEqual(teardowns, 1,
                       "resuming the caller without removing the surface leaves the game "
                       + "running under an ad whose close button now does nothing")
    }

    /// 🔴 Negative control for the test above, and the regression test for the version of the
    /// failsafe I nearly shipped: a plain `Task.sleep` would have fired here.
    ///
    /// Identical to the test above except that the player is away. The commonest reason an ad
    /// is on screen for minutes is that they TAPPED it and went to the advertiser's site —
    /// success, not a hang — and firing then both credits an impression early and rips the ad
    /// away on return.
    func testTheFailsafeDoesNotFireWhileThePlayerIsAway() async throws {
        let presenter = HangingPresenter()
        let away = ScriptedForeground(foreground: false)
        let sut = await Self.ads(Self.transport(Self.house()), presenter: presenter,
                                 foreground: away)

        // ONE call, watched across the transition. Deliberately not two: the second would be
        // refused by the in-flight guard while the first is still stuck, and the test would
        // then be measuring that guard instead of the failsafe.
        let box = ResultBox<GogAdOutcome>()
        let pending = Task {
            if let r = try? await sut.showInterstitial() { await box.set(r.outcome) }
        }
        defer { pending.cancel() }

        try? await Task.sleep(nanoseconds: 1_500_000_000)   // 6x the failsafe budget
        let early = await box.get()
        XCTAssertNil(early, "6x the failsafe budget in wall clock, none of it on screen")
        let teardownsWhileAway = await presenter.teardowns
        XCTAssertEqual(teardownsWhileAway, 0)

        // They come back. Now the clock runs and the guard does its job.
        await away.set(true)
        var resolved: GogAdOutcome?
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let v = await box.get() { resolved = v; break }
        }
        XCTAssertEqual(resolved, .shown,
                       "once on screen again, the failsafe must resolve the stuck ad")
        let teardowns = await presenter.teardowns
        XCTAssertEqual(teardowns, 1)
    }

    func testANormalPresentationNeverTearsDown() async throws {
        let presenter = PromptPresenter()
        let sut = await Self.ads(Self.transport(Self.house()), presenter: presenter)

        let result = try await sut.showInterstitial()
        XCTAssertEqual(result.outcome, .shown)
        // Give the failsafe arm several budgets' worth of wall clock to misfire in.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let teardowns = await presenter.teardowns
        XCTAssertEqual(teardowns, 0, "the failsafe arm must be cancelled by a normal resolution")
    }

    /// Android's `GogAdOverlay.Teardown()`. A shut-down SDK with a fullscreen ad still over the
    /// game is unreachable: the only thing that could have dismissed it was just torn down.
    func testShutdownRemovesALiveAdSurface() async throws {
        let presenter = HangingPresenter()
        let sut = await Self.ads(Self.transport(Self.house()), presenter: presenter, seconds: 600)

        let pending = Task { try? await sut.showInterstitial() }
        // Let the pipeline get as far as presenting.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let presents = await presenter.presents
        XCTAssertEqual(presents, 1)

        await sut.resetState()
        let resolved = await pending.value
        XCTAssertEqual(resolved?.outcome, .noAd,
                       "Android's Teardown resolves a live ad as NoAd")
    }

    // MARK: - Click-URL scheme validation

    func testANonHttpClickURLNeverReachesThePresenter() async throws {
        let presenter = PromptPresenter()
        let sut = await Self.ads(Self.transport(Self.house(clickURL: #""intent://evil/#Intent;end""#)),
                            presenter: presenter)

        let result = try await sut.showInterstitial()
        XCTAssertEqual(result.outcome, .shown, "a bad click target is not a reason to skip the ad")
        let seen = await presenter.lastClickURL
        XCTAssertNil(seen, "an arbitrary scheme must never reach UIApplication.open")
    }

    func testACustomSchemeClickURLIsAlsoStripped() async throws {
        let presenter = PromptPresenter()
        let sut = await Self.ads(Self.transport(Self.house(clickURL: #""gogapp://wallet/spend""#)),
                            presenter: presenter)

        _ = try await sut.showInterstitial()
        let seen = await presenter.lastClickURL
        XCTAssertNil(seen, "a creative must not be able to drive the SDK's own URL handler")
    }

    /// 🔴 Negative control for the two above: they would both pass if the filter dropped
    /// *every* click URL, which would silently kill click-through revenue on every house ad.
    func testAnHttpsClickURLIsPassedThroughUntouched() async throws {
        let presenter = PromptPresenter()
        let sut = await Self.ads(Self.transport(Self.house(clickURL: #""https://advertiser.example/x?a=1""#)),
                            presenter: presenter)

        _ = try await sut.showInterstitial()
        let seen = await presenter.lastClickURL
        XCTAssertEqual(seen?.absoluteString, "https://advertiser.example/x?a=1")
    }

    func testAPlainHttpClickURLIsAllowed() async throws {
        let presenter = PromptPresenter()
        let sut = await Self.ads(Self.transport(Self.house(clickURL: #""http://advertiser.example/x""#)),
                            presenter: presenter)

        _ = try await sut.showInterstitial()
        let seen = await presenter.lastClickURL
        XCTAssertEqual(seen?.absoluteString, "http://advertiser.example/x",
                       "Android allows http:// as well as https://; parity, not preference")
    }
}
