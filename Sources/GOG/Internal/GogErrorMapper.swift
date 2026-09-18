import Foundation

/// The wire error envelope. Every non-2xx from the API is `{"error": "<string>"}`.
///
/// Note there is NO code field: the server's GC001–GC008 SQLSTATEs are mapped to
/// (status, string) pairs server-side and never cross the wire. So the SDK must key off
/// the pair, not off a code — mapping by an imagined `code` field would silently fall
/// through to a generic error for every wallet failure.
private struct ErrorEnvelope: Decodable {
    let error: String
}

/// The one place a non-2xx becomes a `GogError`. One taxonomy, one function.
enum GogErrorMapper {

    static func error(status: Int, body: Data, headers: [String: String]) -> GogError {
        // Decoding the error body must NEVER throw: a non-JSON error body has to fall back
        // to the status bucket rather than masking the real status with a parse failure.
        let wire: String? = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error

        switch (status, wire) {
        case (401, _):
            return .unauthorized

        case (428, _):
            return .cityRequired

        // 403 `banned` is reachable from POST /auth/refresh with a LIVE refresh token.
        // Bucketing it as a generic auth failure would tell a banned player "session
        // expired" and have them retry forever.
        case (403, "banned"):
            return .accountBanned

        case (409, "insufficient_funds"):
            return .insufficientFunds
        case (409, "idempotency_key_reused"):
            return .idempotencyKeyReused
        case (409, _):
            return .network(.unexpectedStatus(409), retryable: false)

        case (422, "earn_too_large"):
            return .earnTooLarge

        case (429, _):
            return .rateLimited(retryAfter: retryAfter(from: headers))

        case (400, "unknown_game"):
            return .unknownGame
        // Both spellings are real and reachable: the wallet RPC mapping emits
        // "invalid_input" (GC005) while the handlers' own validation emits "invalid input".
        // Matching only one of them would drop the other into a generic bucket.
        case (400, "invalid_input"), (400, "invalid input"):
            return .invalidInput(field: nil)
        case (400, _):
            return .invalidInput(field: nil)

        case (500...599, _):
            return .server

        default:
            return .network(.unexpectedStatus(status), retryable: (500...599).contains(status))
        }
    }

    private static func retryAfter(from headers: [String: String]) -> TimeInterval? {
        guard let raw = headers["retry-after"], let seconds = TimeInterval(raw) else { return nil }
        return seconds
    }

    /// Turn a decode failure into a named, delivered error.
    ///
    /// This is the Swift equivalent of Newtonsoft `Required.Always` on the C# side. Every
    /// DTO property in this SDK is NON-OPTIONAL, so a 200 that omits a field lands here as
    /// `.malformedResponse(missingField:)` rather than being default-filled into a wrong
    /// success — which is exactly how Android's coins path could report `balance = 0` for a
    /// response that never contained a balance.
    static func decodeFailure(_ error: Error) -> GogError {
        guard let decoding = error as? DecodingError else {
            return .malformedResponse(missingField: nil)
        }
        switch decoding {
        case .keyNotFound(let key, _):
            return .malformedResponse(missingField: key.stringValue)
        case .valueNotFound(_, let ctx), .typeMismatch(_, let ctx):
            return .malformedResponse(missingField: ctx.codingPath.last?.stringValue)
        case .dataCorrupted:
            // Not JSON at all. On Android this was the case that HUNG FOREVER, because the
            // parse threw inside a `finally` with no `catch` and no callback was ever
            // delivered. Here it is an ordinary thrown error on the one code path.
            return .malformedResponse(missingField: nil)
        @unknown default:
            return .malformedResponse(missingField: nil)
        }
    }
}
