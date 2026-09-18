import XCTest
@testable import GOG

/// The wallet's two invariants, as properties over randomised histories.
///
/// `IdempotencyTests` and `AccountBoundaryTests` check the cases someone thought of, one
/// scripted scenario at a time. These generate thousands of interleavings nobody thought of and
/// assert the two things that must hold across all of them — because both failure modes here
/// are silent and neither is recoverable:
///
///   **I. No lost coins.** An operation leaves the log ONLY on an outcome the SDK is certain
///   about. Any run of uncertain outcomes must leave it pending, however long.
///
///   **II. No mis-crediting.** An idempotency key minted while account A was signed in must
///   never travel on a request bearing account B's token. This is the bug that a fully green
///   suite once hid, because every test used one fixed session.
final class WalletPropertyTests: XCTestCase {

    private static let ok = #"{"balance":110,"transaction_id":"t","applied":true,"awarded":10,"source_coins":10,"pending_source_coins":0}"#

    /// The outcomes an earn can meet, split by whether the SDK can be CERTAIN what happened.
    private enum Outcome: CaseIterable {
        case success              // decided: applied
        case insufficientFunds    // decided: the server refused, definitively
        case timeout              // undecided: may or may not have applied
        case malformed200         // undecided: probably applied, undecodable
        case unauthorized         // undecided: token problem, says nothing about the write
        case serverError          // undecided: transient

        var isDecided: Bool {
            switch self {
            case .success, .insufficientFunds: return true
            case .timeout, .malformed200, .unauthorized, .serverError: return false
            }
        }

        func respond() throws -> (Data, GogWireResponse) {
            switch self {
            case .success:
                return (Data(WalletPropertyTests.ok.utf8), GogWireResponse(status: 200, headers: [:]))
            case .insufficientFunds:
                return (Data(#"{"error":"insufficient_funds"}"#.utf8),
                        GogWireResponse(status: 409, headers: [:]))
            case .timeout:      throw GogError.network(.timedOut, retryable: false)
            case .malformed200: return (Data("{".utf8), GogWireResponse(status: 200, headers: [:]))
            case .unauthorized: return (Data(#"{"error":"unauthorized"}"#.utf8),
                                        GogWireResponse(status: 401, headers: [:]))
            case .serverError:  return (Data(#"{"error":"internal error"}"#.utf8),
                                        GogWireResponse(status: 500, headers: [:]))
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // I. No lost coins
    // ─────────────────────────────────────────────────────────────────────────

    /// 🔴 Erring toward keeping costs at most one redundant request. Erring toward resolving
    /// loses a player's coins permanently — so an UNDECIDED outcome must never clear an entry,
    /// no matter how many of them arrive in a row.
    @MainActor
    func testAnUndecidedOutcomeNeverClearsAnEntry() async throws {
        var rng = SystemRandomNumberGenerator()
        let undecided = Outcome.allCases.filter { !$0.isDecided }

        for trial in 0..<120 {
            let logURL = TestSupport.tempLogURL()
            let script = (0..<Int.random(in: 1...5, using: &rng))
                .map { _ in undecided.randomElement(using: &rng)! }

            // `attempt` is supplied by MockTransport, so no captured mutable state crosses
            // into the concurrent closure.
            let transport = MockTransport { _, attempt in
                try script[min(attempt, script.count - 1)].respond()
            }
            let coins = try TestSupport.coins(transport: transport, logURL: logURL,
                                              session: TestSupport.playerA)
            _ = try? await coins.earn(10, reason: "r")
            for _ in 0..<script.count { _ = await coins.reconcile() }

            let pending = try await IdempotencyLog(fileURL: logURL).pending()
            XCTAssertEqual(pending.count, 1,
                           "trial \(trial): \(script) — an undecided outcome dropped the entry, "
                           + "which is a player's coins gone for good")
        }
    }

    /// 🔴 Negative control for the property above. A DECIDED outcome must clear it — otherwise
    /// the test would pass against a log that simply never resolves anything, and the queue
    /// would grow forever replaying settled work.
    @MainActor
    func testADecidedOutcomeAlwaysClearsTheEntry() async throws {
        for outcome in Outcome.allCases where outcome.isDecided {
            let logURL = TestSupport.tempLogURL()
            let transport = MockTransport { _, _ in try outcome.respond() }
            let coins = try TestSupport.coins(transport: transport, logURL: logURL,
                                              session: TestSupport.playerA)
            _ = try? await coins.earn(10, reason: "r")
            let pending = try await IdempotencyLog(fileURL: logURL).pending()
            XCTAssertEqual(pending.count, 0, "\(outcome) is decided; the entry must be cleared")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // II. No mis-crediting
    // ─────────────────────────────────────────────────────────────────────────

    /// 🔴 The property the original implementation could not even express: over randomised
    /// interleavings of two accounts, no idempotency key ever travels under the other account's
    /// token. Checked by correlating every request's key against its bearer token.
    @MainActor
    func testNoKeyEverTravelsUnderAnotherAccountsToken() async throws {
        var rng = SystemRandomNumberGenerator()

        for trial in 0..<80 {
            let logURL = TestSupport.tempLogURL()
            // key -> the token it was FIRST seen with
            let seen = KeyLedger()

            func makeCoins(_ session: GogSessionSnapshot) throws -> (GogCoins, MockTransport) {
                let t = MockTransport { request, attempt in
                    let token = request.headers["Authorization"] ?? "<none>"
                    if let body = request.body,
                       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                       let key = json["idempotency_key"] as? String {
                        seen.record(key: key, token: token)
                    }
                    // Mostly fail, so operations pile up in the log and get swept later.
                    // Derived from `attempt` rather than a captured RNG: deterministic per
                    // request, and no mutable state crosses into the closure.
                    if attempt % 3 != 2 {
                        throw GogError.network(.timedOut, retryable: false)
                    }
                    return (Data(Self.ok.utf8), GogWireResponse(status: 200, headers: [:]))
                }
                return (try TestSupport.coins(transport: t, logURL: logURL, session: session), t)
            }

            // A random walk between the two accounts, earning and sweeping.
            for _ in 0..<Int.random(in: 2...10, using: &rng) {
                let session = Bool.random(using: &rng) ? TestSupport.playerA : TestSupport.playerB
                let (coins, _) = try makeCoins(session)
                switch Int.random(in: 0...2, using: &rng) {
                case 0: _ = try? await coins.earn(Int64.random(in: 1...50, using: &rng), reason: "r")
                case 1: _ = await coins.reconcile()
                default:
                    _ = try? await coins.earn(5, reason: "r")
                    _ = await coins.reconcile()
                }
            }

            XCTAssertTrue(seen.violations.isEmpty,
                          "trial \(trial): a key crossed the account boundary — "
                          + "\(seen.violations). This is the mis-crediting bug: valid token, "
                          + "unseen key, the wrong player credited, no error anywhere.")
        }
    }

    /// 🔴 Negative control for the ledger itself: if it could not detect a crossing, the test
    /// above would be vacuous. Feed it one by hand and confirm it complains.
    func testTheLedgerActuallyDetectsACrossing() {
        let ledger = KeyLedger()
        ledger.record(key: "k1", token: "Bearer token-A")
        ledger.record(key: "k1", token: "Bearer token-A")
        XCTAssertTrue(ledger.violations.isEmpty, "the same key under the same token is normal")
        ledger.record(key: "k1", token: "Bearer token-B")
        XCTAssertEqual(ledger.violations.count, 1)
    }
}

/// Records which bearer token each idempotency key was first seen with, and flags any key that
/// later appears under a different one.
final class KeyLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var firstToken: [String: String] = [:]
    private var found: [String] = []

    func record(key: String, token: String) {
        lock.lock(); defer { lock.unlock() }
        if let existing = firstToken[key] {
            if existing != token { found.append("\(key): \(existing) -> \(token)") }
        } else {
            firstToken[key] = token
        }
    }

    var violations: [String] {
        lock.lock(); defer { lock.unlock() }
        return found
    }
}
