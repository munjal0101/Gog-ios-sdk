import Foundation

/// An RFC 7636 S256 verifier/challenge pair, generated to match the server's validators
/// EXACTLY — both were read from `services/api/src/index.ts`, not assumed:
///
///   verifier  server: `^[A-Za-z0-9\-._~]{43,128}$`   ours: 32 random bytes → base64url → 43 chars
///   challenge server: `^[A-Za-z0-9_-]{43}$`          ours: base64url(SHA-256(verifier))   → 43 chars
///
/// S256 is the only method. There is no `code_challenge_method` on the wire and the server
/// never accepts `plain`.
struct PKCEPair: Codable, Sendable, Equatable {
    let verifier: String
    let challenge: String

    static func generate() -> PKCEPair {
        // base64url of 32 bytes is 43 chars from the [A-Za-z0-9_-] alphabet, which is a
        // subset of RFC 7636's unreserved set — so one length satisfies both validators.
        let verifier = Base64URL.encode(Base64URL.randomBytes(32))
        let challenge = Base64URL.encode(GogSHA256.hash(verifier))
        return PKCEPair(verifier: verifier, challenge: challenge)
    }
}

/// A PKCE pair persisted for the duration of one in-flight sign-in.
struct PendingPKCEFlow: Codable, Sendable, Equatable {
    let pair: PKCEPair
    let gameId: UUID
    let startedAt: Date

    func isExpired(now: Date, ttl: TimeInterval) -> Bool {
        now.timeIntervalSince(startedAt) > ttl
    }
}

/// Persists the in-flight PKCE verifier across process death.
///
/// 🔴 WHY THIS IS NOT AN IN-MEMORY FIELD. The exchange burn table is unforgiving: a
/// **wrong or missing verifier BURNS the code**, while a malformed one is a 400 before the
/// consume. The reverse handoff backgrounds the game while the hub is foreground, and iOS
/// reaps backgrounded apps. An in-memory verifier lost to a jetsam therefore means the
/// returning code arrives with no verifier, burns, and the player gets an opaque 401 with no
/// recovery but a re-tap — every time the OS decides to reclaim memory.
///
/// This is the wallet write-ahead log applied to identity: state that must outlive the
/// process is written down BEFORE the thing that might kill the process.
actor PKCEFlowStore {

    /// Generous relative to the code's own 120s TTL, tight enough that an abandoned flow
    /// cannot authorise a much later return.
    static let flowTTL: TimeInterval = 5 * 60

    private let store: any SecureStore
    private let key = "gog.pkce.pending"

    init(store: any SecureStore) { self.store = store }

    /// Generate, persist, and hand back the pair. Persist FIRST: if the write fails the flow
    /// must not start, because starting it would guarantee a burnt code on process death.
    func begin(gameId: UUID, now: Date = Date()) throws -> PKCEPair {
        let flow = PendingPKCEFlow(pair: .generate(), gameId: gameId, startedAt: now)
        try store.set(try JSONEncoder().encode(flow), for: key)
        return flow.pair
    }

    /// Retrieve the verifier for a returning code, then clear it — one flow, one use.
    /// Returns nil if there is no flow, if it expired, or if it was for another game.
    func consume(gameId: UUID, now: Date = Date()) -> String? {
        guard let data = try? store.get(key),
              let flow = try? JSONDecoder().decode(PendingPKCEFlow.self, from: data) else {
            return nil
        }
        try? store.remove(key)

        guard !flow.isExpired(now: now, ttl: Self.flowTTL) else {
            GogLog.warn("pkce: discarded a flow older than \(Int(Self.flowTTL))s without a return")
            return nil
        }
        guard flow.gameId == gameId else {
            GogLog.warn("pkce: stored flow was for a different game; discarding")
            return nil
        }
        return flow.pair.verifier
    }

    func hasPendingFlow() -> Bool { (try? store.get(key)) != nil }

    /// Drop an over-age flow whether or not anyone is about to sign in.
    ///
    /// `consume` already discards one, but only when a sign-in happens to arrive. Android
    /// sweeps unconditionally at `initialize()` and calls the sweep 🔴 UNCONDITIONAL and
    /// FIRST, before any decision about whether there is something to complete — precisely so
    /// an abandoned flow cannot leave a verifier in storage past its bound. Waiting for the
    /// next sign-in is not a bound.
    ///
    /// Returns true if something was swept, for the log line.
    @discardableResult
    func sweepIfStale(now: Date = Date()) -> Bool {
        guard let data = try? store.get(key),
              let flow = try? JSONDecoder().decode(PendingPKCEFlow.self, from: data),
              flow.isExpired(now: now, ttl: Self.flowTTL) else { return false }
        try? store.remove(key)
        GogLog.warn("pkce: swept a stale flow at startup (older than \(Int(Self.flowTTL))s)")
        return true
    }

    func clear() { try? store.remove(key) }
}
