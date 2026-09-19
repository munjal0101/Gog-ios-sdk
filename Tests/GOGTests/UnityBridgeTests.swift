import XCTest
@testable import GOG

/// The Unity binding's native seam on iOS (`Bridge/GogUnityBridge.swift`).
///
/// The C# side (`IosAuthBridge.cs`) can only be exercised inside a Unity iOS build, so the
/// contract it depends on is pinned HERE: the JSON shape, the error-token table, and which
/// identity events cross the boundary.
final class UnityBridgeTests: XCTestCase {

    private static let user = "22222222-2222-4222-8222-222222222222"
    private static func exchange(expiresIn: Int = 3600) -> String {
        """
        {"access_token":"at","refresh_token":"rt","expires_at":1,"expires_in":\(expiresIn),
         "token_type":"bearer","user":{"id":"\(user)","email":"p@example.com"}}
        """
    }
    private var gameId: UUID { TestSupport.gameId }

    private func bridge(_ transport: MockTransport,
                        store: InMemorySecureStore = InMemorySecureStore()) throws -> UnityBridgeCore {
        let identity = try GogIdentity(configuration: TestSupport.configuration(),
                                       store: store, transport: transport)
        return UnityBridgeCore(identity: identity, gameId: gameId)
    }

    private func launchURL(_ suffix: String) -> URL {
        URL(string: "https://link.godofgaming.online/launch/\(gameId.uuidString.lowercased())\(suffix)")!
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // ─── the error-token table ───────────────────────────────────────────────

    /// 🔴 These strings are ABI. `IosAuthBridge.MapReason` switches on exactly this set, and
    /// its own table-driven test lists the same tokens. Renaming one here without there turns
    /// a typed error into `InternalError` on the C# side with no compiler to notice.
    func testEveryErrorCaseHasItsPinnedToken() {
        let table: [(GogError, String)] = [
            (.network(.offline, retryable: true), "network"),
            (.unauthorized, "unauthorized"),
            (.rateLimited(retryAfter: 3), "rate_limited"),
            (.insufficientFunds, "insufficient_funds"),
            (.earnTooLarge, "earn_too_large"),
            (.idempotencyKeyReused, "idempotency_key_reused"),
            (.invalidInput(field: nil), "invalid_input"),
            (.unknownGame, "unknown_game"),
            (.cityRequired, "city_required"),
            (.server, "server"),
            (.malformedResponse(missingField: "x"), "malformed_response"),
            (.accountBanned, "account_banned"),
            (.signInCancelled, "sign_in_cancelled"),
            (.invalidOrExpiredCode, "invalid_or_expired_code"),
            (.signInInProgress, "sign_in_in_progress"),
            (.launchLinkInvalid(.missingCode), "launch_link_invalid"),
            (.notConfigured("x"), "not_configured"),
        ]
        for (error, token) in table {
            XCTAssertEqual(BridgeResult.reason(for: error), token, "\(error)")
        }
        XCTAssertEqual(Set(table.map(\.1)).count, table.count, "two cases share a token")
    }

    func testAFailureCarriesTheTransportsRetryOpinion() throws {
        let retry = try object(BridgeResult.failure(GogError.network(.timedOut, retryable: true)))
        XCTAssertEqual(retry["ok"] as? Bool, false)
        XCTAssertEqual(retry["reason"] as? String, "network")
        XCTAssertEqual(retry["retryable"] as? Bool, true)

        let dead = try object(BridgeResult.failure(GogError.invalidOrExpiredCode))
        XCTAssertEqual(dead["retryable"] as? Bool, false)
    }

    func testANonGogErrorIsInternalNotACrash() throws {
        let result = try object(BridgeResult.failure(CancellationError()))
        XCTAssertEqual(result["reason"] as? String, "internal")
    }

    // ─── explicit calls ─────────────────────────────────────────────────────

    func testSignInWithCodeResolvesWithTheUserAndNoTokens() async throws {
        let bridge = try bridge(MockTransport.fixed(200, Self.exchange()))
        let result = try object(await bridge.signIn(code: "abc"))

        XCTAssertEqual(result["ok"] as? Bool, true)
        let user = try XCTUnwrap(result["user"] as? [String: Any])
        XCTAssertEqual(user["id"] as? String, Self.user)
        XCTAssertEqual(user["email"] as? String, "p@example.com")
        // Identity flows up; the refresh token never does, and a sign-in carries no token.
        XCTAssertNil(result["token"])
        XCTAssertFalse(try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: result),
                                            encoding: .utf8)).contains("rt"))
    }

    func testASpentCodeIsInvalidOrExpiredNotUnauthorized() async throws {
        let bridge = try bridge(MockTransport.fixed(401, #"{"error":"invalid or expired code"}"#))
        let result = try object(await bridge.signIn(code: "spent"))
        XCTAssertEqual(result["reason"] as? String, "invalid_or_expired_code")
    }

    func testAccessTokenWhileSignedOutIsUnauthorized() async throws {
        let bridge = try bridge(MockTransport.fixed(500, "{}"))
        let result = try object(await bridge.accessToken())
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["reason"] as? String, "unauthorized")
    }

    func testAccessTokenAfterSignIn() async throws {
        let bridge = try bridge(MockTransport.fixed(200, Self.exchange()))
        _ = await bridge.signIn(code: "abc")
        let result = try object(await bridge.accessToken())
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["token"] as? String, "at")
    }

    // ─── CurrentSession, synchronously ───────────────────────────────────────

    func testCurrentUserIsNilSignedOutAndPresentSignedIn() async throws {
        let bridge = try bridge(MockTransport.fixed(200, Self.exchange()))
        XCTAssertNil(bridge.currentUserJSON())

        _ = await bridge.signIn(code: "abc")
        let user = try object(try XCTUnwrap(bridge.currentUserJSON()))
        XCTAssertEqual(user["id"] as? String, Self.user)

        await bridge.signOut()
        XCTAssertNil(bridge.currentUserJSON(), "a signed-out read must not see the old player")
    }

    // ─── launch links ────────────────────────────────────────────────────────

    func testOnlyThisGamesLaunchLinkIsRecognised() throws {
        let bridge = try bridge(MockTransport.fixed(200, Self.exchange()))
        XCTAssertTrue(bridge.isLaunchLink(launchURL("#code=x")))
        XCTAssertFalse(bridge.isLaunchLink(URL(string: "https://gog-api.fly.dev/launch?code=x")!),
                       "the Android launch host is not an iOS launch link")
        XCTAssertFalse(bridge.isLaunchLink(
            URL(string: "https://link.godofgaming.online/launch/\(UUID().uuidString.lowercased())#code=x")!),
            "another game's link")
    }

    func testALaunchLinkSignsInAndReportsTheUser() async throws {
        let transport = MockTransport.fixed(200, Self.exchange())
        let bridge = try bridge(transport)
        let result = try object(await bridge.handleLaunch(url: launchURL("#code=abc")))

        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["handled"] as? Bool, true)
        XCTAssertEqual((result["user"] as? [String: Any])?["id"] as? String, Self.user)
        let body = await transport.stringBody("code", at: 0)
        XCTAssertEqual(body, "abc")
    }

    func testAForeignURLIsNotHandledAndCostsNothing() async throws {
        let transport = MockTransport.fixed(200, Self.exchange())
        let bridge = try bridge(transport)
        let result = try object(await bridge.handleLaunch(url: URL(string: "https://example.com/x")!))

        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["handled"] as? Bool, false)
        let calls = await transport.callCount
        XCTAssertEqual(calls, 0)
    }

    /// Ours, but carrying the code in the query under the fragment policy: a security event,
    /// reported as a failure — never exchanged, never ignored.
    func testALeakedQueryCodeIsRefusedLoudly() async throws {
        let transport = MockTransport.fixed(200, Self.exchange())
        let bridge = try bridge(transport)
        let result = try object(await bridge.handleLaunch(url: launchURL("?code=leaked")))

        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["reason"] as? String, "launch_link_invalid")
        let calls = await transport.callCount
        XCTAssertEqual(calls, 0)
    }

    // ─── events ──────────────────────────────────────────────────────────────

    /// Only the UNSOLICITED sign-out crosses. `signedIn` and a user-requested sign-out are
    /// raised by C# itself from the explicit call; forwarding them too would double-fire.
    func testOnlyASessionExpiryIsForwarded() async throws {
        // Signs in with a token already due for refresh; the refresh is then refused.
        let transport = MockTransport { request, _ in
            if request.url.path == "/auth/refresh" {
                return (Data(#"{"error":"unauthorized"}"#.utf8), GogWireResponse(status: 401, headers: [:]))
            }
            return (Data(Self.exchange(expiresIn: 0).utf8), GogWireResponse(status: 200, headers: [:]))
        }
        let bridge = try bridge(transport)
        let counter = EventCounter()
        let watcher = bridge.watchSessionExpiry { counter.hit() }
        defer { watcher.cancel() }
        // Let the subscription register before anything is emitted.
        try await Task.sleep(nanoseconds: 50_000_000)

        _ = await bridge.signIn(code: "abc")            // emits signedIn — must NOT forward
        _ = await bridge.accessToken()                  // refresh → 401 → sessionExpired
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(counter.count, 1)

        _ = await bridge.signIn(code: "again")
        await bridge.signOut()                          // userRequested — must NOT forward
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(counter.count, 1)
    }

    // ─── the C ABI itself ────────────────────────────────────────────────────

    /// Two lines in a generated file are a version square of their own. The stamp script
    /// writes both; this is what notices if anything else ever writes only one.
    func testTheCompiledVersionIsTheVersion() {
        XCTAssertEqual(GogSDKVersion.compiled.description, GogSDKVersion.value)
    }

    func testTheVersionCrossesAsAFreeableCString() throws {
        let pointer = try XCTUnwrap(_gogBridgeSDKVersion())
        defer { free(pointer) }
        XCTAssertEqual(String(cString: pointer), GogSDKVersion.value)
    }

    /// Before initialize, the synchronous entry points answer "nothing" rather than crash,
    /// and an async one still resolves — with `not_initialized`, on the main thread.
    func testBeforeInitializeEveryEntryPointAnswers() async throws {
        XCTAssertNil(UnityBridgeHost.shared.current, "tests must never boot the shared host")
        XCTAssertNil(_gogBridgeCurrentUserJSON())
        XCTAssertEqual(_gogBridgeIsLaunchLink("https://link.godofgaming.online/launch/x"), 0)

        CReplies.reset()
        _gogBridgeGetAccessToken(7, CReplies.record)
        try await Task.sleep(nanoseconds: 200_000_000)
        let replies = CReplies.snapshot()
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first?.id, 7)
        XCTAssertEqual(replies.first?.onMain, true)
        let result = try object(try XCTUnwrap(replies.first?.json))
        XCTAssertEqual(result["reason"] as? String, "not_initialized")
    }
}

private final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var hits = 0
    func hit() { lock.lock(); hits += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return hits }
}

/// A C function pointer cannot capture, so replies land in static storage.
private enum CReplies {
    struct Reply: Sendable { let id: Int32; let json: String?; let onMain: Bool }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []

    static let record: GogBridgeCallback = { id, json in
        let reply = Reply(id: id, json: json.map { String(cString: $0) }, onMain: Thread.isMainThread)
        CReplies.lock.lock(); CReplies.replies.append(reply); CReplies.lock.unlock()
    }
    static func reset() { lock.lock(); replies = []; lock.unlock() }
    static func snapshot() -> [Reply] { lock.lock(); defer { lock.unlock() }; return replies }
}
