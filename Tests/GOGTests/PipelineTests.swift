import XCTest
@testable import GOG

/// The three regressions that cost real time on Android, plus the mapping table.
final class PipelineTests: XCTestCase {

    // ─── REGRESSION 1 ────────────────────────────────────────────────────────────
    // A malformed 200. On Android this HUNG FOREVER: the parse threw inside a
    // try/finally with no catch, so neither callback ever fired and the game waited
    // forever. Here it must be a thrown, named error — and it must arrive.
    @MainActor
    func testMalformed200ThrowsAndDoesNotHang() async throws {
        let transport = MockTransport.fixed(200, "<!doctype html><html>gateway</html>")
        let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())

        do {
            _ = try await coins.balance()
            XCTFail("a malformed 200 must not succeed")
        } catch let error as GogError {
            XCTAssertEqual(error, .malformedResponse(missingField: nil))
        }
    }

    // ─── REGRESSION 2 ────────────────────────────────────────────────────────────
    // Valid JSON, wrong shape. On Android this produced balance = 0 — a WRONG SUCCESS,
    // and the worst kind, because zero is a plausible balance. Non-optional DTO
    // properties must turn it into a named failure instead.
    @MainActor
    func testWrongShape200ThrowsNamingTheFieldRatherThanReturningZero() async throws {
        // "blance" — a plausible typo, and exactly the shape of the real bug.
        let transport = MockTransport.fixed(200, #"{"blance": 500}"#)
        let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())

        do {
            let wallet = try await coins.balance()
            XCTFail("must not default-fill; got balance = \(wallet.balance)")
        } catch let error as GogError {
            XCTAssertEqual(error, .malformedResponse(missingField: "balance"),
                           "the missing field must be named, so support can see it")
        }
    }

    @MainActor
    func testWellFormed200Decodes() async throws {
        let transport = MockTransport.fixed(200, #"{"balance": 1234}"#)
        let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())
        let wallet = try await coins.balance()
        XCTAssertEqual(wallet.balance, 1234)
    }

    /// I9 — forward tolerance. An unknown field must not break parsing.
    @MainActor
    func testUnknownFieldsAreIgnored() async throws {
        let transport = MockTransport.fixed(200, #"{"balance": 7, "future_field": {"a": 1}}"#)
        let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())
        let wallet = try await coins.balance()
        XCTAssertEqual(wallet.balance, 7)
    }

    // ─── PATH ASYMMETRY ──────────────────────────────────────────────────────────
    // /me/wallet for the read, /wallet/earn and /wallet/spend for the writes. Different
    // prefixes, same wallet. Tidying this produces 404s against production, so it is
    // pinned by a test.
    @MainActor
    func testWalletPathAsymmetryIsMirroredVerbatim() async throws {
        let transport = MockTransport { request, _ in
            let body: String = request.url.path.contains("/me/wallet")
                ? #"{"balance": 1}"#
                : #"{"balance":1,"transaction_id":"t","applied":true,"awarded":1,"source_coins":1,"pending_source_coins":0}"#
            return (Data(body.utf8), GogWireResponse(status: 200, headers: [:]))
        }
        let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())

        _ = try await coins.balance()
        _ = try await coins.earn(5)
        _ = try await coins.spend(2)

        let paths = await transport.paths
        XCTAssertEqual(paths, ["/me/wallet", "/wallet/earn", "/wallet/spend"])
    }

    // ─── ERROR TAXONOMY ──────────────────────────────────────────────────────────
    @MainActor
    func testWireErrorsMapToTheOneTaxonomy() async throws {
        let cases: [(Int, String, GogError)] = [
            (401, #"{"error":"unauthorized"}"#,            .unauthorized),
            (428, #"{"error":"city_required"}"#,           .cityRequired),
            (409, #"{"error":"insufficient_funds"}"#,      .insufficientFunds),
            (409, #"{"error":"idempotency_key_reused"}"#,  .idempotencyKeyReused),
            (422, #"{"error":"earn_too_large"}"#,          .earnTooLarge),
            (400, #"{"error":"unknown_game"}"#,            .unknownGame),
            // BOTH spellings are real: "invalid_input" from the wallet RPC mapping (GC005),
            // "invalid input" from the handlers' own validation. Matching one and not the
            // other would silently bucket half of them as generic.
            (400, #"{"error":"invalid_input"}"#,           .invalidInput(field: nil)),
            (400, #"{"error":"invalid input"}"#,           .invalidInput(field: nil)),
            (500, #"{"error":"internal error"}"#,          .server),
        ]

        for (status, body, expected) in cases {
            let transport = MockTransport.fixed(status, body)
            let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())
            do {
                _ = try await coins.balance()
                XCTFail("\(status) \(body) should have thrown")
            } catch let error as GogError {
                XCTAssertEqual(error, expected, "for \(status) \(body)")
            }
        }
    }

    /// A non-JSON ERROR body must fall back to the status bucket, never mask the status
    /// with a parse failure. (GogHttp.cs does the same with a catch-and-return-nil.)
    @MainActor
    func testNonJsonErrorBodyFallsBackToStatus() async throws {
        let transport = MockTransport.fixed(503, "<html>502 Bad Gateway</html>")
        let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())
        do {
            _ = try await coins.balance()
            XCTFail("should have thrown")
        } catch let error as GogError {
            XCTAssertEqual(error, .server, "a non-JSON error body must not become .malformedResponse")
        }
    }

    @MainActor
    func testRateLimitedCarriesRetryAfter() async throws {
        let transport = MockTransport.fixed(429, #"{"error":"rate_limited"}"#,
                                            headers: ["retry-after": "30"])
        let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())
        do {
            _ = try await coins.balance()
            XCTFail("should have thrown")
        } catch let error as GogError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 30))
        }
    }

    // ─── RETRY POLICY ────────────────────────────────────────────────────────────
    @MainActor
    func testIdempotentRequestRetriesOnceOn5xx() async throws {
        let transport = MockTransport { _, attempt in
            attempt == 0
                ? (Data(#"{"error":"internal error"}"#.utf8), GogWireResponse(status: 500, headers: [:]))
                : (Data(#"{"balance": 42}"#.utf8), GogWireResponse(status: 200, headers: [:]))
        }
        let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())
        let wallet = try await coins.balance()
        XCTAssertEqual(wallet.balance, 42)
        let calls = await transport.callCount
        XCTAssertEqual(calls, 2, "exactly one retry, not more")
    }

    /// 429 is a considered signal from the server. Repeating it automatically makes the
    /// condition it reports worse, so it is surfaced rather than retried.
    @MainActor
    func test429IsNotRetried() async throws {
        let transport = MockTransport.fixed(429, #"{"error":"rate_limited"}"#)
        let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())
        _ = try? await coins.balance()
        let calls = await transport.callCount
        XCTAssertEqual(calls, 1)
    }
}
