import Foundation

/// The GG Coins client.
///
/// `@MainActor` on the public surface makes invariant I3 (callbacks marshalled to the main
/// thread) a COMPILE-TIME property rather than a runtime convention, and `async throws`
/// makes I2 (delivered exactly once) a language guarantee — a function returns or throws,
/// never neither. Those two were hand-built on Android; here they are free, which is the
/// whole argument for this idiom.
@MainActor
public final class GogCoins {

    // ─────────────────────────────────────────────────────────────────────────────
    // PATH ASYMMETRY — MIRRORED VERBATIM, DO NOT "FIX".
    //
    // Balance is read from /me/wallet. Earn and spend post to /wallet/earn and
    // /wallet/spend. Different prefixes, same wallet. This looks like an inconsistency and
    // is not one; tidying it produces 404s against production.
    // ─────────────────────────────────────────────────────────────────────────────
    private static let balancePath = "/me/wallet"
    private static let earnPath    = "/wallet/earn"
    private static let spendPath   = "/wallet/spend"

    private let configuration: GogConfiguration
    private let http: GogHTTP
    private let log: IdempotencyLog
    private let sessionProvider: GogSessionProvider

    /// Production initializer. Takes no internal types, so the public surface stays frozen
    /// and free of implementation detail.
    public convenience init(configuration: GogConfiguration,
                            sessionProvider: @escaping GogSessionProvider) throws {
        try self.init(configuration: configuration,
                      sessionProvider: sessionProvider,
                      transport: URLSessionTransport(),
                      idempotencyLog: try IdempotencyLog(fileURL: IdempotencyLog.defaultFileURL()))
    }

    /// Seam initializer. Internal on purpose: injecting the transport and the log is how the
    /// three failure modes that bit Android are tested deterministically — no loopback
    /// server, no Mac, no real filesystem location.
    init(configuration: GogConfiguration,
         sessionProvider: @escaping GogSessionProvider,
         transport: any GogTransport,
         idempotencyLog: IdempotencyLog) throws {
        try configuration.validate()
        self.configuration = configuration
        self.sessionProvider = sessionProvider
        self.http = GogHTTP(baseURL: configuration.baseURL, transport: transport)
        self.log = idempotencyLog
    }

    // MARK: - Balance

    /// `GET /me/wallet`
    public func balance() async throws -> Wallet {
        let session = try await sessionProvider()
        return try await http.send(.get(Self.balancePath, accessToken: session.accessToken),
                                   as: Wallet.self)
    }

    // MARK: - Earn

    /// Grant coins. The SDK mints and PERSISTS the idempotency key, so this call is
    /// replay-safe across process death: if the app dies mid-request, the next
    /// `reconcile()` re-sends it with the same key and the player is credited exactly once.
    ///
    /// This is the convenience form and it is the SAFE one. That inversion is deliberate —
    /// on Android the convenience overload mints a fresh key per call, so the easy path is
    /// the one that double-credits. Here the easy path is the correct path, and owning your
    /// own key requires saying so.
    @discardableResult
    public func earn(_ amount: Int64, reason: String? = nil) async throws -> EarnResult {
        try await managedApply(kind: .earn, amount: amount, reason: reason, as: EarnResult.self)
    }

    /// Grant coins under a key YOU supply — e.g. a semantic key like "level-7-complete".
    ///
    /// The SDK does not persist this operation and will not reconcile it. You own replay
    /// safety: reuse the same key for the same logical event, and never mint a fresh one on
    /// retry.
    @discardableResult
    public func earn(_ amount: Int64, reason: String? = nil,
                     idempotencyKey: String) async throws -> EarnResult {
        try await unmanagedApply(path: Self.earnPath, amount: amount,
                                 reason: reason, key: idempotencyKey, as: EarnResult.self)
    }

    // MARK: - Spend

    /// Debit coins. SDK-managed key; replay-safe across process death. See `earn`.
    @discardableResult
    public func spend(_ amount: Int64, reason: String? = nil) async throws -> SpendResult {
        try await managedApply(kind: .spend, amount: amount, reason: reason, as: SpendResult.self)
    }

    /// Debit coins under a key you supply. You own replay safety. See `earn`.
    @discardableResult
    public func spend(_ amount: Int64, reason: String? = nil,
                      idempotencyKey: String) async throws -> SpendResult {
        try await unmanagedApply(path: Self.spendPath, amount: amount,
                                 reason: reason, key: idempotencyKey, as: SpendResult.self)
    }

    // MARK: - Reconciliation

    /// Replay every operation whose outcome is still unknown, using its ORIGINAL key.
    ///
    /// Call this after sign-in on launch. Each settled operation is returned so the game can
    /// refresh its UI — a win that lands during a silent sweep and never reaches the screen
    /// is only half-fixed.
    ///
    /// Never throws: a sweep is best-effort by nature and must not fail a launch.
    @discardableResult
    public func reconcile() async -> [ReconciledOp] {
        guard let ops = try? await log.pending(), !ops.isEmpty else { return [] }

        // ONE session read for the whole sweep. Reading it per-operation would let an
        // account switch land mid-sweep and pair one account's token with another's scope —
        // the same class of mismatch this whole mechanism exists to prevent, reintroduced
        // inside the fix.
        guard let session = try? await sessionProvider() else {
            GogLog.warn("reconcile: no session available; \(ops.count) operation(s) left pending")
            return []
        }

        let mine = ops.filter { $0.userScope == session.userScope }
        let theirs = ops.count - mine.count
        if theirs > 0 {
            // A sweep that quietly skips half the log is its own small silent failure. Say so.
            // These are KEPT, not dropped: the original player may sign back in, and the age
            // eviction clears them eventually with its own loud line.
            GogLog.warn(
                "reconcile: \(theirs) pending operation(s) belong to a different account and "
                + "were skipped, not dropped. They will replay if that account signs back in, "
                + "or age out after \(Int(IdempotencyLog.maxAge / 86_400)) days."
            )
        }
        guard !mine.isEmpty else { return [] }

        var settled: [ReconciledOp] = []
        for op in mine {
            do {
                let body = WalletApplyBody(gameId: op.gameId, amount: op.amount,
                                           idempotencyKey: op.opId.uuidString, reason: op.reason)
                let path = op.kind == .earn ? Self.earnPath : Self.spendPath
                let request = GogRequest.post(path, body: try JSONEncoder().encode(body),
                                              accessToken: session.accessToken, idempotent: true)

                // Decode as SpendResult for both: it is the common prefix of the two shapes,
                // and a sweep only needs balance + applied. Earn's extra fields are ignored
                // here by forward tolerance (I9).
                let result: SpendResult = try await http.send(request, as: SpendResult.self)
                try? await log.resolve(op.opId)
                settled.append(ReconciledOp(kind: op.kind, amount: op.amount,
                                            balanceAfter: result.balance,
                                            wasAlreadyApplied: !result.applied))
            } catch let error as GogError where Self.isDefinitive(error) {
                try? await log.resolve(op.opId)
                GogLog.warn("reconcile: \(op.kind.rawValue) \(op.amount) settled as \(error) — dropped")
            } catch {
                // Still unknown. Keep it: a replay is free, a lost credit is not.
            }
        }
        if !settled.isEmpty {
            GogLog.warn("reconcile: settled \(settled.count) pending operation(s)")
        }
        return settled
    }

    /// Operations awaiting reconciliation FOR THE CURRENT ACCOUNT.
    ///
    /// Scoped for the same reason the sweep is: an unscoped count is a cross-account read.
    /// A game surfacing "3 pending" that is silently counting the previous player's
    /// operations is a smaller version of the same mistake.
    public func pendingOperationCount() async -> Int {
        guard let session = try? await sessionProvider(),
              let ops = try? await log.pending() else { return 0 }
        return ops.filter { $0.userScope == session.userScope }.count
    }

    // MARK: - Internals

    private func managedApply<T: Decodable & Sendable>(kind: WalletOpKind, amount: Int64,
                                                       reason: String?, as type: T.Type) async throws -> T {
        // Read the session ONCE, here, and record whose operation this is alongside the key.
        // The key alone prevents double-crediting; only the scope prevents MIS-crediting.
        let session = try await sessionProvider()
        let op = PendingWalletOp(opId: UUID(), userScope: session.userScope,
                                 gameId: configuration.gameId, kind: kind,
                                 amount: amount, reason: reason, createdAt: Date())
        // Persist BEFORE sending. A failure here is not fatal — it degrades this one call to
        // Android's behaviour rather than refusing to let the player earn.
        do { try await log.record(op) }
        catch { GogLog.warn("idempotency log: could not persist \(kind.rawValue) \(amount): \(error)") }

        do {
            let result: T = try await send(path: kind == .earn ? Self.earnPath : Self.spendPath,
                                           amount: amount, reason: reason,
                                           key: op.opId.uuidString, as: type)
            // Any 2xx is definitive — including a replay (applied == false).
            try? await log.resolve(op.opId)
            return result
        } catch let error as GogError {
            if Self.isDefinitive(error) { try? await log.resolve(op.opId) }
            throw error
        }
    }

    private func unmanagedApply<T: Decodable & Sendable>(path: String, amount: Int64,
                                                         reason: String?, key: String,
                                                         as type: T.Type) async throws -> T {
        try await send(path: path, amount: amount, reason: reason, key: key, as: type)
    }

    private func send<T: Decodable & Sendable>(path: String, amount: Int64, reason: String?,
                                               key: String, as type: T.Type) async throws -> T {
        let session = try await sessionProvider()
        let body = WalletApplyBody(gameId: configuration.gameId, amount: amount,
                                   idempotencyKey: key, reason: reason)
        let data: Data
        do { data = try JSONEncoder().encode(body) }
        catch { throw GogError.invalidInput(field: nil) }

        // idempotent: true is earned, not assumed — the request carries a key, which is
        // precisely what makes repeating it safe.
        return try await http.send(.post(path, body: data,
                                         accessToken: session.accessToken, idempotent: true),
                                   as: type)
    }

    /// Is this outcome one the server has DECIDED?
    ///
    /// Definitive: the operation will never apply, so the log entry is dead.
    /// Not definitive: the outcome is unknown or recoverable, so the entry stays and a later
    /// sweep replays it. `.malformedResponse` is deliberately NOT definitive — an
    /// undecodable 200 most likely means the operation DID apply, and replaying it under the
    /// same key returns `applied == false` at zero cost, whereas dropping it loses the coins.
    /// `.unauthorized` and `.cityRequired` are likewise kept: both are recoverable, and the
    /// op should land once the player signs in or sets a city.
    private static func isDefinitive(_ error: GogError) -> Bool {
        switch error {
        case .insufficientFunds, .earnTooLarge, .idempotencyKeyReused,
             .invalidInput, .unknownGame, .notConfigured:
            return true
        case .unauthorized, .cityRequired, .rateLimited, .server,
             .network, .malformedResponse:
            return false
        // A ban may be lifted, so the op is kept and ages out if it never is.
        // signInCancelled / launchLinkInvalid cannot arise on a wallet call at all; they are
        // listed only to keep this switch exhaustive, which is what makes a future error
        // case a compile error here rather than a silent default.
        case .accountBanned, .signInCancelled, .launchLinkInvalid,
             .invalidOrExpiredCode, .signInInProgress:
            return false
        }
    }
}
