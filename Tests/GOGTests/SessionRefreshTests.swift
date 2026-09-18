import XCTest
@testable import GOG

/// Session lifecycle: exchange, refresh, single-flight, and the two negative controls that
/// would catch a repeat of the Phase 2 account-boundary bug in the identity layer.
/// A clock the tests move by hand, so proactive-refresh timing is deterministic instead of
/// depending on degenerate `expires_in` values.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: @Sendable () -> Date { { [self] in lock.lock(); defer { lock.unlock() }; return current } }
    func advance(by seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}

final class SessionRefreshTests: XCTestCase {

    private static let userA = "11111111-1111-4111-8111-111111111111"
    private static let userB = "22222222-2222-4222-8222-222222222222"

    private static func exchangeBody(user: String, expiresIn: Int = 3600) -> String {
        """
        {"access_token":"at-\(user.prefix(4))","refresh_token":"rt-\(user.prefix(4))",
         "expires_at":1,"expires_in":\(expiresIn),"token_type":"bearer",
         "user":{"id":"\(user)","email":"p@example.com"}}
        """
    }
    /// NOTE: /auth/refresh returns the same shape MINUS token_type. Modelled as its own DTO.
    private static func refreshBody(user: String, token: String, expiresIn: Int = 3600) -> String {
        """
        {"access_token":"\(token)","refresh_token":"rt2-\(user.prefix(4))",
         "expires_at":1,"expires_in":\(expiresIn),
         "user":{"id":"\(user)","email":"p@example.com"}}
        """
    }

    private func identity(_ transport: MockTransport,
                          store: InMemorySecureStore,
                          now: @escaping @Sendable () -> Date = { Date() }) throws -> GogIdentity {
        try GogIdentity(configuration: TestSupport.configuration(),
                        store: store, transport: transport, now: now)
    }

    // ─── userScope derivation ────────────────────────────────────────────────
    func testUserScopeIsDerivedFromUserIdNotTheToken() {
        let scope = GogIdentity.userScope(for: Self.userA)
        XCTAssertEqual(scope, Base64URL.encode(GogSHA256.hash(Self.userA)))
        XCTAssertEqual(scope.count, 43)
        XCTAssertNotEqual(scope, Self.userA, "the raw user id must not be what gets stored")
        XCTAssertNotEqual(scope, GogIdentity.userScope(for: Self.userB))
    }

    func testSignInStoresAScopeDerivedFromTheReturnedUser() async throws {
        let transport = MockTransport.fixed(200, Self.exchangeBody(user: Self.userA))
        let store = InMemorySecureStore()
        let identity = try identity(transport, store: store)

        let user = try await identity.signIn(code: "c", flow: .forwardLaunch)
        XCTAssertEqual(user.id, Self.userA)

        let snapshot = try await identity.snapshot()
        XCTAssertEqual(snapshot.userScope, GogIdentity.userScope(for: Self.userA))
        XCTAssertEqual(snapshot.accessToken, "at-1111")
    }

    // ─── 🔴 NEGATIVE CONTROL 1 ───────────────────────────────────────────────
    // userScope must be STABLE across a token refresh. If it were derived from the access
    // token, every refresh would silently orphan the player's pending wallet operations.
    func testUserScopeIsStableAcrossATokenRefresh() async throws {
        let store = InMemorySecureStore()
        let transport = MockTransport { request, _ in
            let body = request.url.path.contains("/sso/exchange")
                ? Self.exchangeBody(user: Self.userA, expiresIn: 10)   // near-expiry on purpose
                : Self.refreshBody(user: Self.userA, token: "at-REFRESHED")
            return (Data(body.utf8), GogWireResponse(status: 200, headers: [:]))
        }
        let identity = try identity(transport, store: store)
        _ = try await identity.signIn(code: "c", flow: .forwardLaunch)

        let before = try await identity.snapshot()
        let after = try await identity.forceRefresh()

        XCTAssertNotEqual(before.accessToken, after.accessToken, "the token must have rotated")
        XCTAssertEqual(after.accessToken, "at-REFRESHED")
        XCTAssertEqual(before.userScope, after.userScope,
                       "the scope MUST NOT move when the token does")
    }

    // ─── 🔴 NEGATIVE CONTROL 2 ───────────────────────────────────────────────
    // A session that comes back for a DIFFERENT user.id must not inherit the previous
    // scope. Carrying it over is how one account inherits another's pending operations —
    // the identity-layer form of the Phase 2 mis-crediting bug.
    func testSessionForADifferentUserDoesNotInheritThePreviousScope() async throws {
        let store = InMemorySecureStore()
        let transport = MockTransport { request, _ in
            let body = request.url.path.contains("/sso/exchange")
                ? Self.exchangeBody(user: Self.userA, expiresIn: 10)
                : Self.refreshBody(user: Self.userB, token: "at-B")   // server returns user B
            return (Data(body.utf8), GogWireResponse(status: 200, headers: [:]))
        }
        let identity = try identity(transport, store: store)
        _ = try await identity.signIn(code: "c", flow: .forwardLaunch)
        let scopeA = try await identity.snapshot().userScope

        let after = try await identity.forceRefresh()

        XCTAssertEqual(after.userScope, GogIdentity.userScope(for: Self.userB))
        XCTAssertNotEqual(after.userScope, scopeA,
                          "the scope must follow the user, never the stored session")
    }

    // ─── single-flight ───────────────────────────────────────────────────────
    // N parallel refreshes would rotate the refresh token N times and invalidate each
    // other's copy.
    func testConcurrentRefreshesCollapseToOneRequest() async throws {
        let store = InMemorySecureStore()
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let transport = MockTransport { request, _ in
            let body = request.url.path.contains("/sso/exchange")
                ? Self.exchangeBody(user: Self.userA, expiresIn: 3600)
                : Self.refreshBody(user: Self.userA, token: "at-R", expiresIn: 3600)
            return (Data(body.utf8), GogWireResponse(status: 200, headers: [:]))
        }
        let identity = try identity(transport, store: store, now: clock.now)
        _ = try await identity.signIn(code: "c", flow: .forwardLaunch)
        let afterSignIn = await transport.callCount

        // Past 80% of the token's life — every caller now sees a refresh as due.
        clock.advance(by: 3000)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { _ = try? await identity.snapshot() } }
        }

        let refreshCalls = await transport.callCount - afterSignIn
        XCTAssertEqual(refreshCalls, 1, "8 concurrent callers, exactly one refresh")
    }

    func testFreshTokenIsNotRefreshed() async throws {
        let transport = MockTransport.fixed(200, Self.exchangeBody(user: Self.userA, expiresIn: 3600))
        let identity = try identity(transport, store: InMemorySecureStore())
        _ = try await identity.signIn(code: "c", flow: .forwardLaunch)
        let after = await transport.callCount
        _ = try await identity.snapshot()
        _ = try await identity.snapshot()
        let now = await transport.callCount
        XCTAssertEqual(now, after, "a token with plenty of life left must not trigger a refresh")
    }

    // ─── failure handling ────────────────────────────────────────────────────
    /// 403 `banned` must be diagnosably different from an expired token: the remedy is
    /// completely different and a banned player told "session expired" retries forever.
    func testBannedRefreshSurfacesItsOwnErrorAndClearsTheSession() async throws {
        let store = InMemorySecureStore()
        let transport = MockTransport { request, _ in
            request.url.path.contains("/sso/exchange")
                ? (Data(Self.exchangeBody(user: Self.userA, expiresIn: 10).utf8),
                   GogWireResponse(status: 200, headers: [:]))
                : (Data(#"{"error":"banned"}"#.utf8), GogWireResponse(status: 403, headers: [:]))
        }
        let identity = try identity(transport, store: store)
        _ = try await identity.signIn(code: "c", flow: .forwardLaunch)

        do {
            _ = try await identity.forceRefresh()
            XCTFail("should have thrown")
        } catch let error as GogError {
            XCTAssertEqual(error, .accountBanned)
        }
        let signedIn = await identity.isSignedIn
        XCTAssertFalse(signedIn, "a dead session must not be left behind to retry against")
    }

    func testDeadRefreshTokenClearsTheSession() async throws {
        let store = InMemorySecureStore()
        let transport = MockTransport { request, _ in
            request.url.path.contains("/sso/exchange")
                ? (Data(Self.exchangeBody(user: Self.userA, expiresIn: 10).utf8),
                   GogWireResponse(status: 200, headers: [:]))
                : (Data(#"{"error":"invalid or expired token"}"#.utf8),
                   GogWireResponse(status: 401, headers: [:]))
        }
        let identity = try identity(transport, store: store)
        _ = try await identity.signIn(code: "c", flow: .forwardLaunch)
        _ = try? await identity.forceRefresh()
        let signedIn = await identity.isSignedIn
        XCTAssertFalse(signedIn)
    }

    /// Transient failure must NOT throw the session away — the next attempt may work.
    func testTransientRefreshFailureKeepsTheSession() async throws {
        let store = InMemorySecureStore()
        let transport = MockTransport { request, _ in
            request.url.path.contains("/sso/exchange")
                ? (Data(Self.exchangeBody(user: Self.userA, expiresIn: 10).utf8),
                   GogWireResponse(status: 200, headers: [:]))
                : (Data(#"{"error":"internal error"}"#.utf8),
                   GogWireResponse(status: 500, headers: [:]))
        }
        let identity = try identity(transport, store: store)
        _ = try await identity.signIn(code: "c", flow: .forwardLaunch)
        _ = try? await identity.forceRefresh()
        let signedIn = await identity.isSignedIn
        XCTAssertTrue(signedIn, "a 500 is transient; the session is still the best we have")
    }

    // ─── the burn guard ──────────────────────────────────────────────────────
    /// A reverse handoff whose verifier is gone must NOT reach the network. Exchanging
    /// without it consumes the code to learn something already known — the burn table puts
    /// the verifier check AFTER the atomic consume.
    func testReverseHandoffWithoutAVerifierNeverSendsTheExchange() async throws {
        let transport = MockTransport.fixed(200, Self.exchangeBody(user: Self.userA))
        let identity = try identity(transport, store: InMemorySecureStore())

        do {
            _ = try await identity.signIn(code: "live-code", flow: .reverseHandoff)
            XCTFail("should have refused")
        } catch let error as GogError {
            guard case .notConfigured = error else { return XCTFail("wrong error: \(error)") }
        }
        let calls = await transport.callCount
        XCTAssertEqual(calls, 0, "the code must not be spent on a doomed exchange")
    }

    /// The forward leg has no challenge, so no verifier is required and the pre-PKCE
    /// contract is byte-identical.
    func testForwardLaunchExchangesWithoutAVerifier() async throws {
        let transport = MockTransport.fixed(200, Self.exchangeBody(user: Self.userA))
        let identity = try identity(transport, store: InMemorySecureStore())
        _ = try await identity.signIn(code: "c", flow: .forwardLaunch)

        let count = await transport.bodyCount
        XCTAssertEqual(count, 1)
        let hasVerifier = await transport.bodyHasKey("code_verifier", at: 0)
        XCTAssertFalse(hasVerifier, "no challenge was sent, so no verifier must be")
    }

    /// The reverse leg sends the verifier that matches the challenge it began with.
    func testReverseHandoffSendsTheVerifierItBeganWith() async throws {
        let store = InMemorySecureStore()
        let transport = MockTransport.fixed(200, Self.exchangeBody(user: Self.userA))
        let identity = try identity(transport, store: store)

        let handoff = try await identity.beginReverseHandoff()
        let challenge = handoff.codeChallenge
        _ = try await identity.signIn(code: "c", flow: .reverseHandoff)

        let sent = await transport.stringBody("code_verifier", at: 0)
        let verifier = try XCTUnwrap(sent)
        XCTAssertEqual(Base64URL.encode(GogSHA256.hash(verifier)), challenge,
                       "S256: the challenge sent to the hub must be the hash of the verifier sent to exchange")
    }

    func testSignOutClearsSessionAndAnyInFlightFlow() async throws {
        let store = InMemorySecureStore()
        let transport = MockTransport.fixed(200, Self.exchangeBody(user: Self.userA))
        let identity = try identity(transport, store: store)
        _ = try await identity.signIn(code: "c", flow: .forwardLaunch)
        _ = try await identity.beginReverseHandoff()

        await identity.signOut()

        let signedIn = await identity.isSignedIn
        XCTAssertFalse(signedIn)
        XCTAssertTrue(store.keys.isEmpty, "no session, and no previous player's verifier left behind")
    }

    /// The whole point of the seam: identity satisfies what coins needs, with no coupling.
    func testIdentityCanDriveTheCoinsSessionProvider() async throws {
        let transport = MockTransport { request, _ in
            let body = request.url.path.contains("/sso/exchange")
                ? Self.exchangeBody(user: Self.userA)
                : #"{"balance": 77}"#
            return (Data(body.utf8), GogWireResponse(status: 200, headers: [:]))
        }
        let identity = try identity(transport, store: InMemorySecureStore())
        _ = try await identity.signIn(code: "c", flow: .forwardLaunch)

        let coins = try await MainActor.run {
            try GogCoins(configuration: TestSupport.configuration(),
                         sessionProvider: identity.sessionProvider,
                         transport: transport,
                         idempotencyLog: IdempotencyLog(fileURL: TestSupport.tempLogURL()))
        }
        let wallet = try await coins.balance()
        XCTAssertEqual(wallet.balance, 77)

        let auths = await transport.authorizations
        XCTAssertEqual(auths.last, "Bearer at-1111", "coins used the session identity minted")
    }
}
