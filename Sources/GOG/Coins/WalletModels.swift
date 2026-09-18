import Foundation

/// `GET /me/wallet` → `{ "balance": <long> }`
///
/// One non-optional property. A 200 that does not contain `balance` therefore throws
/// `.malformedResponse(missingField: "balance")`. It does NOT produce `balance == 0`,
/// which is what the C# path used to do — a wrong success, and the hardest kind of bug to
/// see, because zero is a perfectly plausible balance.
public struct Wallet: Decodable, Sendable, Equatable {
    public let balance: Int64

    private enum CodingKeys: String, CodingKey { case balance }
}

public enum WalletOpKind: String, Codable, Sendable {
    case earn, spend
}

/// `POST /wallet/spend` → `{ balance, transaction_id, applied }`
public struct SpendResult: Decodable, Sendable, Equatable {
    public let balance: Int64
    /// Decoded as a String, not a UUID, on purpose: the shape is verified but the *format*
    /// is not, and a format assumption here would turn a cosmetic server change into a
    /// hard `.malformedResponse` on a field games do not branch on.
    public let transactionId: String
    /// `false` means this was a REPLAY — the server already had this idempotency_key with
    /// these parameters and returned the original outcome. A replay is a success, and it is
    /// the signal the write-ahead log resolves on.
    public let applied: Bool

    private enum CodingKeys: String, CodingKey {
        case balance
        case transactionId = "transaction_id"
        case applied
    }
}

/// `POST /wallet/earn` → `{ balance, transaction_id, applied, awarded, source_coins,
/// pending_source_coins }`
///
/// Earn returns strictly MORE than spend. That asymmetry is real and is modelled with two
/// types rather than one loose type with optionals — a shared type would have to make
/// `awarded` optional, which would re-open exactly the default-filling hole that
/// non-optional properties exist to close.
public struct EarnResult: Decodable, Sendable, Equatable {
    public let balance: Int64
    public let transactionId: String
    public let applied: Bool
    /// GG Coins that actually moved — the CONVERTED figure.
    ///
    /// ⚠️ `awarded == 0` is a legitimate success, not a failure: the game's own currency
    /// converts at a per-game rate and a small earn can round to zero GG Coins with the
    /// remainder carried in `pendingSourceCoins`. Do not treat zero as an error.
    public let awarded: Int64
    /// The game-currency amount the server attributed to this call.
    public let sourceCoins: Int64
    /// Game-currency remainder carried forward, so a game can show "3 more to go".
    public let pendingSourceCoins: Int64

    private enum CodingKeys: String, CodingKey {
        case balance
        case transactionId = "transaction_id"
        case applied
        case awarded
        case sourceCoins = "source_coins"
        case pendingSourceCoins = "pending_source_coins"
    }
}

/// The body of a wallet apply. snake_case because the API maps by exact field name.
struct WalletApplyBody: Encodable, Sendable {
    let gameId: UUID
    let amount: Int64
    let idempotencyKey: String
    let reason: String?

    private enum CodingKeys: String, CodingKey {
        case gameId = "game_id"
        case amount
        case idempotencyKey = "idempotency_key"
        case reason
    }
}

/// One entry in the write-ahead log: an operation that has been *decided* but whose
/// server-side outcome is not yet known.
struct PendingWalletOp: Codable, Sendable, Equatable {
    /// Becomes `idempotency_key` on the wire. Stable across every replay of this operation —
    /// that stability is the entire safety property against DOUBLE-crediting.
    let opId: UUID

    /// Whose operation this is — the opaque `GogSessionSnapshot.userScope` captured at mint
    /// time.
    ///
    /// 🔴 THIS FIELD IS LOAD-BEARING. A stable key prevents double-crediting; it does
    /// nothing at all about MIS-crediting. Without this field: player A earns, the process
    /// dies, player B signs in on the same device, and the sweep replays A's operation with
    /// B's token. The server sees a valid token and an unseen key, and credits B. A's coins
    /// are gone, B has extra, and no error is raised anywhere on either side. "Lost win"
    /// would have become "wrong player credited", which is strictly worse.
    ///
    /// It also closes the backup vector: a device backup restored under a different account
    /// carries this log with it, and scope matching means none of it replays.
    let userScope: String

    let gameId: UUID
    let kind: WalletOpKind
    let amount: Int64
    /// Game-supplied text, persisted verbatim to a plaintext file that is eligible for
    /// device backup. Do not put secrets or personal data in it.
    let reason: String?
    let createdAt: Date
}

/// What a reconciliation sweep settled.
public struct ReconciledOp: Sendable, Equatable {
    public let kind: WalletOpKind
    public let amount: Int64
    public let balanceAfter: Int64
    /// `true` when the server reported `applied == false` — i.e. the original attempt HAD
    /// landed before the process died, and this sweep merely learned about it.
    public let wasAlreadyApplied: Bool
}
