import XCTest
@testable import GOG

/// The launch code, and the one switch that decides where it rides.
final class LaunchCodeExtractionTests: XCTestCase {
    private let gameId = TestSupport.gameId
    private func launch(_ suffix: String) -> URL {
        URL(string: "https://link.godofgaming.online/launch/\(gameId.uuidString.lowercased())\(suffix)")!
    }

    func testFragmentPolicyAcceptsAFragmentCode() throws {
        let code = try LaunchLinkValidator.extractCode(from: launch("#code=abc123"), delimiter: .fragment)
        XCTAssertEqual(code, "abc123")
    }

    func testQueryPolicyAcceptsAQueryCode() throws {
        let code = try LaunchLinkValidator.extractCode(from: launch("?code=abc123"), delimiter: .query)
        XCTAssertEqual(code, "abc123")
    }

    /// 🔴 The point of having a policy at all. A query-delimited code reached server access
    /// logs and Referer headers before the app saw it; under a fragment policy it must be
    /// refused as compromised, not quietly consumed.
    func testFragmentPolicyRefusesAQueryCode() {
        assertWrongPosition(launch("?code=leaked"), delimiter: .fragment,
                            expected: "fragment", got: "query")
    }

    func testQueryPolicyRefusesAFragmentCode() {
        assertWrongPosition(launch("#code=misplaced"), delimiter: .query,
                            expected: "query", got: "fragment")
    }

    func testNoCodeAtAllIsItsOwnDiagnosis() {
        for delimiter in [LaunchCodeDelimiter.fragment, .query] {
            do {
                _ = try LaunchLinkValidator.extractCode(from: launch(""), delimiter: delimiter)
                XCTFail("should have thrown")
            } catch let error as GogError {
                guard case .launchLinkInvalid(.missingCode) = error else {
                    return XCTFail("expected missingCode, got \(error)")
                }
            } catch { XCTFail("wrong error type") }
        }
    }

    func testFragmentWithOtherParametersStillYieldsTheCode() throws {
        let code = try LaunchLinkValidator.extractCode(
            from: launch("#state=x&code=abc123&v=2"), delimiter: .fragment)
        XCTAssertEqual(code, "abc123")
    }

    func testDefaultPolicyIsFragment() {
        XCTAssertEqual(GogConfiguration(gameId: gameId).launchCodeDelimiter, .fragment)
    }

    private func assertWrongPosition(_ url: URL, delimiter: LaunchCodeDelimiter,
                                     expected: String, got: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try LaunchLinkValidator.extractCode(from: url, delimiter: delimiter)
            XCTFail("must not accept the non-active position", file: file, line: line)
        } catch let error as GogError {
            guard case .launchLinkInvalid(.codeDeliveredInWrongPosition(let e, let g)) = error else {
                return XCTFail("got \(error)", file: file, line: line)
            }
            XCTAssertEqual(e, expected, file: file, line: line)
            XCTAssertEqual(g, got, file: file, line: line)
        } catch { XCTFail("wrong error type", file: file, line: line) }
    }
}

/// The auth surface: state, news, and the distinction between them.
final class AuthSurfaceTests: XCTestCase {
    private static let user = "11111111-1111-4111-8111-111111111111"
    private static let exchangeOK = """
        {"access_token":"at","refresh_token":"rt","expires_at":1,"expires_in":3600,
         "token_type":"bearer","user":{"id":"\(user)","email":"p@example.com"}}
        """

    private func identity(_ t: MockTransport, store: InMemorySecureStore = InMemorySecureStore())
        throws -> GogIdentity {
        try GogIdentity(configuration: TestSupport.configuration(), store: store, transport: t)
    }

    func testCurrentSessionIsSignedOutBeforeSignIn() async throws {
        let identity = try identity(MockTransport.fixed(200, Self.exchangeOK))
        let session = await identity.currentSession
        XCTAssertFalse(session.isSignedIn)
        XCTAssertNil(session.user)
    }

    func testSignInUpdatesStateAndEmitsNews() async throws {
        let identity = try identity(MockTransport.fixed(200, Self.exchangeOK))
        let stream = await identity.eventStream()

        _ = try await identity.signIn(code: "c", flow: .forwardLaunch)

        let session = await identity.currentSession
        XCTAssertTrue(session.isSignedIn)
        XCTAssertEqual(session.user?.id, Self.user)

        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event, .signedIn(GogUser(id: Self.user, email: "p@example.com")))
    }

    /// 🔴 I1 — state is truth, events are news, NEVER replays.
    ///
    /// On Android, gating the UI on the event instead of the state meant coins calls
    /// succeeded while the "signed in as…" label never appeared. A subscriber that starts
    /// after sign-in must get nothing, and must read `currentSession` instead.
    func testALateSubscriberGetsNoReplay() async throws {
        let identity = try identity(MockTransport.fixed(200, Self.exchangeOK))
        _ = try await identity.signIn(code: "c", flow: .forwardLaunch)

        let late = await identity.eventStream()
        let received = await withTaskGroup(of: GogAuthEvent?.self) { group -> GogAuthEvent? in
            group.addTask { var i = late.makeAsyncIterator(); return await i.next() }
            group.addTask { try? await Task.sleep(nanoseconds: 150_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        XCTAssertNil(received, "a restored/late subscriber must not receive a replayed signedIn")

        let session = await identity.currentSession
        XCTAssertTrue(session.isSignedIn, "…but the STATE is still authoritative")
    }

    func testSignOutEmitsItsReason() async throws {
        let identity = try identity(MockTransport.fixed(200, Self.exchangeOK))
        _ = try await identity.signIn(code: "c", flow: .forwardLaunch)
        let stream = await identity.eventStream()

        await identity.signOut()

        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event, .signedOut(.userRequested))
        let session = await identity.currentSession
        XCTAssertFalse(session.isSignedIn)
    }

    func testSignOutWhenAlreadySignedOutEmitsNothing() async throws {
        let identity = try identity(MockTransport.fixed(200, Self.exchangeOK))
        let stream = await identity.eventStream()
        await identity.signOut()

        let received = await withTaskGroup(of: GogAuthEvent?.self) { group -> GogAuthEvent? in
            group.addTask { var i = stream.makeAsyncIterator(); return await i.next() }
            group.addTask { try? await Task.sleep(nanoseconds: 120_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        XCTAssertNil(received, "news is for changes; nothing changed")
    }

    /// A 401 on the EXCHANGE means the code is spent — a different remedy from a session that
    /// went away, even though the wire response is identical.
    func testExchange401BecomesInvalidOrExpiredCode() async throws {
        let identity = try identity(MockTransport.fixed(401, #"{"error":"invalid or expired code"}"#))
        do {
            _ = try await identity.signIn(code: "spent", flow: .forwardLaunch)
            XCTFail("should have thrown")
        } catch let error as GogError {
            XCTAssertEqual(error, .invalidOrExpiredCode)
        }
    }

    func testGetAccessTokenReturnsTheTokenAndNeverTheRefreshToken() async throws {
        let identity = try identity(MockTransport.fixed(200, Self.exchangeOK))
        _ = try await identity.signIn(code: "c", flow: .forwardLaunch)
        let token = try await identity.getAccessToken()
        XCTAssertEqual(token, "at")
        XCTAssertNotEqual(token, "rt", "the refresh token has no path to game code")
    }

    // ─── launch handling ─────────────────────────────────────────────────────
    func testTrySignInFromLaunchIgnoresLinksThatAreNotOurs() async throws {
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let identity = try identity(t)
        let handled = try await identity.trySignInFromLaunch(
            url: URL(string: "https://example.com/somewhere")!)
        XCTAssertFalse(handled, "a host app can pass every link through without special-casing")
        let calls = await t.callCount
        XCTAssertEqual(calls, 0)
    }

    func testTrySignInFromLaunchSignsInOnAGoodLink() async throws {
        let identity = try identity(MockTransport.fixed(200, Self.exchangeOK))
        let url = URL(string:
            "https://link.godofgaming.online/launch/\(TestSupport.gameId.uuidString.lowercased())#code=abc")!
        let handled = try await identity.trySignInFromLaunch(url: url)
        XCTAssertTrue(handled)
        let session = await identity.currentSession
        XCTAssertTrue(session.isSignedIn)
    }

    /// Launch sign-in has no explicit caller, so its failure is broadcast. Android only logs
    /// here, which is the hardest failure in this system to diagnose in the field.
    func testALaunchLinkForUsThatIsBrokenBroadcastsAndThrows() async throws {
        let identity = try identity(MockTransport.fixed(200, Self.exchangeOK))
        let stream = await identity.eventStream()
        let url = URL(string:
            "https://link.godofgaming.online/launch/\(TestSupport.gameId.uuidString.lowercased())?code=leaked")!

        do {
            _ = try await identity.trySignInFromLaunch(url: url)
            XCTFail("a query-delimited code under the fragment policy must not be consumed")
        } catch let error as GogError {
            guard case .launchLinkInvalid(.codeDeliveredInWrongPosition) = error else {
                return XCTFail("got \(error)")
            }
        }
        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        guard case .launchSignInFailed = event else {
            return XCTFail("expected launchSignInFailed, got \(String(describing: event))")
        }
    }
}

/// The root facade.
@MainActor
final class FacadeTests: XCTestCase {

    override func tearDown() async throws {
        await GOG.shutdown()
    }

    private func boot(_ configuration: GogConfiguration) async throws -> GOG {
        try await GOG.initialize(configuration,
                                 store: InMemorySecureStore(),
                                 transport: MockTransport.fixed(200, #"{"type":"none"}"#),
                                 indexStore: MemoryIndexStore(),
                                 presenter: NoOpAdPresenter(),
                                 log: IdempotencyLog(fileURL: TestSupport.tempLogURL()),
                                 playtimeQueue: PlaytimeQueue(fileURL: TestSupport.tempLogURL()),
                                 runStartupTasks: false)
    }

    func testInitializeWiresEverySurface() async throws {
        let gog = try await boot(TestSupport.configuration())
        XCTAssertTrue(GOG.isInitialized)
        XCTAssertIdentical(GOG.shared, gog)
        XCTAssertEqual(gog.configuration.gameId, TestSupport.gameId)
        let session = await gog.auth.currentSession
        XCTAssertFalse(session.isSignedIn)
    }

    /// Runtime reconfiguration does not exist. On Android a second Initialize() with a new
    /// game id updated the managed config while the native core kept the old values — coins
    /// posted against the new game while auth exchanged against the old, silently.
    func testSecondInitializeIsIgnoredAndReturnsTheSameInstance() async throws {
        let first = try await boot(TestSupport.configuration())
        let second = try await boot(GogConfiguration(gameId: UUID()))
        XCTAssertIdentical(first, second)
        XCTAssertEqual(second.configuration.gameId, TestSupport.gameId,
                       "the FIRST configuration must survive")
    }

    /// §1.5 — the handshake throws before anything is marked initialized, so a partial or
    /// tampered install cannot half-boot.
    func testVersionMismatchThrowsAndLeavesTheSdkUninitialized() async {
        let mismatched = GogConfiguration(gameId: TestSupport.gameId, bindingVersion: "9.9.9")
        do {
            _ = try await boot(mismatched)
            XCTFail("should have thrown")
        } catch let error as GogError {
            guard case .notConfigured = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("wrong error type") }
        XCTAssertFalse(GOG.isInitialized)
        XCTAssertNil(GOG.shared)
    }

    func testShutdownClearsTheInstance() async throws {
        _ = try await boot(TestSupport.configuration())
        await GOG.shutdown()
        XCTAssertFalse(GOG.isInitialized)
        XCTAssertNil(GOG.shared)
    }

    func testVersionIsTheCompiledConstant() {
        XCTAssertEqual(GOG.version, GogSDKVersion.value)
    }
}
