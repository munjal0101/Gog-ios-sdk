import Foundation

/// The token and the account it belongs to, read together, at one instant.
///
/// WHY ONE STRUCT AND NOT TWO CLOSURES. The bug this type exists to prevent is a mismatch
/// between *which token* a request carries and *which account* a persisted operation belongs
/// to. Two independent closures would be read at two different moments, so an account switch
/// landing between them yields a token from one account and a scope from another — which is
/// the very mismatch, reintroduced as a time-of-check/time-of-use window inside the fix.
/// One call, one snapshot, no window.
///
/// The second reason is configuration safety: with two closures, a caller can supply the
/// token one and forget the scope one, and any default for the missing half degrades
/// silently back to the original bug. Here you cannot construct a session without stating
/// whose it is.
public struct GogSessionSnapshot: Sendable, Equatable {

    /// Bearer token for the call being made right now.
    public let accessToken: String

    /// An OPAQUE, stable, per-account identifier. The coins layer never parses, splits,
    /// compares-as-anything-but-a-string, or otherwise interprets this — that is what keeps
    /// this layer free of any dependency on the identity model.
    ///
    /// Requirements on whoever supplies it (Phase 3):
    ///   - **Stable** for the same account across sign-out / sign-in and across app launches.
    ///     If it changes for the same player, their pending operations become unreplayable
    ///     and age out.
    ///   - **Different** for different accounts. If two accounts can collide, the
    ///     mis-crediting hole reopens.
    ///   - **Not a secret, and preferably not raw PII.** It is written to a plaintext file
    ///     that is eligible for device backup. A stable hash of the account identifier
    ///     satisfies everything above and is the recommended value.
    public let userScope: String

    public init(accessToken: String, userScope: String) {
        self.accessToken = accessToken
        self.userScope = userScope
    }
}

/// Supplies the current session. Injected rather than owned, so the coins layer has NO
/// dependency on the identity model — which is still open (AASA, Team ID, and the
/// launch-URL delimiter are all undecided). Phase 3 provides the real implementation;
/// nothing in this package changes when it does.
public typealias GogSessionProvider = @Sendable () async throws -> GogSessionSnapshot
