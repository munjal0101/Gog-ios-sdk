import XCTest
@testable import GOG

/// REGRESSION 3 — replay after process death, plus the ergonomics inversion.
final class IdempotencyTests: XCTestCase {

    private static let earnOK = #"{"balance":110,"transaction_id":"tx-1","applied":true,"awarded":10,"source_coins":10,"pending_source_coins":0}"#
    /// A REPLAY: the server already had this key with these parameters and returns the
    /// original outcome with applied == false. This is a SUCCESS, and it is the signal the
    /// write-ahead log resolves on.
    private static let earnReplay = #"{"balance":110,"transaction_id":"tx-1","applied":false,"awarded":10,"source_coins":10,"pending_source_coins":0}"#

    // ─────────────────────────────────────────────────────────────────────────────
    // The one that matters: the app dies mid-request, restarts, and the SAME key is
    // replayed — so the player is credited exactly once. On Android the attempt is simply
    // forgotten (lost win), and a game that retries itself mints a fresh key and
    // double-credits.
    // ─────────────────────────────────────────────────────────────────────────────
    @MainActor
    func testReplayAfterProcessDeathReusesTheOriginalKey() async throws {
        let logURL = TestSupport.tempLogURL()

        // ── run 1: the request never completes ──
        let dying = MockTransport { _, _ in
            throw GogError.network(.timedOut, retryable: false)
        }
        let coins1 = try TestSupport.coins(transport: dying, logURL: logURL)
        _ = try? await coins1.earn(10, reason: "boss-defeated")

        let firstKeys = await dying.idempotencyKeys()
        XCTAssertEqual(firstKeys.count, 1)
        let originalKey = try XCTUnwrap(firstKeys.first)

        // The op must have SURVIVED as pending — this is the whole point.
        let stillPending = await coins1.pendingOperationCount()
        XCTAssertEqual(stillPending, 1, "an unknown outcome must stay in the log")

        // ── run 2: fresh process, same log file on disk ──
        let alive = MockTransport.fixed(200, Self.earnReplay)
        let coins2 = try TestSupport.coins(transport: alive, logURL: logURL)

        let settled = await coins2.reconcile()

        let replayKeys = await alive.idempotencyKeys()
        XCTAssertEqual(replayKeys, [originalKey],
                       "the replay MUST reuse the original key — a fresh key here is the double-credit bug")
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled.first?.amount, 10)
        XCTAssertEqual(settled.first?.balanceAfter, 110)
        XCTAssertEqual(settled.first?.wasAlreadyApplied, true,
                       "applied == false means the first attempt HAD landed")

        let remaining = await coins2.pendingOperationCount()
        XCTAssertEqual(remaining, 0, "a settled op must be removed from the log")
    }

    /// A 2xx — including a replay — is definitive, so nothing is left pending.
    @MainActor
    func testSuccessfulEarnLeavesNothingPending() async throws {
        let transport = MockTransport.fixed(200, Self.earnOK)
        let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())
        _ = try await coins.earn(10)
        let pending = await coins.pendingOperationCount()
        XCTAssertEqual(pending, 0)
    }

    /// A decided failure must NOT linger — it will never apply.
    @MainActor
    func testDefinitiveFailureResolvesTheLogEntry() async throws {
        let transport = MockTransport.fixed(409, #"{"error":"insufficient_funds"}"#)
        let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())
        _ = try? await coins.spend(999)
        let pending = await coins.pendingOperationCount()
        XCTAssertEqual(pending, 0, "insufficient_funds is decided; the op will never apply")
    }

    /// An undecodable 200 most likely means the op DID apply. Keeping it costs one free
    /// replay; dropping it loses the player's coins. So it must stay pending.
    @MainActor
    func testMalformed200KeepsTheOpPendingRatherThanLosingIt() async throws {
        let transport = MockTransport.fixed(200, "not json at all")
        let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())
        _ = try? await coins.earn(10)
        let pending = await coins.pendingOperationCount()
        XCTAssertEqual(pending, 1,
                       "an undecodable 200 is an UNKNOWN outcome, not a decided one")
    }

    /// Recoverable auth failure: the op did not apply, and it should land after sign-in.
    @MainActor
    func testUnauthorizedKeepsTheOpPending() async throws {
        let transport = MockTransport.fixed(401, #"{"error":"unauthorized"}"#)
        let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())
        _ = try? await coins.earn(10)
        let pending = await coins.pendingOperationCount()
        XCTAssertEqual(pending, 1)
    }

    // ─── THE ERGONOMICS INVERSION ────────────────────────────────────────────────
    // On Android the convenience form is the DANGEROUS one. Here the convenience form is
    // SDK-managed and replay-safe, and owning your own key requires saying so explicitly.
    @MainActor
    func testConvenienceFormIsTheManagedOne() async throws {
        let transport = MockTransport { _, _ in
            throw GogError.network(.timedOut, retryable: false)
        }
        let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())
        _ = try? await coins.earn(10)
        let pending = await coins.pendingOperationCount()
        XCTAssertEqual(pending, 1, "the easy path must be the safe path")
    }

    @MainActor
    func testCallerSuppliedKeyIsNotManagedBySDK() async throws {
        let transport = MockTransport { _, _ in
            throw GogError.network(.timedOut, retryable: false)
        }
        let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())
        _ = try? await coins.earn(10, reason: nil, idempotencyKey: "level-7-complete")

        let pending = await coins.pendingOperationCount()
        XCTAssertEqual(pending, 0, "you asked to own replay safety; the SDK does not second-guess it")

        let keys = await transport.idempotencyKeys()
        XCTAssertEqual(keys, ["level-7-complete"], "the supplied key must be used verbatim")
    }

    /// awarded == 0 is a legitimate success (a small earn can round to zero GG Coins with
    /// the remainder carried), so it must decode as success rather than read as failure.
    @MainActor
    func testZeroAwardedIsASuccessNotAFailure() async throws {
        let body = #"{"balance":100,"transaction_id":"tx","applied":true,"awarded":0,"source_coins":3,"pending_source_coins":3}"#
        let transport = MockTransport.fixed(200, body)
        let coins = try TestSupport.coins(transport: transport, logURL: TestSupport.tempLogURL())
        let result = try await coins.earn(3)
        XCTAssertEqual(result.awarded, 0)
        XCTAssertEqual(result.pendingSourceCoins, 3)
        XCTAssertTrue(result.applied)
    }

    // ─── THE BOUNDED LOG ─────────────────────────────────────────────────────────
    func testLogEvictsOldestBeyondCapacity() async throws {
        let log = IdempotencyLog(fileURL: TestSupport.tempLogURL())
        let now = Date()
        for i in 0..<(IdempotencyLog.maxEntries + 5) {
            try await log.record(PendingWalletOp(opId: UUID(), userScope: "scope-A",
                                                 gameId: TestSupport.gameId,
                                                 kind: .earn, amount: Int64(i), reason: nil,
                                                 createdAt: now.addingTimeInterval(Double(i))),
                                 now: now.addingTimeInterval(Double(i)))
        }
        let pending = try await log.pending(now: now.addingTimeInterval(1000))
        XCTAssertEqual(pending.count, IdempotencyLog.maxEntries)
        XCTAssertEqual(pending.first?.amount, 5, "the five oldest were evicted, newest kept")
    }

    func testLogDropsEntriesOlderThanMaxAge() async throws {
        let log = IdempotencyLog(fileURL: TestSupport.tempLogURL())
        let now = Date()
        let old = now.addingTimeInterval(-(IdempotencyLog.maxAge + 60))
        try await log.record(PendingWalletOp(opId: UUID(), userScope: "scope-A", gameId: TestSupport.gameId,
                                             kind: .earn, amount: 1, reason: nil, createdAt: old), now: old)
        try await log.record(PendingWalletOp(opId: UUID(), userScope: "scope-A", gameId: TestSupport.gameId,
                                             kind: .earn, amount: 2, reason: nil, createdAt: now), now: now)
        let pending = try await log.pending(now: now)
        XCTAssertEqual(pending.map(\.amount), [2])
    }

    /// The log must survive a process boundary — that is its only job.
    func testLogPersistsAcrossInstances() async throws {
        let url = TestSupport.tempLogURL()
        let op = PendingWalletOp(opId: UUID(), userScope: "scope-A", gameId: TestSupport.gameId,
                                 kind: .spend, amount: 25, reason: "hint", createdAt: Date())
        try await IdempotencyLog(fileURL: url).record(op)

        let reopened = try await IdempotencyLog(fileURL: url).pending()
        XCTAssertEqual(reopened.count, 1)
        XCTAssertEqual(reopened.first?.opId, op.opId)
        XCTAssertEqual(reopened.first?.amount, 25)
        XCTAssertEqual(reopened.first?.reason, "hint")
    }
}
