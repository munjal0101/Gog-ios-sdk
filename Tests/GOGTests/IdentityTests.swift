import XCTest
@testable import GOG

final class CryptoTests: XCTestCase {
    /// NIST FIPS 180-4 vectors. They pin BOTH paths — CryptoKit on Apple platforms and the
    /// portable fallback on Linux CI — so the fallback cannot quietly diverge.
    func testSHA256NISTVectors() {
        XCTAssertEqual(hex(GogSHA256.hash("")),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(GogSHA256.hash("abc")),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(GogSHA256.hash("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    /// The fallback must agree with whatever the platform provides, byte for byte.
    func testFallbackMatchesPlatformImplementation() {
        for sample in ["", "a", "gog", String(repeating: "x", count: 1000), UUID().uuidString] {
            XCTAssertEqual(GogSHA256.fallback(Data(sample.utf8)),
                           GogSHA256.hash(Data(sample.utf8)),
                           "divergence on \(sample.prefix(20))")
        }
    }

    func testBase64URLHasNoPaddingOrUnsafeCharacters() {
        for _ in 0..<50 {
            let encoded = Base64URL.encode(Base64URL.randomBytes(32))
            XCTAssertEqual(encoded.count, 43)
            XCTAssertNil(encoded.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

final class PKCETests: XCTestCase {

    /// Both regexes were read from services/api/src/index.ts, not assumed.
    func testGeneratedPairMatchesTheServersValidatorsExactly() throws {
        let verifierRE = try NSRegularExpression(pattern: "^[A-Za-z0-9\\-._~]{43,128}$")
        let challengeRE = try NSRegularExpression(pattern: "^[A-Za-z0-9_-]{43}$")
        for _ in 0..<100 {
            let pair = PKCEPair.generate()
            XCTAssertTrue(matches(verifierRE, pair.verifier), "verifier: \(pair.verifier)")
            XCTAssertTrue(matches(challengeRE, pair.challenge), "challenge: \(pair.challenge)")
            // S256: challenge == base64url(SHA-256(ASCII(verifier)))
            XCTAssertEqual(pair.challenge, Base64URL.encode(GogSHA256.hash(pair.verifier)))
        }
    }

    func testVerifiersAreNotReused() {
        let generated = Set((0..<200).map { _ in PKCEPair.generate().verifier })
        XCTAssertEqual(generated.count, 200)
    }

    /// 🔴 The reason the verifier is persisted at all: an in-memory one is lost to a jetsam,
    /// and a missing verifier BURNS the code.
    func testVerifierSurvivesProcessDeath() async throws {
        let store = InMemorySecureStore()
        let gameId = TestSupport.gameId

        // Process 1 begins the flow, then dies.
        let issued = try await PKCEFlowStore(store: store).begin(gameId: gameId)

        // Process 2, same Keychain, code comes back.
        let recovered = await PKCEFlowStore(store: store).consume(gameId: gameId)
        XCTAssertEqual(recovered, issued.verifier)
    }

    func testFlowIsSingleUse() async throws {
        let store = InMemorySecureStore()
        _ = try await PKCEFlowStore(store: store).begin(gameId: TestSupport.gameId)
        let flows = PKCEFlowStore(store: store)
        let first = await flows.consume(gameId: TestSupport.gameId)
        XCTAssertNotNil(first)
        let second = await flows.consume(gameId: TestSupport.gameId)
        XCTAssertNil(second, "one flow, one use")
    }

    func testExpiredFlowIsDiscarded() async throws {
        let store = InMemorySecureStore()
        let start = Date()
        _ = try await PKCEFlowStore(store: store).begin(gameId: TestSupport.gameId, now: start)
        let late = start.addingTimeInterval(PKCEFlowStore.flowTTL + 1)
        let recovered = await PKCEFlowStore(store: store).consume(gameId: TestSupport.gameId, now: late)
        XCTAssertNil(recovered)
    }

    func testFlowForAnotherGameIsDiscarded() async throws {
        let store = InMemorySecureStore()
        _ = try await PKCEFlowStore(store: store).begin(gameId: TestSupport.gameId)
        let other = UUID()
        let recovered = await PKCEFlowStore(store: store).consume(gameId: other)
        XCTAssertNil(recovered)
    }

    /// If the verifier cannot be persisted the flow must not start — starting it would
    /// guarantee a burnt code on the return leg.
    func testBeginFailsClosedWhenTheStoreCannotWrite() async {
        let store = InMemorySecureStore()
        store.failWrites = true
        do {
            _ = try await PKCEFlowStore(store: store).begin(gameId: TestSupport.gameId)
            XCTFail("must not start a flow whose verifier was not persisted")
        } catch {}
    }

    private func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

final class LaunchLinkTests: XCTestCase {
    private let gameId = TestSupport.gameId

    func testValidLinkPasses() throws {
        let url = URL(string: "https://link.godofgaming.online/launch/\(gameId.uuidString.lowercased())")!
        let link = try LaunchLinkValidator.validate(url, expecting: gameId)
        XCTAssertEqual(link.gameId, gameId)
    }

    func testWrongHostIsRejectedLoudly() {
        let url = URL(string: "https://evil.example.com/launch/\(gameId.uuidString)")!
        assertProblem(url) {
            if case .wrongHost = $0 { return true }; return false
        }
    }

    func testHttpIsRejected() {
        let url = URL(string: "http://link.godofgaming.online/launch/\(gameId.uuidString)")!
        assertProblem(url) { $0 == .notHTTPS }
    }

    /// A genuinely unrelated path on the link host. `/auth` is deliberately NOT the example
    /// any more: since the two-host split it gets the more specific `.hostRoleMismatch`
    /// diagnosis, and using it here would test the wrong classification.
    func testNonLaunchPathIsRejected() {
        let url = URL(string: "https://link.godofgaming.online/privacy")!
        assertProblem(url) { if case .notLaunchPath = $0 { return true }; return false }
    }

    /// The check Android's `pathPrefix` cannot make: `/launch/<uuid>anything-else` matches
    /// there and is validated nowhere. Here it is rejected.
    func testLooseSuffixIsRejected() {
        let url = URL(string: "https://link.godofgaming.online/launch/\(gameId.uuidString)-extra")!
        assertProblem(url) { if case .malformedGameIdSegment = $0 { return true }; return false }
    }

    func testExtraPathSegmentIsRejected() {
        let url = URL(string: "https://link.godofgaming.online/launch/\(gameId.uuidString)/more")!
        assertProblem(url) { if case .malformedGameIdSegment = $0 { return true }; return false }
    }

    /// A well-formed UUID for a DIFFERENT game: real link, wrong app. Distinct from
    /// malformed, because it points at AASA or the manifest rather than a typo.
    func testAnotherGamesLinkIsRejectedDistinctly() {
        let other = UUID()
        let url = URL(string: "https://link.godofgaming.online/launch/\(other.uuidString)")!
        assertProblem(url) {
            if case .gameIdMismatch(let expected, let got) = $0 {
                return expected == self.gameId && got == other
            }
            return false
        }
    }

    func testHostMatchIsCaseInsensitive() throws {
        let url = URL(string: "https://LINK.GODOFGAMING.ONLINE/launch/\(gameId.uuidString)")!
        XCTAssertNoThrow(try LaunchLinkValidator.validate(url, expecting: gameId))
    }

    private func assertProblem(_ url: URL, _ check: (LaunchLinkProblem) -> Bool,
                              file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try LaunchLinkValidator.validate(url, expecting: gameId)
            XCTFail("expected a thrown error, not a silent return", file: file, line: line)
        } catch let error as GogError {
            guard case .launchLinkInvalid(let problem) = error else {
                return XCTFail("wrong error: \(error)", file: file, line: line)
            }
            XCTAssertTrue(check(problem), "unexpected problem: \(problem)", file: file, line: line)
        } catch {
            XCTFail("unexpected error type", file: file, line: line)
        }
    }
}

/// The two-host split. Nothing pinned this before, and the whole point of the split is that
/// the two hosts have DISTINCT roles — collapsing them re-creates the same-domain condition
/// TN3155 says stops the app opening, which strands a live credential in Safari.
final class TwoHostSplitTests: XCTestCase {
    private let gameId = TestSupport.gameId

    func testHostsAreDistinct() {
        XCTAssertNotEqual(GogHosts.hub, GogHosts.link)
        XCTAssertEqual(GogHosts.hub, "hub.godofgaming.online")
        XCTAssertEqual(GogHosts.link, "link.godofgaming.online")
    }

    // ─── the two crossings, which are what the split exists to prevent ───────
    func testLaunchLinkOnTheHubHostIsRejected() {
        let url = URL(string: "https://hub.godofgaming.online/launch/\(gameId.uuidString)")!
        assertRoleMismatch(url)
    }

    func testAuthLinkOnTheLinkHostIsRejected() {
        let url = URL(string: "https://link.godofgaming.online/auth?game_id=\(gameId.uuidString)")!
        assertRoleMismatch(url)
    }

    func testAuthSubPathOnTheLinkHostIsRejected() {
        let url = URL(string: "https://link.godofgaming.online/auth/callback")!
        assertRoleMismatch(url)
    }

    /// A role mismatch must be diagnosably different from a stranger linking at us: one is
    /// our own misconfiguration, the other is background noise.
    func testRoleMismatchIsDistinctFromAForeignHost() {
        let foreign = URL(string: "https://evil.example.com/launch/\(gameId.uuidString)")!
        do {
            _ = try LaunchLinkValidator.validate(foreign, expecting: gameId)
            XCTFail("should have thrown")
        } catch let error as GogError {
            guard case .launchLinkInvalid(let problem) = error else { return XCTFail("\(error)") }
            if case .hostRoleMismatch = problem {
                XCTFail("a foreign host is not a role mismatch")
            }
        } catch { XCTFail("unexpected error") }
    }

    func testLaunchLinkOnTheLinkHostStillPasses() throws {
        let url = URL(string: "https://link.godofgaming.online/launch/\(gameId.uuidString)")!
        XCTAssertNoThrow(try LaunchLinkValidator.validate(url, expecting: gameId))
    }

    // ─── the hub URL builder ─────────────────────────────────────────────────
    func testHubURLTargetsTheHubHostAndCarriesTheChallenge() throws {
        let challenge = PKCEPair.generate().challenge
        let url = GogHubURL.reverseHandoff(gameId: gameId, codeChallenge: challenge)

        XCTAssertEqual(url.host, GogHosts.hub, "the reverse handoff must NOT go to the link host")
        XCTAssertEqual(url.path, "/auth")
        XCTAssertEqual(url.scheme, "https")

        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "game_id" }?.value, gameId.uuidString.lowercased())
        XCTAssertEqual(items.first { $0.name == "code_challenge" }?.value, challenge)
    }

    /// No attacker-supplied return target anywhere in the flow — the hub derives it from
    /// game_id against the catalogue. The open-redirect class is structurally absent.
    func testHubURLCarriesNoRedirectParameter() {
        let url = GogHubURL.reverseHandoff(gameId: gameId, codeChallenge: "c")
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.map(\.name) ?? []
        XCTAssertEqual(Set(names), ["game_id", "code_challenge"])
    }

    private func assertRoleMismatch(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try LaunchLinkValidator.validate(url, expecting: gameId)
            XCTFail("expected rejection", file: file, line: line)
        } catch let error as GogError {
            guard case .launchLinkInvalid(let problem) = error,
                  case .hostRoleMismatch = problem else {
                return XCTFail("expected hostRoleMismatch, got \(error)", file: file, line: line)
            }
        } catch { XCTFail("unexpected error type", file: file, line: line) }
    }
}
