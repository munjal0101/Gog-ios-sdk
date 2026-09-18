import XCTest
@testable import GOG

/// The two places the SDK parses input it did not create.
///
/// The launch link is the important one: it arrives from **outside the app**, chosen by whoever
/// sent the player there, and it is the single credential-bearing entry point in the whole SDK.
/// The existing tests check that the handful of shapes we thought of are handled. These check
/// the ones we did not think of — that nothing in the space of malformed input can crash the
/// game, and that no amount of creativity gets a foreign host or another game's id accepted.
///
/// Nothing here asserts a *specific* rejection reason. The property is the point: reject or
/// accept-correctly, never crash, never widen.
final class UntrustedInputTests: XCTestCase {

    private let gameId = TestSupport.gameId
    private var idString: String { gameId.uuidString.lowercased() }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: launch links
    // ─────────────────────────────────────────────────────────────────────────

    /// Everything a hostile or broken sender might put in front of us.
    private func hostileURLs() -> [String] {
        let id = idString
        var out: [String] = [
            // host games
            "https://link.godofgaming.online.evil.com/launch/\(id)",
            "https://evil.com/launch/\(id)",
            "https://link.godofgaming.online.evil.com./launch/\(id)",
            "https://LINK.GODOFGAMING.ONLINE/launch/\(id)",
            "https://link.godofgaming.online@evil.com/launch/\(id)",
            "https://evil.com@link.godofgaming.online/launch/\(id)",
            "https://link.godofgaming.online:443/launch/\(id)",
            "https://link.godofgaming.online:8443/launch/\(id)",
            "https://xn--link-godofgaming.online/launch/\(id)",
            // scheme games
            "http://link.godofgaming.online/launch/\(id)",
            "gogapp://link.godofgaming.online/launch/\(id)",
            "javascript:alert(1)",
            "file:///launch/\(id)",
            "data:text/html,<script>",
            // path games
            "https://link.godofgaming.online/launch/\(id)/../auth",
            "https://link.godofgaming.online/launch/\(id)%2F..%2Fauth",
            "https://link.godofgaming.online//launch/\(id)",
            "https://link.godofgaming.online/LAUNCH/\(id)",
            "https://link.godofgaming.online/launch/\(id)extra",
            "https://link.godofgaming.online/launch/\(id)/more",
            "https://link.godofgaming.online/launch/",
            "https://link.godofgaming.online/launch",
            "https://link.godofgaming.online/",
            "https://link.godofgaming.online",
            // id games
            "https://link.godofgaming.online/launch/00000000-0000-0000-0000-000000000000",
            "https://link.godofgaming.online/launch/not-a-uuid",
            "https://link.godofgaming.online/launch/\(id.uppercased())",
            "https://link.godofgaming.online/launch/\(String(id.dropLast()))",
            "https://link.godofgaming.online/launch/\(id)\(id)",
            // payload games
            "https://link.godofgaming.online/launch/\(id)#code=",
            "https://link.godofgaming.online/launch/\(id)#code=" + String(repeating: "A", count: 100_000),
            "https://link.godofgaming.online/launch/\(id)#code=a#code=b",
            "https://link.godofgaming.online/launch/\(id)?code=a#code=b",
            "https://link.godofgaming.online/launch/\(id)#code=%00%01%02",
            "https://link.godofgaming.online/launch/\(id)#code=" + String(repeating: "é🙂", count: 500),
        ]
        // plus structurally random noise
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("abcdefgh/:.%#?@-_0123456789[]{}\\ ")
        for _ in 0..<400 {
            let n = Int.random(in: 0...80, using: &rng)
            out.append(String((0..<n).map { _ in alphabet.randomElement(using: &rng)! }))
        }
        return out
    }

    /// 🔴 The property: never crash, and never accept something that is not exactly this game's
    /// launch link on the launch host.
    func testNoHostileLaunchURLIsEverAccepted() {
        var accepted: [String] = []
        for raw in hostileURLs() {
            guard let url = URL(string: raw) else { continue }   // unparseable is fine
            if let link = try? LaunchLinkValidator.validate(url, expecting: gameId) {
                accepted.append(raw)
                // If it WAS accepted, it must genuinely be ours, on the launch host.
                XCTAssertEqual(link.url.host?.lowercased(), "link.godofgaming.online", raw)
                XCTAssertTrue(link.url.path.lowercased().hasPrefix("/launch/"), raw)
                XCTAssertEqual(link.url.scheme?.lowercased(), "https", raw)
            }
        }
        // Only genuinely-correct forms may appear — stated as a normalised property rather than
        // a string prefix, because a case-different host and a `:443` port are both legitimately
        // the same URL and a prefix check calls them failures.
        for a in accepted {
            let u = URL(string: a)!
            XCTAssertEqual(u.scheme?.lowercased(), "https", a)
            XCTAssertEqual(u.host?.lowercased(), "link.godofgaming.online", a)
            XCTAssertNil(u.user, "userinfo must never survive validation: \(a)")
            XCTAssertTrue(u.port == nil || u.port == 443, "non-standard port accepted: \(a)")
            let segment = String(u.path.dropFirst("/launch/".count))
            XCTAssertEqual(UUID(uuidString: segment), gameId,
                           "accepted a link for a different game: \(a)")
        }
    }

    /// 🔴 Negative control: the sweep above must actually be exercising the validator, not
    /// rejecting everything for a trivial reason. The real link has to pass.
    func testTheGenuineLaunchLinkStillPasses() throws {
        let good = URL(string: "https://link.godofgaming.online/launch/\(idString)#code=abc")!
        let link = try LaunchLinkValidator.validate(good, expecting: gameId)
        let code = try LaunchLinkValidator.extractCode(from: link.url, delimiter: .fragment)
        XCTAssertEqual(code, "abc")
    }

    /// `extractCode` runs on attacker-shaped input too, and must never trap.
    func testExtractCodeNeverCrashesOnAnyValidatedShape() {
        for raw in hostileURLs() {
            guard let url = URL(string: raw) else { continue }
            _ = try? LaunchLinkValidator.extractCode(from: url, delimiter: .fragment)
            _ = try? LaunchLinkValidator.extractCode(from: url, delimiter: .query)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: ad directives
    //
    // Server-supplied, so lower stakes than a launch link — but a bug or a bad deploy upstream
    // must degrade to "no ad", never take the game down with it.
    // ─────────────────────────────────────────────────────────────────────────

    private static let realDirective = """
        {"type":"house","impression_id":"70f7c8c3-c601-445f-b718-d9209a75385c",
         "creative":{"id":"5cae7180-06bf-42c8-a556-0d55d2274894",
                     "image_url":"https://cdn.example.com/a.jpg","click_url":null,
                     "forced_view_seconds":10},
         "expires_at":"2026-08-27T09:52:03.268Z","expires_in":300}
        """

    func testNoMutationOfADirectiveEverCrashes() {
        let base = Array(Self.realDirective.utf8)
        var rng = SystemRandomNumberGenerator()

        // every truncation
        for cut in 0...base.count {
            _ = try? AdDirectiveInterpreter.interpret(Data(base.prefix(cut)))
        }
        // single-byte corruptions
        for _ in 0..<3000 {
            var bytes = base
            let i = Int.random(in: 0..<bytes.count, using: &rng)
            bytes[i] = UInt8.random(in: 0...255, using: &rng)
            _ = try? AdDirectiveInterpreter.interpret(Data(bytes))
        }
        // structured nonsense
        for body in ["", "{}", "[]", "null", "0", "\"x\"", "{\"type\":null}", "{\"type\":123}",
                     "{\"type\":\"house\"}", "{\"type\":\"house\",\"creative\":{}}",
                     "{\"type\":\"" + String(repeating: "x", count: 100_000) + "\"}",
                     String(repeating: "[", count: 5_000)] {
            _ = try? AdDirectiveInterpreter.interpret(Data(body.utf8))
        }
    }

    /// 🔴 Negative control for the sweep above: the real directive must still interpret, or the
    /// fuzz is proving only that everything fails.
    func testTheRealDirectiveStillInterprets() throws {
        guard case .house(let d) = try AdDirectiveInterpreter.interpret(Data(Self.realDirective.utf8))
        else { return XCTFail("the genuine directive must interpret as .house") }
        XCTAssertEqual(d.creative.forcedViewSeconds, 10)
        XCTAssertEqual(d.expiresIn, 300)
    }

    /// Whatever a mutation produces, `forcedViewSeconds` is inside the contract's bounds —
    /// there is no byte sequence that traps a player in an ad.
    func testNoDirectiveCanProduceAnOutOfRangeForcedView() {
        let base = Array(Self.realDirective.utf8)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<3000 {
            var bytes = base
            let i = Int.random(in: 0..<bytes.count, using: &rng)
            bytes[i] = UInt8.random(in: 0...255, using: &rng)
            if case .house(let d)? = try? AdDirectiveInterpreter.interpret(Data(bytes)) {
                XCTAssertGreaterThanOrEqual(d.creative.forcedViewSeconds,
                                            AdCreativeDTO.minForcedViewSeconds)
                XCTAssertLessThanOrEqual(d.creative.forcedViewSeconds,
                                         AdCreativeDTO.maxForcedViewSeconds)
            }
        }
    }
}
