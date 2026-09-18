import XCTest
@testable import GOG

/// Wraps a store and counts what happened to each key, so "these two changes landed in ONE
/// write" is an assertion rather than a claim in a comment.
final class CountingSecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private let inner: InMemorySecureStore
    private var writes: [String] = []
    private var removes: [String] = []

    init(_ inner: InMemorySecureStore = InMemorySecureStore()) { self.inner = inner }

    func get(_ key: String) throws -> Data? { try inner.get(key) }

    func set(_ data: Data, for key: String) throws {
        try inner.set(data, for: key)
        lock.lock(); writes.append(key); lock.unlock()
    }

    func remove(_ key: String) throws {
        try inner.remove(key)
        lock.lock(); removes.append(key); lock.unlock()
    }

    func resetCounts() { lock.lock(); writes = []; removes = []; lock.unlock() }
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes.count }
    var removeCount: Int { lock.lock(); defer { lock.unlock() }; return removes.count }
    var raw: InMemorySecureStore { inner }
}

/// Manual mode captures a launch code and then waits — for the game to finish loading and ask
/// for it. Android writes that code down (`PendingHandoff`); until this change we held it in a
/// field, which loses it to exactly the jetsam a cold launch invites.
final class PendingLaunchCodeTests: XCTestCase {

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private static let userId = "11111111-1111-4111-8111-111111111111"
    private static let exchangeOK = """
        {"access_token":"at","refresh_token":"rt","expires_at":1,"expires_in":3600,
         "token_type":"bearer","user":{"id":"\(userId)","email":"p@example.com"}}
        """

    private var gameId: UUID { TestSupport.gameId }

    private func manualConfig(gameId: UUID? = nil) -> GogConfiguration {
        GogConfiguration(gameId: gameId ?? TestSupport.gameId,
                         baseURL: URL(string: "https://gog-api.fly.dev")!,
                         autoSignInFromLaunch: false)
    }

    private func launchURL(_ suffix: String = "#code=abc", gameId: UUID? = nil) -> URL {
        let id = (gameId ?? TestSupport.gameId).uuidString.lowercased()
        return URL(string: "https://link.godofgaming.online/launch/\(id)\(suffix)")!
    }

    private func identity(_ t: MockTransport, store: any SecureStore,
                          config: GogConfiguration? = nil,
                          clock: TestClock? = nil) throws -> GogIdentity {
        try GogIdentity(configuration: config ?? manualConfig(), store: store,
                        transport: t, webAuth: nil,
                        now: (clock ?? TestClock(PendingLaunchCodeTests.epoch)).now)
    }

    // MARK: - Survival

    /// 🔴 The whole point. A code captured by one process is still there for the next one.
    func testACapturedCodeSurvivesProcessDeath() async throws {
        let store = InMemorySecureStore()
        let t = MockTransport.fixed(200, Self.exchangeOK)

        // Process 1: the link arrives, the game has not asked yet, the app is reaped.
        do {
            let first = try identity(t, store: store)
            let handled = try await first.trySignInFromLaunch(url: launchURL("#code=live-code"))
            XCTAssertTrue(handled)
            let captured = await first.hasCapturedLaunchCode
            XCTAssertTrue(captured)
        }

        // Process 2: a brand-new SDK on the same storage. The URL is long gone.
        let second = try identity(t, store: store)
        let stillThere = await second.hasCapturedLaunchCode
        XCTAssertTrue(stillThere, "the code must outlive the process that captured it")

        let signedIn = try await second.trySignInFromLaunch()
        XCTAssertTrue(signedIn)
        let sentCode = await t.stringBody("code", at: 0)
        XCTAssertEqual(sentCode, "live-code")
    }

    /// 🔴 Negative control for the test above: it must be reading a code that was really
    /// captured, not defaulting to true. An SDK that never saw a link has nothing pending.
    func testAFreshSDKWithNoCaptureHasNothingPending() async throws {
        let store = InMemorySecureStore()
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let sut = try identity(t, store: store)

        let captured = await sut.hasCapturedLaunchCode
        XCTAssertFalse(captured)
        let exchanged = try await sut.trySignInFromLaunch()
        XCTAssertFalse(exchanged, "nothing pending must be false, not an error")
        let calls = await t.callCount
        XCTAssertEqual(calls, 0)
    }

    // MARK: - The 120s life

    func testACodeOlderThanItsTTLIsNotOffered() async throws {
        let store = InMemorySecureStore()
        let clock = TestClock(Self.epoch)
        let t = MockTransport.fixed(200, Self.exchangeOK)

        let first = try identity(t, store: store, clock: clock)
        _ = try await first.trySignInFromLaunch(url: launchURL())

        clock.advance(by: PendingLaunchCode.ttl + 1)

        let second = try identity(t, store: store, clock: clock)
        let captured = await second.hasCapturedLaunchCode
        XCTAssertFalse(captured, "a dead code must not be offered as if it could sign anyone in")
        let exchanged = try await second.trySignInFromLaunch()
        XCTAssertFalse(exchanged)
        let calls = await t.callCount
        XCTAssertEqual(calls, 0, "and must not be spent on a round trip that cannot succeed")
    }

    /// 🔴 Negative control for the TTL: one second inside the window it is still live. Without
    /// this the test above would pass just as well against a store that dropped everything.
    func testACodeInsideItsTTLIsStillOffered() async throws {
        let store = InMemorySecureStore()
        let clock = TestClock(Self.epoch)
        let t = MockTransport.fixed(200, Self.exchangeOK)

        let first = try identity(t, store: store, clock: clock)
        _ = try await first.trySignInFromLaunch(url: launchURL())

        clock.advance(by: PendingLaunchCode.ttl - 1)

        let second = try identity(t, store: store, clock: clock)
        let captured = await second.hasCapturedLaunchCode
        XCTAssertTrue(captured)
        let exchanged = try await second.trySignInFromLaunch()
        XCTAssertTrue(exchanged)
    }

    func testACodeCapturedForAnotherGameIsDiscarded() async throws {
        let store = InMemorySecureStore()
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let otherGame = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

        let first = try identity(t, store: store, config: manualConfig(gameId: otherGame))
        _ = try await first.trySignInFromLaunch(url: launchURL(gameId: otherGame))

        // Same device, same storage, a different game's SDK reading it.
        let second = try identity(t, store: store)
        let captured = await second.hasCapturedLaunchCode
        XCTAssertFalse(captured, "one game must never exchange another game's launch code")
    }

    // MARK: - Atomicity: saveSessionAndClearPending

    /// 🔴 A signed-in player must never still hold the code that signed them in.
    ///
    /// On this path the guarantee is stronger than Android's, and for the same reason the
    /// PKCE verifier is consumed before its exchange: the code is dropped BEFORE the round
    /// trip, so there is no instant in which a session and the code that produced it both
    /// exist. One code, one attempt.
    func testSigningInFromACapturedCodeLeavesNothingPending() async throws {
        let store = CountingSecureStore()
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let sut = try identity(t, store: store)

        _ = try await sut.trySignInFromLaunch(url: launchURL("#code=abc"))
        _ = try await sut.trySignInFromLaunch()

        let record = try XCTUnwrap(try store.get("gog.session"))
        let stored = try XCTUnwrap(StoredIdentity.decode(record))
        XCTAssertNotNil(stored.session)
        XCTAssertNil(stored.pendingLaunchCode)

        let stillThere = await sut.hasCapturedLaunchCode
        XCTAssertFalse(stillThere)
    }

    /// 🔴 `saveSessionAndClearPending`, on the path that needs it: a sign-in that did NOT come
    /// from the pending record — a direct `signIn(code:flow:)`, or an auto-mode launch — still
    /// has to drop a code captured earlier, and has to do it in the SAME store operation.
    ///
    /// Two operations would leave a window: killed between them, the next launch finds a
    /// signed-in player holding a spent code, offers it to the game, and buys a 401 and a
    /// `launchSignInFailed` nobody caused.
    func testASessionWriteClearsAPendingCodeInOneOperation() async throws {
        let store = CountingSecureStore()
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let sut = try identity(t, store: store)

        _ = try await sut.trySignInFromLaunch(url: launchURL("#code=captured"))
        let captured = await sut.hasCapturedLaunchCode
        XCTAssertTrue(captured, "precondition: something is pending for the write to clear")

        store.resetCounts()
        _ = try await sut.signIn(code: "a-different-code", flow: .forwardLaunch)

        XCTAssertEqual(store.writeCount, 1,
                       "the session write and the pending clear are one store operation")
        XCTAssertEqual(store.removeCount, 0, "and not a write plus a separate removal")

        let record = try XCTUnwrap(try store.get("gog.session"))
        let stored = try XCTUnwrap(StoredIdentity.decode(record))
        XCTAssertNotNil(stored.session)
        XCTAssertNil(stored.pendingLaunchCode)
    }

    /// A code is single-use. A failed exchange has still spent it, so it must not be left
    /// behind to fail identically on every relaunch for the rest of its life.
    func testAFailedExchangeDoesNotLeaveTheCodeBehind() async throws {
        let store = InMemorySecureStore()
        let t = MockTransport.fixed(401, #"{"error":"invalid_grant"}"#)
        let sut = try identity(t, store: store)

        _ = try await sut.trySignInFromLaunch(url: launchURL())
        do {
            _ = try await sut.trySignInFromLaunch()
            XCTFail("a 401 on the exchange must surface")
        } catch let error as GogError {
            XCTAssertEqual(error, .invalidOrExpiredCode)
        }

        let stillThere = await sut.hasCapturedLaunchCode
        XCTAssertFalse(stillThere)
        let again = try await sut.trySignInFromLaunch()
        XCTAssertFalse(again)
        let calls = await t.callCount
        XCTAssertEqual(calls, 1, "one code, one attempt")
    }

    func testSignOutClearsAPendingCode() async throws {
        let store = InMemorySecureStore()
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let sut = try identity(t, store: store)

        _ = try await sut.trySignInFromLaunch(url: launchURL())
        await sut.signOut()

        let stillThere = await sut.hasCapturedLaunchCode
        XCTAssertFalse(stillThere,
                       "a signed-out player must not hold a live code that signs them back in")
    }

    /// Shutdown is a gentler process death, and the code is persisted precisely to survive
    /// that. An orderly teardown must not lose what a crash preserves.
    func testShutdownDoesNotDropACapturedCode() async throws {
        let store = InMemorySecureStore()
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let sut = try identity(t, store: store)

        _ = try await sut.trySignInFromLaunch(url: launchURL())
        await sut.finishEvents()

        let next = try identity(t, store: store)
        let stillThere = await next.hasCapturedLaunchCode
        XCTAssertTrue(stillThere)
    }

    // MARK: - The startup sweep (Android's resumePendingHandoff, minus the resume)

    /// The bound is Android's, deliberately — and it is storage hygiene, not a validity
    /// check. Bounding at the server's ~120s code life would put a copy of the server's TTL
    /// in the client, wrong the day it changes and wrong in the silent direction.
    func testThePendingBoundMatchesAndroid() {
        // GogAuthCore.kt: const val PENDING_MAX_AGE_SEC = 300L
        XCTAssertEqual(PendingLaunchCode.ttl, 300)
        // ...and the PKCE flow, armed by the same Android record, uses the same bound.
        XCTAssertEqual(PKCEFlowStore.flowTTL, 300)
    }

    func testStartupSweepsAnAbandonedLaunchCode() async throws {
        let store = InMemorySecureStore()
        let clock = TestClock(Self.epoch)
        let t = MockTransport.fixed(200, Self.exchangeOK)

        let first = try identity(t, store: store, clock: clock)
        _ = try await first.trySignInFromLaunch(url: launchURL())
        XCTAssertFalse(store.keys.isEmpty, "precondition: something was written")

        clock.advance(by: PendingLaunchCode.ttl + 1)
        let next = try identity(t, store: store, clock: clock)
        await next.sweepStaleSignInState()

        XCTAssertTrue(store.keys.isEmpty,
                      "an abandoned record must not survive its bound just because nobody asked")
    }

    /// 🔴 Negative control: the sweep must be selective. A sweep that cleared everything would
    /// satisfy the test above and sign every returning player out.
    func testStartupLeavesALiveLaunchCodeAlone() async throws {
        let store = InMemorySecureStore()
        let clock = TestClock(Self.epoch)
        let t = MockTransport.fixed(200, Self.exchangeOK)

        let first = try identity(t, store: store, clock: clock)
        _ = try await first.trySignInFromLaunch(url: launchURL())

        clock.advance(by: PendingLaunchCode.ttl - 1)
        let next = try identity(t, store: store, clock: clock)
        await next.sweepStaleSignInState()

        let stillThere = await next.hasCapturedLaunchCode
        XCTAssertTrue(stillThere)
    }

    func testStartupSweepsAnAbandonedPKCEFlow() async throws {
        let store = InMemorySecureStore()
        let clock = TestClock(Self.epoch)
        let pkce = PKCEFlowStore(store: store)

        _ = try await pkce.begin(gameId: TestSupport.gameId, now: clock.now())
        var armed = await pkce.hasPendingFlow()
        XCTAssertTrue(armed)

        clock.advance(by: PKCEFlowStore.flowTTL + 1)
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let sut = try identity(t, store: store, clock: clock)
        await sut.sweepStaleSignInState()

        armed = await pkce.hasPendingFlow()
        XCTAssertFalse(armed, "an abandoned verifier must not outlive its bound in the Keychain")
    }

    /// 🔴 Negative control for the sweep above.
    func testStartupLeavesALivePKCEFlowAlone() async throws {
        let store = InMemorySecureStore()
        let clock = TestClock(Self.epoch)
        let pkce = PKCEFlowStore(store: store)

        _ = try await pkce.begin(gameId: TestSupport.gameId, now: clock.now())
        clock.advance(by: PKCEFlowStore.flowTTL - 1)

        let t = MockTransport.fixed(200, Self.exchangeOK)
        let sut = try identity(t, store: store, clock: clock)
        await sut.sweepStaleSignInState()

        let armed = await pkce.hasPendingFlow()
        XCTAssertTrue(armed, "sweeping a live flow would burn the code it is waiting for")
    }

    // MARK: - Record tolerance (I9)

    /// The stored record grew an envelope around the session. A build from before that change
    /// wrote a bare `StoredSession` under the same key; reading one must not sign the player
    /// out.
    func testALegacyBareSessionRecordIsStillReadable() throws {
        let session = StoredSession(accessToken: "at", refreshToken: "rt",
                                    user: GogUser(id: Self.userId, email: "p@example.com"),
                                    userScope: "scope", expiresIn: 3600,
                                    receivedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let legacy = try JSONEncoder().encode(session)

        let decoded = try XCTUnwrap(StoredIdentity.decode(legacy))
        XCTAssertEqual(decoded.session?.accessToken, "at")
        XCTAssertNil(decoded.pendingLaunchCode)
    }

    func testAnEnvelopeRecordRoundTrips() throws {
        let identity = StoredIdentity(
            session: nil,
            pendingLaunchCode: PendingLaunchCode(code: "c", gameId: TestSupport.gameId,
                                                 capturedAt: Date(timeIntervalSince1970: 1)))
        let decoded = try XCTUnwrap(StoredIdentity.decode(try JSONEncoder().encode(identity)))
        XCTAssertEqual(decoded.pendingLaunchCode?.code, "c")
        XCTAssertNil(decoded.session)
    }

    func testGarbageInTheRecordReadsAsSignedOutRatherThanCrashing() {
        XCTAssertNil(StoredIdentity.decode(Data("not json".utf8)))
    }
}
