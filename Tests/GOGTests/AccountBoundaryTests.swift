import XCTest
@testable import GOG

/// The identity boundary of the write-ahead log.
///
/// A stable idempotency key prevents DOUBLE-crediting. It does nothing whatsoever about
/// MIS-crediting. These tests exist because the original implementation recorded no user
/// identity at all, and every other test used a single fixed session — so no test could
/// express an account switch, and the hole survived a fully green suite.
final class AccountBoundaryTests: XCTestCase {

    private static let earnReplay = #"{"balance":110,"transaction_id":"tx-1","applied":false,"awarded":10,"source_coins":10,"pending_source_coins":0}"#

    private func dyingTransport() -> MockTransport {
        MockTransport { _, _ in throw GogError.network(.timedOut, retryable: false) }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // THE BUG. Player A earns, the process dies mid-request, player B signs in on the
    // same device. Before the fix, the sweep replayed A's operation with B's token and
    // the server credited B — valid token, unseen key, no error on any side.
    // ─────────────────────────────────────────────────────────────────────────────
    @MainActor
    func testPendingOpIsNotReplayedUnderADifferentAccount() async throws {
        let logURL = TestSupport.tempLogURL()

        // Player A earns; the request never completes.
        let dying = dyingTransport()
        let coinsA = try TestSupport.coins(transport: dying, logURL: logURL,
                                           session: TestSupport.playerA)
        _ = try? await coinsA.earn(100, reason: "boss-defeated")
        let pendingAfterA = await coinsA.pendingOperationCount()
        XCTAssertEqual(pendingAfterA, 1)

        // Player A signs out; player B signs in on the same device and the app sweeps.
        let live = MockTransport.fixed(200, Self.earnReplay)
        let coinsB = try TestSupport.coins(transport: live, logURL: logURL,
                                           session: TestSupport.playerB)
        let settled = await coinsB.reconcile()

        let sent = await live.callCount
        XCTAssertEqual(sent, 0, "player A's operation MUST NOT be sent under player B's token")
        XCTAssertTrue(settled.isEmpty, "nothing belonging to B was settled")

        // B's own scoped count is zero — B has no pending work.
        let bSees = await coinsB.pendingOperationCount()
        XCTAssertEqual(bSees, 0, "a scoped count must not surface another account's operations")

        // But A's op is KEPT on disk, not dropped — A may sign back in.
        let onDisk = try await IdempotencyLog(fileURL: logURL).pending()
        XCTAssertEqual(onDisk.map(\.userScope), [TestSupport.playerA.userScope],
                       "the other account's op is kept, not discarded")
    }

    /// The other half of the assertion, and the one that proves the fix did not simply
    /// disable reconciliation: when the ORIGINAL account returns, the op replays, with the
    /// ORIGINAL key and the CURRENT token.
    @MainActor
    func testOpReplaysWithOriginalKeyWhenTheOriginalAccountReturns() async throws {
        let logURL = TestSupport.tempLogURL()

        let dying = dyingTransport()
        let box = SessionBox(TestSupport.playerA)
        let coins1 = try TestSupport.coins(transport: dying, logURL: logURL, box: box)
        _ = try? await coins1.earn(100, reason: "boss-defeated")

        let firstKeys = await dying.idempotencyKeys()
        let originalKey = try XCTUnwrap(firstKeys.first)

        // B signs in and sweeps — nothing happens.
        let live = MockTransport.fixed(200, Self.earnReplay)
        let coins2 = try TestSupport.coins(transport: live, logURL: logURL, box: box)
        await box.signIn(as: TestSupport.playerB)
        _ = await coins2.reconcile()
        let sentUnderB = await live.callCount
        XCTAssertEqual(sentUnderB, 0)

        // A signs back in and sweeps — now it replays.
        await box.signIn(as: TestSupport.playerA)
        let settled = await coins2.reconcile()

        let keys = await live.idempotencyKeys()
        XCTAssertEqual(keys, [originalKey],
                       "the replay must reuse the ORIGINAL key — a fresh key is the double-credit bug")
        let auths = await live.authorizations
        XCTAssertEqual(auths, ["Bearer \(TestSupport.playerA.accessToken)"],
                       "and it must carry the returning account's token")
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled.first?.wasAlreadyApplied, true)

        let remaining = await coins2.pendingOperationCount()
        XCTAssertEqual(remaining, 0)
    }

    /// The scope is captured at MINT time, from the same read that supplies the token —
    /// not looked up later. A switch after the mint must not retag the operation.
    @MainActor
    func testScopeIsCapturedAtMintNotAtSweep() async throws {
        let logURL = TestSupport.tempLogURL()
        let box = SessionBox(TestSupport.playerA)

        let dying = dyingTransport()
        let coins = try TestSupport.coins(transport: dying, logURL: logURL, box: box)
        _ = try? await coins.earn(50)

        await box.signIn(as: TestSupport.playerB)

        let live = MockTransport.fixed(200, Self.earnReplay)
        let coinsB = try TestSupport.coins(transport: live, logURL: logURL, box: box)
        _ = await coinsB.reconcile()

        let sent = await live.callCount
        XCTAssertEqual(sent, 0, "the op stays tagged to A even though B is signed in now")
    }

    /// The sweep reads the session ONCE. Reading per-operation would let an account switch
    /// land mid-sweep and pair one account's token with another's scope — the same class of
    /// mismatch, reintroduced inside the fix.
    @MainActor
    func testSweepReadsTheSessionExactlyOnce() async throws {
        let logURL = TestSupport.tempLogURL()
        let log = IdempotencyLog(fileURL: logURL)
        for amount in [10, 20, 30] as [Int64] {
            try await log.record(PendingWalletOp(opId: UUID(), userScope: TestSupport.playerA.userScope,
                                                 gameId: TestSupport.gameId, kind: .earn,
                                                 amount: amount, reason: nil, createdAt: Date()))
        }

        let box = SessionBox(TestSupport.playerA)
        let live = MockTransport.fixed(200, Self.earnReplay)
        let coins = try GogCoins(configuration: TestSupport.configuration(),
                                 sessionProvider: box.provider,
                                 transport: live,
                                 idempotencyLog: log)

        let settled = await coins.reconcile()
        XCTAssertEqual(settled.count, 3)

        let reads = await box.readCount()
        XCTAssertEqual(reads, 1, "one snapshot for the whole sweep, not one per operation")
    }

    /// Mixed log: only the current account's operations move.
    @MainActor
    func testMixedLogSweepsOnlyTheCurrentAccount() async throws {
        let logURL = TestSupport.tempLogURL()
        let log = IdempotencyLog(fileURL: logURL)
        try await log.record(PendingWalletOp(opId: UUID(), userScope: TestSupport.playerA.userScope,
                                             gameId: TestSupport.gameId, kind: .earn,
                                             amount: 10, reason: nil, createdAt: Date()))
        try await log.record(PendingWalletOp(opId: UUID(), userScope: TestSupport.playerB.userScope,
                                             gameId: TestSupport.gameId, kind: .earn,
                                             amount: 20, reason: nil, createdAt: Date()))

        let live = MockTransport.fixed(200, Self.earnReplay)
        let coins = try GogCoins(configuration: TestSupport.configuration(),
                                 sessionProvider: { TestSupport.playerA },
                                 transport: live,
                                 idempotencyLog: log)

        let settled = await coins.reconcile()
        XCTAssertEqual(settled.count, 1)
        XCTAssertEqual(settled.first?.amount, 10)

        let remaining = try await log.pending()
        XCTAssertEqual(remaining.map(\.userScope), [TestSupport.playerB.userScope],
                       "B's op survives untouched")
    }

    // ─── THE SCHEMA ENVELOPE ─────────────────────────────────────────────────────
    // Adding userScope changed the on-disk shape. A bare-array file from the previous
    // build must not take the whole log down silently — `load()` throwing would be
    // swallowed by every `try?` call site and abandon real pending credits with no signal.
    func testLegacyBareArrayLogIsHandledLoudlyNotFatally() async throws {
        let url = TestSupport.tempLogURL()
        try Data(#"[{"opId":"00000000-0000-0000-0000-000000000001","gameId":"f07ff931-5e22-4414-a399-a85ec3c55b97","kind":"earn","amount":10,"createdAt":"2026-08-25T00:00:00Z"}]"#.utf8)
            .write(to: url)

        let log = IdempotencyLog(fileURL: url)
        let pending = try await log.pending()
        XCTAssertTrue(pending.isEmpty, "unreadable, but it must not throw its way out")

        // And the log must remain usable afterwards.
        let op = PendingWalletOp(opId: UUID(), userScope: "scope-A", gameId: TestSupport.gameId,
                                 kind: .earn, amount: 5, reason: nil, createdAt: Date())
        try await log.record(op)
        let after = try await log.pending()
        XCTAssertEqual(after.map(\.opId), [op.opId])
    }

    func testFutureSchemaVersionIsRefusedRatherThanMisread() async throws {
        let url = TestSupport.tempLogURL()
        try Data(#"{"version":99,"ops":[]}"#.utf8).write(to: url)
        let pending = try await IdempotencyLog(fileURL: url).pending()
        XCTAssertTrue(pending.isEmpty)
    }
}
