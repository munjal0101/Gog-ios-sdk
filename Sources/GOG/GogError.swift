import Foundation

/// Why a transport-level failure happened. Deliberately our own type rather than
/// `URLError.Code`: the public error surface should not leak Foundation's networking
/// taxonomy into a frozen contract, and it keeps the enum identical across platforms.
public enum GogNetworkReason: Equatable, Sendable {
    case offline
    case timedOut
    case cancelled
    /// A status the SDK has no specific mapping for. Carries the code so support can see it.
    case unexpectedStatus(Int)
    /// Anything else the transport reported, as text. Never a secret — see the redaction
    /// note in GogHTTP.
    case transport(String)
}

/// THE error type. One closed taxonomy for the whole SDK.
///
/// Android accreted two overlapping sets (`NetworkError` vs `Network`,
/// `InvalidOrExpiredCode` vs `Unauthorized`) and it cost real debugging time. There is
/// exactly one of these, and every throwing path in the SDK funnels through
/// `GogErrorMapper` to produce it.
///
/// NOTE what is deliberately ABSENT: there is no `noAd` case. "No ad was eligible" is a
/// *success* (invariant I7) and is modelled as a case of the ads result type, not as an
/// error. Keeping them in different types makes the third silent-failure rule —
/// never collapse an error into NoAd — structurally impossible to violate rather than a
/// thing a reviewer has to notice.
public enum GogError: Error, Equatable, Sendable {

    /// Transport failed, or an unmapped status came back. `retryable` reflects whether the
    /// SDK considers a repeat attempt sensible; it does NOT mean the SDK already retried.
    case network(GogNetworkReason, retryable: Bool)

    /// HTTP 401. Covers an invalid/expired SSO code and an expired session alike — the
    /// server returns one opaque 401 for all of them by design (anti-enumeration), so the
    /// SDK must not invent a distinction it cannot actually observe.
    case unauthorized

    /// HTTP 429 `rate_limited` (server codes GC002 and GC007). The two ceilings are
    /// deliberately indistinguishable on the wire — which ceiling was hit is a platform
    /// detail, not something a studio should branch on.
    case rateLimited(retryAfter: TimeInterval?)

    /// HTTP 409 `insufficient_funds` (GC001).
    case insufficientFunds

    /// HTTP 422 `earn_too_large` (GC003).
    case earnTooLarge

    /// HTTP 409 `idempotency_key_reused` (GC004) — the key was reused with DIFFERENT
    /// parameters. A key reused with the same parameters is not this: it returns 200 with
    /// `applied == false`, which is a successful replay. See `WalletResult.applied`.
    case idempotencyKeyReused

    /// HTTP 400 `invalid_input` (GC005) or `invalid input` (request validation). The server
    /// uses BOTH spellings — underscore from the wallet RPC mapping, space from the
    /// handler's own validation — so both map here.
    case invalidInput(field: String?)

    /// HTTP 400 `unknown_game`. The configured `gameId` is not a game the server will
    /// accept for this call. Worth its own case: on the coins path this is the ONLY place a
    /// wrong game id announces itself — `/ads/next` answers 200 `{"type":"none"}` for a
    /// well-formed but unknown id, i.e. silently.
    case unknownGame

    /// HTTP 428 `city_required`. Can come back from ANY authenticated call, which is why it
    /// is first-class rather than folded into a generic 4xx.
    case cityRequired

    /// HTTP 5xx, or server code GC006.
    case server

    /// A 200 whose body could not be decoded into the expected shape.
    ///
    /// This is the Swift half of the guarantee that killed the two worst Android coins bugs:
    /// a malformed 200 used to hang forever (unguarded parse inside a `finally` with no
    /// `catch`), and a valid-JSON-wrong-shape used to yield `balance = 0` — a WRONG SUCCESS.
    /// DTO properties here are non-optional, so a missing key throws instead of
    /// default-filling, and it arrives as this case with the field named.
    case malformedResponse(missingField: String?)

    /// HTTP 403 `banned` from `POST /auth/refresh`. The refresh token was LIVE — GoTrue
    /// refused the grant because the account is banned.
    ///
    /// First-class because it must be diagnosably different from an expired token: the
    /// remedy is completely different, and a banned player told "session expired" will retry
    /// forever. `GET /auth/ban-status/:userId` gives the detail.
    case accountBanned

    /// The player dismissed the web sign-in without completing it. Not a failure — a choice.
    case signInCancelled

    /// The SSO code was rejected at exchange: bad, expired, already consumed, wrong game, or
    /// the PKCE verifier did not match. The server returns ONE opaque 401 for every one of
    /// those, deliberately, so the SDK does not invent a distinction it cannot observe.
    ///
    /// Distinct from `.unauthorized` by CONTEXT, which is the part that matters to a caller:
    /// this one means "that sign-in link is spent, get a fresh one", while `.unauthorized` on
    /// an ordinary call means "the session went away, sign in again".
    case invalidOrExpiredCode

    /// A sign-in was already running. Starting a second one would mint a second code and
    /// leave the first stranded.
    case signInInProgress

    /// A link arrived on the launch path that this SDK will not act on.
    ///
    /// Android's parser was upgraded from a silent return to a log warning; still only a log,
    /// with nothing reaching the game. This is the version that reaches the game.
    case launchLinkInvalid(LaunchLinkProblem)

    /// The SDK was used before `configure`, or configured inconsistently (unstamped
    /// version, empty base URL, invalid game id). Always carries remediation text.
    case notConfigured(String)
}

/// Why a launch link was rejected. Each case names something an integrator can act on.
public enum LaunchLinkProblem: Equatable, Sendable {
    case notHTTPS
    case wrongHost(expected: String, got: String)
    /// One of OUR hosts, carrying the OTHER host's path — a launch link on the hub host, or
    /// an `/auth` link on the link host.
    ///
    /// Distinct from `wrongHost` because it is a misconfiguration on our side, not a
    /// stranger linking at us, and because collapsing the two roles onto one domain
    /// re-creates the same-domain condition the split exists to prevent.
    case hostRoleMismatch(host: String, path: String)
    case notLaunchPath(String)
    case malformedGameIdSegment(String)
    /// The link is well-formed but carries no code at all.
    case missingCode
    /// 🔴 The code arrived in the form this build does NOT accept.
    ///
    /// Not a parse failure — a security event. A query-delimited code has already been
    /// written to server access logs and `Referer` headers before the app ever saw it, so if
    /// the fragment is the active policy the arriving code must be treated as compromised
    /// and a fresh sign-in started. The reverse (a fragment arriving under a query policy)
    /// means the hub and the SDK disagree about the contract.
    case codeDeliveredInWrongPosition(expected: String, got: String)
    /// A well-formed UUID that is not THIS game. Distinct from malformed: it means the link
    /// was real but routed to the wrong app, which points at AASA or the manifest, not at a
    /// typo.
    case gameIdMismatch(expected: UUID, got: UUID)
}

extension GogError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .network(let reason, let retryable):
            return "network(\(reason), retryable: \(retryable))"
        case .unauthorized:            return "unauthorized"
        case .rateLimited(let after):  return "rateLimited(retryAfter: \(after.map(String.init(describing:)) ?? "nil"))"
        case .insufficientFunds:       return "insufficientFunds"
        case .earnTooLarge:            return "earnTooLarge"
        case .idempotencyKeyReused:    return "idempotencyKeyReused"
        case .invalidInput(let f):     return "invalidInput(field: \(f ?? "nil"))"
        case .unknownGame:             return "unknownGame"
        case .cityRequired:            return "cityRequired"
        case .server:                  return "server"
        case .malformedResponse(let f):return "malformedResponse(missingField: \(f ?? "nil"))"
        case .accountBanned:           return "accountBanned"
        case .signInCancelled:         return "signInCancelled"
        case .invalidOrExpiredCode:    return "invalidOrExpiredCode"
        case .signInInProgress:        return "signInInProgress"
        case .launchLinkInvalid(let p):return "launchLinkInvalid(\(p))"
        case .notConfigured(let why):  return "notConfigured(\(why))"
        }
    }
}
