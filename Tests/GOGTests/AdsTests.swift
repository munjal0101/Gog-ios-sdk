import XCTest
@testable import GOG

actor RecordingPresenter: AdPresenter {
    private(set) var calls = 0
    private(set) var lastForcedViewSeconds = -1
    private(set) var lastClickURL: URL?
    private(set) var lastBytes = 0
    private var outcome: GogAdOutcome = .shown

    func setOutcome(_ o: GogAdOutcome) { outcome = o }

    func present(imageData: Data, clickURL: URL?, forcedViewSeconds: Int) async -> GogAdOutcome {
        calls += 1
        lastForcedViewSeconds = forcedViewSeconds
        lastClickURL = clickURL
        lastBytes = imageData.count
        return outcome
    }
}

final class MemoryIndexStore: ImpressionIndexStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ seed: Int = 0) { value = seed }
    func load() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ v: Int) { lock.lock(); value = v; lock.unlock() }
    var current: Int { load() }
}

final class TestMonotonic: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1000
    var now: @Sendable () -> TimeInterval { { [self] in lock.lock(); defer { lock.unlock() }; return t } }
    func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
}

final class AdsTests: XCTestCase {

    private static let creativeURL = "https://cdn.example.com/ad.jpg"
    private static func house(expiresIn: Int = 300, expiresAt: String = "2026-08-27T09:52:03.268Z") -> String {
        """
        {"type":"house","impression_id":"70f7c8c3-c601-445f-b718-d9209a75385c",
         "creative":{"id":"5cae7180-06bf-42c8-a556-0d55d2274894",
                     "image_url":"\(creativeURL)","click_url":null,"forced_view_seconds":10},
         "expires_at":"\(expiresAt)","expires_in":\(expiresIn)}
        """
    }

    /// Serves the directive on the API host and image bytes anywhere else.
    private func transport(directive: String, status: Int = 200,
                           imageStatus: Int = 200) -> MockTransport {
        MockTransport { request, _ in
            if request.url.path.contains("/ads/next") {
                return (Data(directive.utf8), GogWireResponse(status: status, headers: [:]))
            }
            return (Data(repeating: 0xFF, count: 128), GogWireResponse(status: imageStatus, headers: [:]))
        }
    }

    @MainActor
    private func ads(_ t: MockTransport,
                     index: MemoryIndexStore = MemoryIndexStore(),
                     presenter: RecordingPresenter = RecordingPresenter(),
                     clock: TestMonotonic = TestMonotonic(),
                     userId: String? = nil) -> GogAds {
        GogAds(configuration: TestSupport.configuration(), transport: t,
               indexStore: index, presenter: presenter,
               currentUserId: { userId }, monotonic: clock.now)
    }

    // ─── URL construction ────────────────────────────────────────────────────
    // Pinned because the first cut appended the query to the PATH, and
    // `appendingPathComponent` percent-encodes `?` — producing /ads/next%3Fgame_id=…, a 404,
    // and therefore "no ads, ever" with no error anywhere.
    @MainActor
    func testDirectiveURLIsBuiltWithARealQueryString() async throws {
        let t = transport(directive: #"{"type":"none"}"#)
        _ = try await ads(t, userId: "user-123").showInterstitial()

        let urls = await t.urls
        let url = try XCTUnwrap(urls.first)
        XCTAssertEqual(url.path, "/ads/next")
        XCTAssertFalse(url.absoluteString.contains("%3F"), "the ? must be a real separator")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        XCTAssertEqual(byName["game_id"], TestSupport.gameId.uuidString.lowercased())
        XCTAssertEqual(byName["index"], "0")
        XCTAssertEqual(byName["user_id"], "user-123")
        XCTAssertNil(byName["trigger"])
    }

    @MainActor
    func testSignedOutPlayerSendsNoUserIdAndStillGetsAnAd() async throws {
        let t = transport(directive: Self.house())
        let result = try await ads(t, userId: nil).showInterstitial()
        XCTAssertEqual(result.outcome, .shown, "house ads must not require a signed-in session")
        let urls = await t.urls
        let url = try XCTUnwrap(urls.first)
        XCTAssertFalse(url.absoluteString.contains("user_id"))
    }

    @MainActor
    func testAutoShowOnOpenTagsTheTrigger() async throws {
        let t = transport(directive: #"{"type":"none"}"#)
        await ads(t).autoShowOnOpen()
        let urls = await t.urls
        let url = try XCTUnwrap(urls.first)
        XCTAssertTrue(url.absoluteString.contains("trigger=open"),
                      "the SERVER decides show_on_open; it needs the tag to do so")
    }

    @MainActor
    func testAdsRequestCarriesNoBearerToken() async throws {
        let t = transport(directive: #"{"type":"none"}"#)
        _ = try await ads(t).showInterstitial()
        let auths = await t.authorizations
        XCTAssertTrue(auths.isEmpty, "/ads/next is public; a token would put a refresh on the ad path")
    }

    // ─── directive outcomes ──────────────────────────────────────────────────
    @MainActor
    func testNoneIsASuccessfulNoAd() async throws {
        let result = try await ads(transport(directive: #"{"type":"none"}"#)).showInterstitial()
        XCTAssertEqual(result.outcome, .noAd)
    }

    /// I9 — forward tolerance. An unrecognised discriminator is designed evolution, not a fault.
    @MainActor
    func testUnknownDirectiveTypeResolvesToNoAd() async throws {
        let result = try await ads(transport(directive: #"{"type":"rewarded_video"}"#)).showInterstitial()
        XCTAssertEqual(result.outcome, .noAd)
    }

    @MainActor
    func testAdmobResolvesToNoAdInThisBuild() async throws {
        let result = try await ads(transport(directive: #"{"type":"admob","ad_unit_id":"ca-app-pub-x/y"}"#))
            .showInterstitial()
        XCTAssertEqual(result.outcome, .noAd)
    }

    @MainActor
    func testHouseDirectiveIsRendered() async throws {
        let presenter = RecordingPresenter()
        let result = try await ads(transport(directive: Self.house()), presenter: presenter)
            .showInterstitial()
        XCTAssertEqual(result.outcome, .shown)
        let calls = await presenter.calls
        let forced = await presenter.lastForcedViewSeconds
        let click = await presenter.lastClickURL
        let bytes = await presenter.lastBytes
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(forced, 10)
        XCTAssertNil(click, "click_url is null on the wire and must stay nil")
        XCTAssertEqual(bytes, 128)
    }

    // ─── 🔴 RULE 3 — errors are NEVER collapsed into NoAd ─────────────────────
    @MainActor
    func testDirectiveFetchFailureThrowsRatherThanReturningNoAd() async {
        let t = transport(directive: #"{"error":"internal error"}"#, status: 500)
        do {
            _ = try await ads(t).showInterstitial()
            XCTFail("a 500 must not look like 'no ad was eligible'")
        } catch let error as GogError {
            XCTAssertEqual(error, .server)
        } catch { XCTFail("wrong error type") }
    }

    @MainActor
    func testMalformedDirectiveThrows() async {
        // Discriminator says house; payload has no creative. That is a fault, not a decision.
        let t = transport(directive: #"{"type":"house","impression_id":"x","expires_in":300}"#)
        do {
            _ = try await ads(t).showInterstitial()
            XCTFail("a house directive with no creative must not resolve as noAd")
        } catch let error as GogError {
            guard case .malformedResponse = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("wrong error type") }
    }

    @MainActor
    func testNonJsonDirectiveThrows() async {
        do {
            _ = try await ads(transport(directive: "<html>gateway</html>")).showInterstitial()
            XCTFail("should have thrown")
        } catch let error as GogError {
            guard case .malformedResponse = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("wrong error type") }
    }

    /// But a creative that cannot be FETCHED is a presentation problem, not a fault (I7).
    @MainActor
    func testUnfetchableCreativeIsNoAdNotAnError() async throws {
        let t = transport(directive: Self.house(), imageStatus: 404)
        let result = try await ads(t).showInterstitial()
        XCTAssertEqual(result.outcome, .noAd)
    }

    // ─── 🔴 RULE 1 — monotonic TTL from expires_in ────────────────────────────
    @MainActor
    func testDirectiveExpiringBeforePresentationIsNoAd() async throws {
        let clock = TestMonotonic()
        let presenter = RecordingPresenter()
        let t = MockTransport { request, _ in
            if request.url.path.contains("/ads/next") {
                return (Data(Self.house(expiresIn: 5).utf8), GogWireResponse(status: 200, headers: [:]))
            }
            clock.advance(10)   // the creative fetch takes longer than the directive's life
            return (Data(repeating: 1, count: 8), GogWireResponse(status: 200, headers: [:]))
        }
        let result = try await ads(t, presenter: presenter, clock: clock).showInterstitial()
        XCTAssertEqual(result.outcome, .noAd)
        let calls = await presenter.calls
        XCTAssertEqual(calls, 0, "an expired directive must never reach the screen")
    }

    /// The rule that actually matters: a wildly wrong `expires_at` must not matter, because
    /// nothing reads it. A player with a forward-set device clock would otherwise see every
    /// directive pre-expired — zero ads, no error, unreproducible on your own device.
    @MainActor
    func testWallClockExpiresAtIsIgnoredEntirely() async throws {
        let longAgo = "1999-01-01T00:00:00.000Z"
        let t = transport(directive: Self.house(expiresIn: 300, expiresAt: longAgo))
        let result = try await ads(t).showInterstitial()
        XCTAssertEqual(result.outcome, .shown,
                       "expires_at is wall-clock and player-settable; only expires_in is read")
    }

    // ─── 🔴 RULE 2 — the impression index ────────────────────────────────────
    @MainActor
    func testIndexIncrementsPerOpportunityAndPersists() async throws {
        let store = MemoryIndexStore()
        let t = transport(directive: #"{"type":"none"}"#)
        let a = ads(t, index: store)
        for _ in 0..<3 { _ = try await a.showInterstitial() }

        let sent = await t.queryValues("index")
        XCTAssertEqual(sent, ["0", "1", "2"])
        XCTAssertEqual(store.current, 3, "the next slot is persisted, not held in memory")
    }

    /// Increments BEFORE the fetch. On success-only increment, a player on a flaky network
    /// replays the same index forever and sees one creative forever. A skipped creative is
    /// strictly better than a repeated one.
    @MainActor
    func testAFailedFetchStillConsumesTheSlot() async throws {
        let store = MemoryIndexStore()
        let t = transport(directive: #"{"error":"internal error"}"#, status: 500)
        _ = try? await ads(t, index: store).showInterstitial()
        XCTAssertEqual(store.current, 1)
    }

    @MainActor
    func testIndexSurvivesAcrossInstances() async throws {
        let store = MemoryIndexStore()
        let t = transport(directive: #"{"type":"none"}"#)
        _ = try await ads(t, index: store).showInterstitial()
        _ = try await ads(t, index: store).showInterstitial()   // "new process"
        let sent = await t.queryValues("index")
        XCTAssertEqual(sent, ["0", "1"])
    }

    func testCorruptedNegativeIndexRestartsAtZero() async {
        let store = MemoryIndexStore(-5)
        let slot = await AdImpressionIndex(store: store).next()
        XCTAssertEqual(slot, 0, "a negative index would be a 400 from the server")
        XCTAssertEqual(store.current, 1)
    }

    // ─── concurrency guard ───────────────────────────────────────────────────
    /// A rejected double-call must NOT consume an impression opportunity — hence the guard
    /// sits before the index increment.
    @MainActor
    func testConcurrentCallResolvesAsNoAdWithoutConsumingASlot() async throws {
        let store = MemoryIndexStore()
        let gate = TestMonotonic()   // reused only as a convenient shared object
        _ = gate
        let t = MockTransport { request, _ in
            if request.url.path.contains("/ads/next") {
                return (Data(Self.house().utf8), GogWireResponse(status: 200, headers: [:]))
            }
            return (Data(repeating: 2, count: 4), GogWireResponse(status: 200, headers: [:]))
        }
        let presenter = RecordingPresenter()
        let a = ads(t, index: store, presenter: presenter)

        // Two truly concurrent opportunities.
        async let first = a.showInterstitial()
        async let second = a.showInterstitial()
        let results = try await [first, second]

        let outcomes = results.map(\.outcome)
        XCTAssertEqual(outcomes.filter { $0 == .shown }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .noAd }.count, 1)
        XCTAssertEqual(store.current, 1, "the rejected call must not have consumed a slot")
        let calls = await presenter.calls
        XCTAssertEqual(calls, 1)
    }

    // ─── I8 ──────────────────────────────────────────────────────────────────
    /// impression_id must never cross the public surface. `GogAdResult` has exactly one
    /// member, so this is structural — the test pins that it stays so.
    @MainActor
    func testImpressionIdNeverReachesThePublicResult() async throws {
        let result = try await ads(transport(directive: Self.house())).showInterstitial()
        let mirror = Mirror(reflecting: result)
        XCTAssertEqual(mirror.children.compactMap(\.label), ["outcome"])
    }
}
