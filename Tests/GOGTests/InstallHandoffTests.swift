import XCTest
@testable import GOG

/// The hub's App Store install handoff: tap a game in the hub, install it from the App Store,
/// open it — and it is already signed in to the hub's account.
final class InstallHandoffTests: XCTestCase {

    private static let user = "11111111-1111-4111-8111-111111111111"
    private static let exchangeOK = """
        {"access_token":"at","refresh_token":"rt","expires_at":1,"expires_in":3600,
         "token_type":"bearer","user":{"id":"\(user)","email":"p@example.com"}}
        """
    private var gameId: UUID { TestSupport.gameId }
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func identity(_ t: MockTransport,
                          handoff: InMemoryInstallHandoffStore,
                          store: InMemorySecureStore = InMemorySecureStore()) throws -> GogIdentity {
        let now = fixedNow
        return try GogIdentity(configuration: TestSupport.configuration(), store: store,
                               transport: t, installHandoff: handoff, now: { now })
    }

    private func handoff(_ code: String = "abc", expiresIn seconds: TimeInterval = 1800)
        -> InMemoryInstallHandoffStore {
        InMemoryInstallHandoffStore([gameId: InstallHandoff(
            code: code, expiresAt: fixedNow.addingTimeInterval(seconds))])
    }

    // ─── the contract with the hub ───────────────────────────────────────────

    func testDecodesWhatTheHubWrites() {
        // Exactly `JSON.stringify({ code, expires_at: new Date(...).toISOString() })`.
        let json = Data(#"{"code":"abc_-123","expires_at":"2026-11-24T12:30:00.000Z"}"#.utf8)
        let decoded = InstallHandoffContract.decode(json)
        XCTAssertEqual(decoded?.code, "abc_-123")
        XCTAssertEqual(decoded?.expiresAt, InstallHandoffContract.parseDate("2026-11-24T12:30:00Z"))
        XCTAssertNotNil(decoded?.expiresAt)
    }

    func testRejectsAnEmptyOrMalformedValue() {
        XCTAssertNil(InstallHandoffContract.decode(Data(#"{"code":""}"#.utf8)))
        XCTAssertNil(InstallHandoffContract.decode(Data("not json".utf8)))
    }

    func testAnUnparseableExpiryIsLeftToTheServer() {
        let decoded = InstallHandoffContract.decode(Data(#"{"code":"abc","expires_at":"soon"}"#.utf8))
        XCTAssertEqual(decoded?.code, "abc")
        XCTAssertNil(decoded?.expiresAt)
    }

    /// expo-secure-store stores the key as UTF-8 BYTES, and the hub keys by lower-case id.
    func testAccountIsTheLowerCaseGameIdAsBytes() {
        XCTAssertEqual(InstallHandoffContract.account(for: gameId),
                       Data(gameId.uuidString.lowercased().utf8))
    }

    func testSharedGroupKeepsTheTeamIdAndSwapsTheRest() {
        XCTAssertEqual(InstallHandoffContract.sharedGroup(fromDefaultGroup: "82K69CSWA7.online.godofgaming.crowdarena"),
                       "82K69CSWA7.online.godofgaming.shared")
        XCTAssertNil(InstallHandoffContract.sharedGroup(fromDefaultGroup: "no-team-prefix"))
        XCTAssertNil(InstallHandoffContract.sharedGroup(fromDefaultGroup: ".leading-dot"))
    }

    // ─── the flow ────────────────────────────────────────────────────────────

    func testAFreshInstallSignsInWithTheHubsCode() async throws {
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let store = handoff()
        let identity = try identity(t, handoff: store)

        let signedIn = try await identity.trySignInFromInstallHandoff()

        XCTAssertTrue(signedIn)
        let user = await identity.currentUser
        XCTAssertEqual(user?.id, Self.user)
        XCTAssertTrue(store.isEmpty, "single use: the code is deleted once taken")
    }

    func testNothingStoredIsASilentNoOp() async throws {
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let identity = try identity(t, handoff: InMemoryInstallHandoffStore())
        let result = try await identity.trySignInFromInstallHandoff()
        XCTAssertFalse(result)
        let calls = await t.callCount
        XCTAssertEqual(calls, 0)
    }

    func testAnExpiredCodeIsDroppedWithoutSpendingANetworkCall() async throws {
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let store = handoff(expiresIn: -1)
        let identity = try identity(t, handoff: store)
        let result = try await identity.trySignInFromInstallHandoff()
        XCTAssertFalse(result)
        let calls = await t.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(store.isEmpty, "a stale code must never be retried on a later launch")
    }

    func testAnExistingSessionIsNeverReplaced() async throws {
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let store = handoff("from-hub")
        let identity = try identity(t, handoff: store)
        _ = try await identity.signIn(code: "already", flow: .forwardLaunch)

        let result = try await identity.trySignInFromInstallHandoff()

        XCTAssertFalse(result)
        let calls = await t.callCount
        XCTAssertEqual(calls, 1, "only the explicit sign-in reached the server")
        XCTAssertTrue(store.isEmpty, "the unused code is still deleted")
    }

    func testARejectedCodeIsBroadcastAndThrown() async throws {
        let t = MockTransport.fixed(401, #"{"error":"invalid or expired code"}"#)
        let identity = try identity(t, handoff: handoff())
        let stream = await identity.eventStream()

        do {
            _ = try await identity.trySignInFromInstallHandoff()
            XCTFail("expected a throw")
        } catch let error as GogError {
            XCTAssertEqual(error, .invalidOrExpiredCode)
        }
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .signInStarted)
        let second = await iterator.next()
        guard case .launchSignInFailed = second else { return XCTFail("got \(String(describing: second))") }
    }

    // ─── installed already: the launch link carries the SAME code ────────────

    func testALaunchLinkDiscardsTheKeychainCopy() async throws {
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let store = handoff("abc")
        let identity = try identity(t, handoff: store)
        let url = URL(string: "https://link.godofgaming.online/launch/\(gameId.uuidString.lowercased())#code=abc")!

        _ = try await identity.trySignInFromLaunch(url: url)
        let later = try await identity.trySignInFromInstallHandoff()

        XCTAssertTrue(store.isEmpty)
        XCTAssertFalse(later)
        let calls = await t.callCount
        XCTAssertEqual(calls, 1, "the shared code is exchanged exactly once")
    }

    func testALaunchLinkAfterTheHandoffDoesNotSpendTheCodeTwice() async throws {
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let identity = try identity(t, handoff: handoff("abc"))
        let url = URL(string: "https://link.godofgaming.online/launch/\(gameId.uuidString.lowercased())#code=abc")!

        _ = try await identity.trySignInFromInstallHandoff()
        let handled = try await identity.trySignInFromLaunch(url: url)

        XCTAssertTrue(handled)
        let calls = await t.callCount
        XCTAssertEqual(calls, 1, "a second exchange would 401 and report a spurious failure")
    }
}

/// "Sign in with GOG" through the hub APP: the hub answers through the game's launch link,
/// and that link must reach the waiting sign-in rather than be exchanged a second time.
final class HubAppSignInTests: XCTestCase {

    /// Stands in for `HubAppSignInPresenter`: a sign-in is "waiting" until a link arrives.
    final class WaitingPresenter: WebAuthPresenter, LaunchCallbackReceiver, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var delivered: [URL] = []
        var isWaiting = true
        func authenticate(url: URL, callbackHost: String, callbackPath: String,
                          switchAccount: Bool) async throws -> URL {
            throw GogError.signInCancelled
        }
        func deliver(_ url: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard isWaiting else { return false }
            delivered.append(url)
            return true
        }
    }

    private var gameId: UUID { TestSupport.gameId }
    private var link: URL {
        URL(string: "https://link.godofgaming.online/launch/\(gameId.uuidString.lowercased())#code=abc")!
    }

    func testALaunchLinkGoesToTheWaitingSignInNotTheServer() async throws {
        let t = MockTransport.fixed(500, "{}")
        let presenter = WaitingPresenter()
        let identity = try GogIdentity(configuration: TestSupport.configuration(),
                                       store: InMemorySecureStore(), transport: t,
                                       webAuth: presenter,
                                       installHandoff: InMemoryInstallHandoffStore())

        let handled = try await identity.trySignInFromLaunch(url: link)

        XCTAssertTrue(handled)
        XCTAssertEqual(presenter.delivered, [link])
        let calls = await t.callCount
        XCTAssertEqual(calls, 0, "the waiting sign-in exchanges it, with its verifier")
    }

    func testWithNothingWaitingTheLinkIsExchangedAsUsual() async throws {
        let ok = """
            {"access_token":"at","refresh_token":"rt","expires_at":1,"expires_in":3600,
             "token_type":"bearer","user":{"id":"11111111-1111-4111-8111-111111111111","email":"p@example.com"}}
            """
        let t = MockTransport.fixed(200, ok)
        let presenter = WaitingPresenter()
        presenter.isWaiting = false
        let identity = try GogIdentity(configuration: TestSupport.configuration(),
                                       store: InMemorySecureStore(), transport: t,
                                       webAuth: presenter,
                                       installHandoff: InMemoryInstallHandoffStore())

        _ = try await identity.trySignInFromLaunch(url: link)

        XCTAssertTrue(presenter.delivered.isEmpty)
        let calls = await t.callCount
        XCTAssertEqual(calls, 1)
    }

    func testTheHubIsOpenedByItsAppSchemeNeverAWebPage() {
        let url = GogHubURL.reverseHandoff(gameId: gameId, codeChallenge: "c")
        XCTAssertEqual(url.absoluteString.hasPrefix("gullygames://game-auth?"), true)
    }
}
