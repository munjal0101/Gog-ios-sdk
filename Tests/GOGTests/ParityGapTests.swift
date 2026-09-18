import XCTest
@testable import GOG

/// A scripted web-auth presenter, so the whole reverse handoff is testable with no browser,
/// no entitlement and no Apple account.
actor ScriptedWebAuth: WebAuthPresenter {
    enum Outcome: Sendable { case callback(URL); case failure(GogError) }

    private let outcome: Outcome
    private(set) var calls = 0
    private(set) var lastURL: URL?
    private(set) var lastCallbackHost: String?
    private(set) var lastCallbackPath: String?
    private(set) var lastSwitchAccount = false

    init(_ outcome: Outcome) { self.outcome = outcome }

    func authenticate(url: URL, callbackHost: String, callbackPath: String,
                      switchAccount: Bool) async throws -> URL {
        calls += 1
        lastURL = url
        lastCallbackHost = callbackHost
        lastCallbackPath = callbackPath
        lastSwitchAccount = switchAccount
        switch outcome {
        case .callback(let u): return u
        case .failure(let e): throw e
        }
    }
}

/// The gaps found by auditing the shipped Android SDK rather than working from the contract
/// alone: launch dedupe, manual mode, `signInStarted`, `signInWithGog`, the settings fields,
/// and the boot-time catalogue check.
final class ParityGapTests: XCTestCase {

    private static let user = "11111111-1111-4111-8111-111111111111"
    private static let exchangeOK = """
        {"access_token":"at","refresh_token":"rt","expires_at":1,"expires_in":3600,
         "token_type":"bearer","user":{"id":"\(user)","email":"p@example.com"}}
        """
    private var gameId: UUID { TestSupport.gameId }
    private func launchURL(_ suffix: String = "#code=abc") -> URL {
        URL(string: "https://link.godofgaming.online/launch/\(gameId.uuidString.lowercased())\(suffix)")!
    }

    private func identity(_ t: MockTransport,
                          config: GogConfiguration? = nil,
                          webAuth: (any WebAuthPresenter)? = nil,
                          store: InMemorySecureStore = InMemorySecureStore()) throws -> GogIdentity {
        try GogIdentity(configuration: config ?? TestSupport.configuration(),
                        store: store, transport: t, webAuth: webAuth)
    }

    // ─── launch dedupe ───────────────────────────────────────────────────────
    /// 🔴 The cold-start URL persists in the launch options AND can re-arrive through the
    /// continue-user-activity path, so the same link is routinely delivered twice. A
    /// single-use code must be exchanged ONCE — a second exchange burns a dead code and
    /// surfaces a spurious failure to the player.
    func testTheSameLaunchLinkIsExchangedOnlyOnce() async throws {
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let identity = try identity(t)

        let first = try await identity.trySignInFromLaunch(url: launchURL())
        let second = try await identity.trySignInFromLaunch(url: launchURL())

        XCTAssertTrue(first)
        XCTAssertTrue(second, "a repeat is expected, not an error")
        let calls = await t.callCount
        XCTAssertEqual(calls, 1, "the code must be exchanged exactly once")
    }

    func testADifferentLaunchLinkIsStillHandled() async throws {
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let identity = try identity(t)
        _ = try await identity.trySignInFromLaunch(url: launchURL("#code=first"))
        _ = try await identity.trySignInFromLaunch(url: launchURL("#code=second"))
        let calls = await t.callCount
        XCTAssertEqual(calls, 2, "dedupe is per-URL, not a one-shot latch")
    }

    // ─── signInStarted ───────────────────────────────────────────────────────
    func testLaunchSignInAnnouncesItselfBeforeTheRoundTrip() async throws {
        let identity = try identity(MockTransport.fixed(200, Self.exchangeOK))
        let stream = await identity.eventStream()
        _ = try await identity.trySignInFromLaunch(url: launchURL())

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .signInStarted, "so a game can put up a spinner")
        let second = await iterator.next()
        guard case .signedIn = second else { return XCTFail("got \(String(describing: second))") }
    }

    // ─── manual mode ─────────────────────────────────────────────────────────
    /// `autoSignInFromLaunch = false` captures the code but does not spend it until the game
    /// asks — the mode the contract describes for games that own their own link plumbing.
    func testManualModeCapturesWithoutExchanging() async throws {
        let manual = GogConfiguration(gameId: gameId, autoSignInFromLaunch: false)
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let identity = try identity(t, config: manual)

        let handled = try await identity.trySignInFromLaunch(url: launchURL())
        XCTAssertTrue(handled)
        let calls = await t.callCount
        XCTAssertEqual(calls, 0, "manual mode must not spend the code on its own")
        let captured = await identity.hasCapturedLaunchCode
        XCTAssertTrue(captured)
        let session = await identity.currentSession
        XCTAssertFalse(session.isSignedIn)
    }

    func testManualModeExchangesWhenAsked() async throws {
        let manual = GogConfiguration(gameId: gameId, autoSignInFromLaunch: false)
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let identity = try identity(t, config: manual)
        _ = try await identity.trySignInFromLaunch(url: launchURL())

        let signedIn = try await identity.trySignInFromLaunch()
        XCTAssertTrue(signedIn)
        let session = await identity.currentSession
        XCTAssertTrue(session.isSignedIn)
        let still = await identity.hasCapturedLaunchCode
        XCTAssertFalse(still, "a captured code is single-use too")
    }

    /// "false ⇒ no launch code captured, callback will not fire" — the contract's words.
    func testManualModeWithNothingCapturedReturnsFalse() async throws {
        let manual = GogConfiguration(gameId: gameId, autoSignInFromLaunch: false)
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let identity = try identity(t, config: manual)
        let result = try await identity.trySignInFromLaunch()
        XCTAssertFalse(result)
        let calls = await t.callCount
        XCTAssertEqual(calls, 0)
    }

    func testAutoModeIsTheDefault() {
        XCTAssertTrue(GogConfiguration(gameId: gameId).autoSignInFromLaunch)
    }

    // ─── signInWithGog, end to end ───────────────────────────────────────────
    func testSignInWithGogRunsTheWholeReverseHandoff() async throws {
        let web = ScriptedWebAuth(.callback(launchURL("#code=returned")))
        let t = MockTransport.fixed(200, Self.exchangeOK)
        let identity = try identity(t, webAuth: web)

        let user = try await identity.signInWithGog()
        XCTAssertEqual(user.id, Self.user)

        // The browser was pointed at the HUB host…
        let opened = await web.lastURL
        XCTAssertEqual(opened?.host, GogHosts.hub)
        XCTAssertEqual(opened?.path, "/auth")
        // …and the callback was expected on the LINK host, at this game's own path.
        let host = await web.lastCallbackHost
        let path = await web.lastCallbackPath
        XCTAssertEqual(host, GogHosts.link)
        XCTAssertEqual(path, "/launch/\(gameId.uuidString.lowercased())")

        // The verifier matching the challenge sent to the hub was presented at exchange.
        let challenge = try XCTUnwrap(URLComponents(url: try XCTUnwrap(opened),
                                                    resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "code_challenge" }?.value)
        let sentVerifier = await t.stringBody("code_verifier", at: 0)
        let verifier = try XCTUnwrap(sentVerifier)
        XCTAssertEqual(Base64URL.encode(GogSHA256.hash(verifier)), challenge)
    }

    func testSignInWithGogPassesSwitchAccountThrough() async throws {
        let web = ScriptedWebAuth(.callback(launchURL("#code=x")))
        let identity = try identity(MockTransport.fixed(200, Self.exchangeOK), webAuth: web)
        _ = try await identity.signInWithGog(switchAccount: true)
        let ephemeral = await web.lastSwitchAccount
        XCTAssertTrue(ephemeral, "the 'not you?' path must not reuse shared cookies")
    }

    func testACancelledWebSignInSurfacesAsCancelledNotAsAFailure() async throws {
        let web = ScriptedWebAuth(.failure(.signInCancelled))
        let identity = try identity(MockTransport.fixed(200, Self.exchangeOK), webAuth: web)
        do {
            _ = try await identity.signInWithGog()
            XCTFail("should have thrown")
        } catch let error as GogError {
            XCTAssertEqual(error, .signInCancelled)
        }
    }

    /// The browser handing back a URL is not a reason to trust its shape.
    func testACallbackForAnotherGameIsRejected() async throws {
        let other = URL(string: "https://link.godofgaming.online/launch/\(UUID().uuidString)#code=x")!
        let web = ScriptedWebAuth(.callback(other))
        let identity = try identity(MockTransport.fixed(200, Self.exchangeOK), webAuth: web)
        do {
            _ = try await identity.signInWithGog()
            XCTFail("should have thrown")
        } catch let error as GogError {
            guard case .launchLinkInvalid(.gameIdMismatch) = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    /// Even a failed handoff must leave no half-open sign-in behind.
    func testAFailedHandoffClearsTheInProgressFlag() async throws {
        let web = ScriptedWebAuth(.failure(.signInCancelled))
        let identity = try identity(MockTransport.fixed(200, Self.exchangeOK), webAuth: web)
        _ = try? await identity.signInWithGog()
        let busy = await identity.isSignInInProgress
        XCTAssertFalse(busy)
    }

    // ─── the AdMob app-id trap ───────────────────────────────────────────────
    /// 🔴 The app id (`~`, a build setting) and the ad UNIT id (`/`, from the server) look
    /// nearly identical and are routinely swapped. Swapping them is a launch crash or a
    /// silent no-fill, and neither says what happened — so it fails at configure time.
    func testAdmobAppIdValidationRejectsAUnitId() {
        XCTAssertTrue(GogConfiguration.isValidAdmobAppId("ca-app-pub-1234567890123456~1234567890"))
        XCTAssertFalse(GogConfiguration.isValidAdmobAppId("ca-app-pub-1234567890123456/1234567890"),
                       "that is an ad UNIT id — note the slash")
        XCTAssertFalse(GogConfiguration.isValidAdmobAppId("ca-app-pub-123~1234567890"))
        XCTAssertFalse(GogConfiguration.isValidAdmobAppId(""))
    }

    func testAConfigurationWithAUnitIdFailsAtConfigureTime() async {
        let bad = GogConfiguration(gameId: gameId,
                                   admobAppId: "ca-app-pub-1234567890123456/1234567890")
        do {
            _ = try GogIdentity(configuration: bad, store: InMemorySecureStore(),
                                transport: MockTransport.fixed(200, "{}"))
            XCTFail("should have thrown at configure time, not at first ad")
        } catch let error as GogError {
            guard case .notConfigured = error else { return XCTFail("got \(error)") }
        } catch { XCTFail("wrong error type") }
    }

    func testAValidAdmobAppIdConfigures() throws {
        let ok = GogConfiguration(gameId: gameId,
                                  admobAppId: "ca-app-pub-1234567890123456~1234567890")
        XCTAssertNoThrow(try GogIdentity(configuration: ok, store: InMemorySecureStore(),
                                         transport: MockTransport.fixed(200, "{}")))
    }

    // ─── the boot-time catalogue check ───────────────────────────────────────
    /// It must FAIL OPEN. Refusing to boot because the catalogue was unreachable is a worse
    /// failure than the misconfiguration it guards against.
    func testCatalogueCheckSaysNothingWhenItCannotTell() async {
        let unreachable = MockTransport { _, _ in
            throw GogError.network(.offline, retryable: true)
        }
        await GOG.verifyCatalogueEntry(TestSupport.configuration(), transport: unreachable)
        // No throw, no crash. The absence of an opinion IS the behaviour under test.
    }

    func testCatalogueCheckAcceptsANativeGame() async {
        let rows = """
            [{"id":"\(gameId.uuidString.lowercased())","kind":"native","slug":"tennis"}]
            """
        await GOG.verifyCatalogueEntry(TestSupport.configuration(),
                                       transport: MockTransport.fixed(200, rows))
    }

    /// The only thing that catches a wrong game id at all: /ads/next answers
    /// 200 {"type":"none"} for a well-formed but unknown id, so a game shipped with the wrong
    /// UUID earns nothing forever with no error anywhere.
    func testCatalogueCheckHandlesAnUnknownGameId() async {
        let rows = """
            [{"id":"99999999-9999-4999-8999-999999999999","kind":"native","slug":"other"}]
            """
        await GOG.verifyCatalogueEntry(TestSupport.configuration(),
                                       transport: MockTransport.fixed(200, rows))
    }

    func testCatalogueCheckToleratesAServerThatStoppedSendingKind() async {
        let rows = """
            [{"id":"\(gameId.uuidString.lowercased())","slug":"tennis"}]
            """
        await GOG.verifyCatalogueEntry(TestSupport.configuration(),
                                       transport: MockTransport.fixed(200, rows))
    }
}
