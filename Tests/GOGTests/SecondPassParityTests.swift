import XCTest
@testable import GOG

/// The divergences found by reading ALL 34 Android implementation files rather than the ten
/// the earlier passes covered. Each test cites the Android source line it is matching, because
/// a test count proves nothing about parity — only the reading behind it does.
final class SecondPassParityTests: XCTestCase {

    private static let userId = "11111111-1111-4111-8111-111111111111"
    private static let exchangeOK = """
        {"access_token":"at","refresh_token":"rt","expires_at":1,"expires_in":3600,
         "token_type":"bearer","user":{"id":"\(userId)","email":"p@example.com"}}
        """

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: forced_view_seconds — optional, defaulted, clamped
    // GogAdDirective.cs:41-52, :161-168
    // ─────────────────────────────────────────────────────────────────────────

    private static func house(forcedView: String) -> String {
        let field = forcedView.isEmpty ? "" : ",\"forced_view_seconds\":\(forcedView)"
        return """
        {"type":"house","impression_id":"70f7c8c3-c601-445f-b718-d9209a75385c",
         "creative":{"id":"5cae7180-06bf-42c8-a556-0d55d2274894",
                     "image_url":"https://cdn.example.com/ad.jpg","click_url":null\(field)},
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
    private static func ads(_ t: MockTransport, presenter: RecordingPresenter) -> GogAds {
        GogAds(configuration: TestSupport.configuration(), transport: t,
               indexStore: MemoryIndexStore(), presenter: presenter)
    }

    private func forcedViewSeen(for wireValue: String) async throws -> Int {
        let presenter = RecordingPresenter()
        let sut = await Self.ads(Self.transport(Self.house(forcedView: wireValue)),
                                 presenter: presenter)
        let result = try await sut.showInterstitial()
        XCTAssertEqual(result.outcome, .shown, "the ad must still be servable")
        return await presenter.lastForcedViewSeconds
    }

    /// 🔴 Android parses the field as `int?` so that making the window dashboard-controllable
    /// is a pure backend change. A required field here turns a server that stops sending it
    /// into an ERROR — I9 read backwards.
    func testAMissingForcedViewFallsBackToTheDefaultRatherThanFailing() async throws {
        let seen = try await forcedViewSeen(for: "")
        XCTAssertEqual(seen, 4, "GogAdDirective.cs: DefaultImageForcedViewSeconds = 4f")
    }

    /// 🔴 The clamp is what makes the field safe to hand to an operator. Android:
    /// "a typo of 6000 cannot trap a player in an ad they are not allowed to dismiss."
    func testAnOperatorTypoCannotTrapThePlayer() async throws {
        let seen = try await forcedViewSeen(for: "6000")
        XCTAssertEqual(seen, 30, "GogAdDirective.cs: MaxForcedViewSeconds = 30f")
    }

    func testAZeroOrNegativeForcedViewIsRaisedToTheFloor() async throws {
        let zero = try await forcedViewSeen(for: "0")
        XCTAssertEqual(zero, 1, "GogAdDirective.cs: MinForcedViewSeconds = 1f")
        let negative = try await forcedViewSeen(for: "-5")
        XCTAssertEqual(negative, 1)
    }

    /// 🔴 Negative control for all three above: an in-range value must pass through UNTOUCHED.
    /// A clamp that pinned everything to 4, or to 30, would satisfy the others.
    func testAnInRangeForcedViewIsUsedVerbatim() async throws {
        let ten = try await forcedViewSeen(for: "10")
        let one = try await forcedViewSeen(for: "1")
        let thirty = try await forcedViewSeen(for: "30")
        XCTAssertEqual(ten, 10)
        XCTAssertEqual(one, 1)
        XCTAssertEqual(thirty, 30)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: the exchange retries once on a transient failure
    // GogAuthCore.kt:244-259 (exchangeWithSingleRetry)
    // ─────────────────────────────────────────────────────────────────────────

    private func identity(_ t: MockTransport,
                          now: @escaping @Sendable () -> Date = { Date() }) throws -> GogIdentity {
        try GogIdentity(configuration: TestSupport.configuration(),
                        store: InMemorySecureStore(), transport: t, webAuth: nil, now: now)
    }

    /// 🔴 My first cut set `idempotent: false`, reasoning that a single-use code makes a retry
    /// pointless. That is wrong in the case that matters: a connection error usually means the
    /// request never reached the server, so the code is untouched and the retry is the only
    /// thing standing between the player and a lost session.
    func testTheExchangeRetriesOnceWhenTheRequestNeverReachedTheServer() async throws {
        let t = MockTransport { _, attempt in
            if attempt == 0 { throw GogError.network(.transport("connection lost"), retryable: true) }
            return (Data(Self.exchangeOK.utf8), GogWireResponse(status: 200, headers: [:]))
        }
        let sut = try identity(t)

        let user = try await sut.signIn(code: "c", flow: .forwardLaunch)
        XCTAssertEqual(user.id, Self.userId)
        let calls = await t.callCount
        XCTAssertEqual(calls, 2, "one retry, exactly — GogAuthCore.exchangeWithSingleRetry")
    }

    /// 🔴 Negative control: the retry is for TRANSIENT failures only. A 401 means the code is
    /// spent; retrying it spends a round trip to learn what we already know.
    func testTheExchangeDoesNotRetryASpentCode() async throws {
        let t = MockTransport.fixed(401, #"{"error":"invalid or expired code"}"#)
        let sut = try identity(t)

        do {
            _ = try await sut.signIn(code: "c", flow: .forwardLaunch)
            XCTFail("a spent code must surface")
        } catch let error as GogError {
            XCTAssertEqual(error, .invalidOrExpiredCode)
        }
        let calls = await t.callCount
        XCTAssertEqual(calls, 1)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: a network blip must not become an auth failure
    // GogAuthCore.kt:283-288 — "NEVER sign out on a network blip"
    // ─────────────────────────────────────────────────────────────────────────

    /// Signs in with a short-lived token, moves the clock past the 80% refresh point but NOT
    /// past expiry, then fails the refresh transiently.
    private func signedInThenRefreshFails(
        expiresIn: Int, advance: TimeInterval
    ) async throws -> (GogIdentity, MockTransport) {
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let t = MockTransport { request, _ in
            if request.url.path.contains("/sso/exchange") {
                let body = """
                    {"access_token":"first","refresh_token":"rt","expires_at":1,
                     "expires_in":\(expiresIn),"token_type":"bearer",
                     "user":{"id":"\(Self.userId)","email":"p@example.com"}}
                    """
                return (Data(body.utf8), GogWireResponse(status: 200, headers: [:]))
            }
            throw GogError.network(.transport("offline"), retryable: true)
        }
        let sut = try identity(t, now: clock.now)
        _ = try await sut.signIn(code: "c", flow: .forwardLaunch)
        clock.advance(by: advance)
        return (sut, t)
    }

    func testATransientRefreshFailureKeepsServingAStillValidToken() async throws {
        // 1000s token: refresh is due at 800s, expiry at 1000s. 900s is between them.
        let (sut, _) = try await signedInThenRefreshFails(expiresIn: 1000, advance: 900)

        let snapshot = try await sut.snapshot()
        XCTAssertEqual(snapshot.accessToken, "first",
                       "the token the player already holds is still good; a blip must not "
                       + "turn into an auth error")

        let session = await sut.currentSession
        XCTAssertTrue(session.isSignedIn, "and must never sign them out")
    }

    /// 🔴 Negative control, and the one thing Android's 60s margin cannot check: once the
    /// token has ACTUALLY expired, handing it back would buy the caller a 401 instead of an
    /// honest error. That case still throws.
    func testAnExpiredTokenWithATransientRefreshFailureStillThrows() async throws {
        let (sut, _) = try await signedInThenRefreshFails(expiresIn: 1000, advance: 1500)

        do {
            _ = try await sut.snapshot()
            XCTFail("an expired token must not be served as if it worked")
        } catch let error as GogError {
            if case .network = error {} else { XCTFail("expected the transport error, got \(error)") }
        }
        let session = await sut.currentSession
        XCTAssertTrue(session.isSignedIn,
                      "but the session still survives — a blip is not a dead refresh token")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: constants matched to Android rather than chosen
    // ─────────────────────────────────────────────────────────────────────────

    func testThePlaytimeQueueCapMatchesAndroid() {
        // PlaytimeStore.kt: private const val MAX_PENDING = 200
        XCTAssertEqual(PlaytimeQueue.maxPending, 200)
    }

    func testTheIdleTimeoutAndFlushCadenceMatchAndroid() {
        XCTAssertEqual(PlaytimeMeter.idleTimeoutMs, 40_000)      // PlaytimeMeter.kt
        XCTAssertEqual(GogPlaytime.flushIntervalMs, 60_000)      // GogPlaytime.kt
        XCTAssertEqual(GogPlaytime.sessionGapMs, 30 * 60 * 1000) // GogPlaytime.kt
        XCTAssertEqual(GogPlaytime.backgroundDebounceMs, 700)    // GogPlaytime.kt
    }

    /// A creative download gets a shorter budget than a JSON call, and no retry: "a slow CDN
    /// must not hold the game while it waits for a picture" (GogHttp.cs:35-37).
    func testACreativeDownloadHasAShorterBudgetThanAJsonCall() async throws {
        XCTAssertEqual(GogHTTP.timeout, 12)
        XCTAssertEqual(GogHTTP.mediaTimeout, 10)
        XCTAssertLessThan(GogHTTP.mediaTimeout, GogHTTP.timeout)

        // And the budget actually reaches the wire, rather than being a constant nobody uses.
        let t = Self.transport(Self.house(forcedView: "10"))
        let sut = await Self.ads(t, presenter: RecordingPresenter())
        _ = try await sut.showInterstitial()

        let requests = await t.requests
        let directive = try XCTUnwrap(requests.first { $0.url.path.contains("/ads/next") })
        let creative = try XCTUnwrap(requests.first { $0.url.host == "cdn.example.com" })
        XCTAssertEqual(directive.timeout, GogHTTP.timeout)
        XCTAssertEqual(creative.timeout, GogHTTP.mediaTimeout)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: input is counted per EVENT, not per completed gesture
    // TouchTapCallback.kt:40-59 — every dispatchTouchEvent, ACTION_MOVE included
    // ─────────────────────────────────────────────────────────────────────────

    /// 🔴 The bug this replaced: the hook used a `UITapGestureRecognizer`, which fires once
    /// per COMPLETED tap and not at all during a drag. A player panning a map or holding a
    /// slider ticked the meter zero times, so the 40-second cutover fired on someone whose
    /// finger was on the glass the whole time — active play recorded as idle.
    func testAContinuouslyDraggingPlayerNeverGoesIdle() throws {
        var meter = PlaytimeMeter()
        meter.onForeground(0)

        // 60 seconds of dragging, delivered the way the coalescer delivers it: a batch every
        // 100ms carrying the events that arrived inside it (~6 at 60Hz).
        var t: Int64 = 0
        while t < 60_000 {
            t += 100
            meter.onTouch(t, count: 6)
        }
        let delta = meter.drain(t)

        let d = try XCTUnwrap(delta)
        XCTAssertEqual(d.idleMs, 0, "a finger on the glass is not idle time")
        XCTAssertEqual(Double(d.activeMs), 60_000, accuracy: 200)
    }

    /// 🔴 Negative control: the meter must still cut over when input actually stops. A meter
    /// that never went idle would satisfy the test above.
    func testTheCutoverStillFiresWhenTheDragStops() throws {
        var meter = PlaytimeMeter()
        meter.onForeground(0)
        meter.onTouch(1_000, count: 6)
        meter.onTick(61_000)                 // a minute of nothing
        let delta = meter.drain(61_000)

        // 40s of the quiet counts as active (the cutover is 40s after the last touch), the
        // remaining 20s is idle.
        let d = try XCTUnwrap(delta)
        XCTAssertEqual(d.activeMs, 41_000)
        XCTAssertEqual(d.idleMs, 20_000)
    }

    /// `touches` feeds the same column as Android's, where it counts dispatches. Batching is
    /// a transport detail — the number must survive it exactly.
    func testBatchingPreservesTheExactEventCount() {
        var batched = PlaytimeMeter()
        batched.onForeground(0)
        batched.onTouch(100, count: 6)
        batched.onTouch(200, count: 6)
        batched.onTouch(300, count: 5)

        var individually = PlaytimeMeter()
        individually.onForeground(0)
        for _ in 0..<6 { individually.onTouch(100) }
        for _ in 0..<6 { individually.onTouch(200) }
        for _ in 0..<5 { individually.onTouch(300) }

        // `drain` resets the counters, so read each meter exactly once.
        let batchedTouches = batched.drain(400)?.touches
        let individualTouches = individually.drain(400)?.touches
        XCTAssertEqual(batchedTouches, 17)
        XCTAssertEqual(batchedTouches, individualTouches)
    }

    func testAZeroCountBatchIsIgnored() {
        var meter = PlaytimeMeter()
        meter.onForeground(0)
        meter.onTouch(100, count: 0)
        XCTAssertEqual(meter.drain(100)?.touches, 0,
                       "an empty batch must not register as input")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: the playtime clock is MONOTONIC
    // PlaytimeMeter.kt:23-26 — "Wall-clock time must never reach here; an NTP correction
    // mid-session would otherwise invent or erase minutes of play."
    // ─────────────────────────────────────────────────────────────────────────

    /// 🔴 The bug this pins: the first cut defaulted to `Date().timeIntervalSince1970 * 1000`,
    /// exactly the wall clock Android's comment forbids. An NTP step mid-session would have
    /// added or removed play time from the tables both platforms feed, with nothing erroring.
    ///
    /// Wall-clock millis since 1970 are ~1.7e12. Uptime millis are many orders smaller, so the
    /// magnitude alone separates the two clocks unambiguously — no timing, no flakiness.
    func testThePlaytimeClockIsNotAWallClock() {
        let now = GogPlaytime.defaultClockMs()
        let epochMillis = Int64(Date().timeIntervalSince1970 * 1000)
        XCTAssertLessThan(now, epochMillis / 1000,
                          "the default clock reads like epoch time — it is a wall clock, and an "
                          + "NTP correction would silently rewrite playtime")
        XCTAssertGreaterThan(now, 0)
    }

    func testThePlaytimeClockNeverGoesBackwards() {
        var previous = GogPlaytime.defaultClockMs()
        for _ in 0..<2000 {
            let next = GogPlaytime.defaultClockMs()
            XCTAssertGreaterThanOrEqual(next, previous)
            previous = next
        }
    }

    /// 🔴 The hook must stamp input from the SAME clock the meter uses. Two clocks would put
    /// `lastTouchMs` and `segmentStartMs` five orders of magnitude apart, every slice would
    /// exceed the server bounds, and playtime would record nothing — silently.
    @MainActor
    func testTheInputHookAndTheMeterShareOneClock() async throws {
        let playtime = GogPlaytime(
            gameId: TestSupport.gameId, deviceId: "d", appVersion: nil,
            queue: try PlaytimeQueue(fileURL: TestSupport.tempLogURL()),
            uploader: PlaytimeUploader(baseURL: TestSupport.configuration().baseURL,
                                       transport: MockTransport.fixed(200, "{}"),
                                       accessToken: { nil }))
        // `clockMs` is the single source the hook reads; prove it is reachable and monotonic
        // from outside the actor, which is what makes one-clock structurally guaranteed.
        let a = playtime.clockMs()
        let b = playtime.clockMs()
        XCTAssertGreaterThanOrEqual(b, a)
        XCTAssertLessThan(a, Int64(Date().timeIntervalSince1970 * 1000) / 1000,
                          "the actor's own clock must be the monotonic one too")
    }

    /// The three server error strings that are NOT snake_case. A port that normalises every
    /// key to snake_case mis-maps all three, silently (GogHttp.cs:268-282).
    func testTheSpaceSeparatedServerErrorStringsAreMapped() {
        let cases: [(Int, String, GogError)] = [
            (400, "invalid input", .invalidInput(field: nil)),
            (400, "invalid_input", .invalidInput(field: nil)),
        ]
        for (status, body, expected) in cases {
            let data = Data(#"{"error":"\#(body)"}"#.utf8)
            let mapped = GogErrorMapper.error(status: status, body: data, headers: [:])
            XCTAssertEqual(mapped, expected, "\(status)/\(body) must map to \(expected)")
        }
        // 401 and 500 are decided by the status bucket, so their space-separated strings
        // ("invalid or expired code", "internal error") need no separate entry — but the
        // bucket must still be right.
        XCTAssertEqual(
            GogErrorMapper.error(status: 401, body: Data(#"{"error":"invalid or expired code"}"#.utf8),
                                 headers: [:]),
            .unauthorized)
    }
}
