import Foundation

/// The signed-in player, as the server reports them.
public struct GogUser: Sendable, Equatable, Codable {
    public let id: String
    /// Optional because the server returns `data.user.email`, which GoTrue may not have.
    public let email: String?
}

/// `POST /sso/exchange` → `{ access_token, refresh_token, expires_at, expires_in,
/// token_type, user: { id, email } }`
struct ExchangeResponseDTO: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let tokenType: String
    let user: GogUser

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case user
    }
}

/// `POST /auth/refresh` → the same MINUS `token_type`.
///
/// A third shape asymmetry, read from the handler rather than assumed. Sharing one DTO with
/// exchange would force `tokenType` optional and reopen the default-filling hole that
/// non-optional properties exist to close — the same argument that split `EarnResult` from
/// `SpendResult`.
struct RefreshResponseDTO: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: GogUser

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
    }
}

struct RefreshRequestBody: Encodable, Sendable {
    let refreshToken: String
    private enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token" }
}

struct ExchangeRequestBody: Encodable, Sendable {
    let code: String
    let gameId: UUID
    let codeVerifier: String?
    private enum CodingKeys: String, CodingKey {
        case code
        case gameId = "game_id"
        case codeVerifier = "code_verifier"
    }
}

/// What is written to the Keychain.
struct StoredSession: Codable, Sendable, Equatable {
    var accessToken: String
    /// Never crosses into game code (contract §4.2). It exists only inside this type and the
    /// refresh call.
    var refreshToken: String
    var expiresAt: Date
    /// When to refresh proactively: 80% of the token's ORIGINAL lifetime.
    ///
    /// Computed at receipt, when `expires_in` is actually known, and stored. The first cut
    /// derived it from the time REMAINING, which makes the 80% rule meaningless — a session
    /// is always "80% through its remaining life" — and it silently never refreshed. A test
    /// caught it; the fix is to compute the deadline once, at the only moment the real
    /// lifetime is in hand.
    var refreshAt: Date
    var user: GogUser
    /// Derived once, from `user.id`. See `GogIdentity.userScope(for:)`.
    var userScope: String

    init(accessToken: String, refreshToken: String, user: GogUser, userScope: String,
         expiresIn: Int, receivedAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.user = user
        self.userScope = userScope
        let lifetime = TimeInterval(max(expiresIn, 0))
        self.expiresAt = receivedAt.addingTimeInterval(lifetime)
        self.refreshAt = receivedAt.addingTimeInterval(lifetime * 0.8)
    }

    func needsRefresh(now: Date) -> Bool { now >= refreshAt }

    func isExpired(now: Date) -> Bool { now >= expiresAt }
}
