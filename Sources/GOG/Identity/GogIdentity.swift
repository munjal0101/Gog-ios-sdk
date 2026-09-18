import Foundation

/// Which leg delivered the code. It changes what a missing PKCE verifier MEANS.
public enum GogSignInFlow: Sendable, Equatable {
    /// Hub → game. The hub minted the code with no `code_challenge`, so the exchange
    /// requires no verifier and the pre-PKCE contract is byte-identical.
    case forwardLaunch
    /// Game → hub → game. The game sent a `code_challenge`, so the exchange REQUIRES the
    /// matching verifier.
    case reverseHandoff
}

/// Owns the session. The only type that ever sees a refresh token.
///
/// Coins depends on this through the `GogSessionProvider` closure and nothing else, so the
/// identity model can change underneath it without touching a line of the wallet code.
public actor GogIdentity {

    private static let sessionKey = "gog.session"

    private let configuration: GogConfiguration
    private let store: any SecureStore
    private let http: GogHTTP
    private let pkce: PKCEFlowStore
    private let webAuth: any WebAuthPresenter
    private let now: @Sendable () -> Date

    /// Single-flight refresh. Concurrent callers await ONE in-flight refresh; N parallel
    /// refreshes would rotate the refresh token N times and invalidate each other's copy.
    private var refreshTask: Task<StoredSession, Error>?

    private let events = AuthEventHub()

    /// Dedupe marker for launch links — see `trySignInFromLaunch(url:)`.
    private var lastHandledLaunchURL: String?

    // The captured launch code is NOT a field. It is written to the session record, because
    // the wait for the game to ask for it is unbounded and spans the most reapable moments of
    // a cold launch — see `PendingLaunchCode`.
    /// True for any sign-in path — explicit or launch. Starting a second would mint a second
    /// code and strand the first.
    public private(set) var isSignInInProgress = false

    init(configuration: GogConfiguration,
         store: any SecureStore,
         transport: any GogTransport,
         webAuth: (any WebAuthPresenter)? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) throws {
        try configuration.validate()
        self.configuration = configuration
        self.store = store
        self.http = GogHTTP(baseURL: configuration.baseURL, transport: transport)
        self.pkce = PKCEFlowStore(store: store)
        self.webAuth = webAuth ?? GogIdentity.defaultWebAuthPresenter()
        self.now = now
    }

    private static func defaultWebAuthPresenter() -> any WebAuthPresenter {
        #if canImport(AuthenticationServices) && canImport(UIKit)
        return ASWebAuthPresenterImpl()
        #else
        return UnavailableWebAuthPresenter()
        #endif
    }

    // MARK: - userScope

    /// The opaque per-account identifier handed to the coins layer.
    ///
    /// **Derived from `user.id`, never from the access token.** Access tokens rotate on every
    /// refresh; a token-derived scope would change mid-session and silently orphan every
    /// pending wallet operation the player had, leaving them to age out unreconciled.
    ///
    /// **Hashed, not raw.** The wallet log is a plaintext file eligible for device backup.
    /// The hash is exactly as stable and as distinct as the UUID and costs nothing.
    static func userScope(for userId: String) -> String {
        Base64URL.encode(GogSHA256.hash(userId))
    }

    // MARK: - Sign-in

    /// Begin a reverse handoff. Generates and PERSISTS the PKCE pair, then returns the hub
    /// URL to open. Throws if the verifier could not be persisted — starting a flow whose
    /// verifier might vanish guarantees a burnt code later.
    ///
    /// The URL is built by `GogHubURL`, so the hub host lives in exactly one place and cannot
    /// drift back onto the link host.
    @discardableResult
    public func beginReverseHandoff() async throws -> ReverseHandoffRequest {
        let pair = try await pkce.begin(gameId: configuration.gameId, now: now())
        return ReverseHandoffRequest(
            url: GogHubURL.reverseHandoff(gameId: configuration.gameId,
                                          codeChallenge: pair.challenge),
            codeChallenge: pair.challenge)
    }

    /// Sign in through the hub — the full reverse handoff, end to end.
    ///
    /// Mints and persists the PKCE pair, opens the hub's web sign-in in a contained browser,
    /// receives the callback, validates it as this game's launch link, and exchanges.
    ///
    /// ⚠️ On iOS this runs on `ASWebAuthenticationSession`, whose https callback requires the
    /// Associated Domains entitlement for `link.godofgaming.online`. Without it the session
    /// refuses to start and this throws `.notConfigured` saying so — it does not fail
    /// obscurely.
    ///
    /// - Parameter switchAccount: force a clean browser session, discarding shared Safari
    ///   cookies. The "not you? use a different account" path.
    @discardableResult
    public func signInWithGog(switchAccount: Bool = false) async throws -> GogUser {
        guard !isSignInInProgress else { throw GogError.signInInProgress }
        isSignInInProgress = true
        defer { isSignInInProgress = false }

        // Persist the verifier BEFORE opening the browser: the game is backgrounded while the
        // hub is foreground, iOS reaps backgrounded apps, and a missing verifier BURNS the
        // returning code.
        let handoff = try await beginReverseHandoff()

        await events.emit(.signInStarted)
        let callback = try await webAuth.authenticate(
            url: handoff.url,
            callbackHost: GogHosts.link,
            callbackPath: GogHosts.launchPathPrefix + configuration.gameId.uuidString.lowercased(),
            switchAccount: switchAccount)

        // The callback is a launch link like any other and gets the same checks — the browser
        // handing it back is not a reason to trust its shape.
        let link = try LaunchLinkValidator.validate(callback, expecting: configuration.gameId)
        let code = try LaunchLinkValidator.extractCode(
            from: link.url, delimiter: configuration.launchCodeDelimiter)
        return try await exchange(code: code, flow: .reverseHandoff)
    }

    /// Exchange a code for a session.
    ///
    /// The code itself is supplied by the caller — the escape hatch for a game that owns its
    /// own link plumbing.
    @discardableResult
    public func signIn(code: String, flow: GogSignInFlow) async throws -> GogUser {
        guard !isSignInInProgress else { throw GogError.signInInProgress }
        isSignInInProgress = true
        defer { isSignInInProgress = false }
        return try await exchange(code: code, flow: flow)
    }

    /// The exchange itself, without the in-progress guard — so the two public entries can
    /// each hold the guard across their whole flow rather than only across the round trip.
    private func exchange(code: String, flow: GogSignInFlow) async throws -> GogUser {
        let verifier = await pkce.consume(gameId: configuration.gameId, now: now())

        if flow == .reverseHandoff && verifier == nil {
            // Do NOT attempt the exchange. The burn table is explicit: a wrong or MISSING
            // verifier is decided AFTER the atomic consume, so it BURNS the code. Sending a
            // verifier-less exchange for a challenge-bearing code spends the credential to
            // learn something we already know.
            throw GogError.notConfigured(
                "The PKCE verifier for this sign-in is missing, so exchanging this code would "
                + "consume it and still fail. Start a fresh sign-in.")
        }

        let body = ExchangeRequestBody(code: code,
                                       gameId: configuration.gameId,
                                       codeVerifier: verifier)
        let dto: ExchangeResponseDTO
        do {
            dto = try await http.send(
                .post("/sso/exchange", body: try JSONEncoder().encode(body),
                      // 🔴 ONE retry on a TRANSIENT failure, matching Android's
                      // `exchangeWithSingleRetry`. My first cut set this false, reasoning that
                      // the code is single-use so a retry can only burn a dead code. That is
                      // wrong in the case that matters: a connection error usually means the
                      // request never REACHED the server, and the code is untouched. Not
                      // retrying then throws away a session for nothing.
                      //
                      // The other branch is safe too, in Android's words: "If the first attempt
                      // actually reached the server and consumed the code but the response was
                      // lost, the retry returns 401 → InvalidOrExpiredCode (correct: the code is
                      // single-use and now spent)." Either the retry recovers the session or it
                      // tells us what we would have had to assume anyway.
                      accessToken: nil, idempotent: true),
                as: ExchangeResponseDTO.self)
        } catch GogError.unauthorized {
            // Context turns a generic 401 into an actionable one: on the exchange path it
            // means the CODE is spent, not that the session went away. Same wire response,
            // different remedy.
            throw GogError.invalidOrExpiredCode
        }

        let session = StoredSession(
            accessToken: dto.accessToken,
            refreshToken: dto.refreshToken,
            user: dto.user,
            userScope: Self.userScope(for: dto.user.id),
            expiresIn: dto.expiresIn,
            receivedAt: now())
        try persist(session)
        await events.emit(.signedIn(dto.user))
        return dto.user
    }

    /// Async so the in-flight PKCE flow is definitely cleared before this returns — a
    /// fire-and-forget Task here would leave a previous player's verifier reachable by the
    /// next sign-in for an unbounded window.
    public func signOut(reason: GogSignOutReason = .userRequested) async {
        let wasSignedIn = loadSession() != nil
        // The WHOLE record, so a signed-out player is not left holding a live launch code
        // that would sign them straight back in.
        try? store.remove(Self.sessionKey)
        await pkce.clear()
        if wasSignedIn { await events.emit(.signedOut(reason)) }
        // The wallet log is deliberately NOT purged: its entries are scope-tagged and will
        // replay correctly if this player signs back in.
    }

    public var currentUser: GogUser? { loadSession()?.user }

    public var isSignedIn: Bool { loadSession() != nil }

    /// The authoritative session state. **Read this on launch** — do not gate on the
    /// `signedIn` event, which by design does not replay for a restored session (I1).
    public var currentSession: GogSession {
        guard let session = loadSession() else { return .signedOut }
        return GogSession(isSignedIn: true, user: session.user)
    }

    /// Session news. Each call returns an independent stream; none of them replay.
    public func eventStream() async -> AsyncStream<GogAuthEvent> { await events.stream() }

    /// The token to attach to a request the game makes itself. The refresh token is never
    /// reachable from here — that boundary is the whole point of the type.
    public func getAccessToken() async throws -> String {
        try await snapshot().accessToken
    }

    /// Handle a Universal Link that landed on this game's launch path.
    ///
    /// Returns `false` when the URL is not a launch link for this game at all, so a host app
    /// can pass every incoming link through without special-casing. A link that IS ours but
    /// is broken throws — Android only logs a warning here, and a host-mismatched link dying
    /// silently at the parser is the single hardest failure to diagnose in the field.
    @discardableResult
    public func trySignInFromLaunch(url: URL) async throws -> Bool {
        let link: ValidatedLaunchLink
        do { link = try LaunchLinkValidator.validate(url, expecting: configuration.gameId) }
        catch { return false }

        // Dedupe BEFORE extracting, so a redelivered link costs nothing and says nothing.
        // The cold-start URL persists in the launch options AND can re-arrive through the
        // continue-user-activity path, so the same link is routinely delivered twice. A
        // single-use code must be exchanged ONCE. A repeat is expected, not a
        // misconfiguration, so it is dropped silently rather than reported.
        let key = url.absoluteString
        if key == lastHandledLaunchURL { return true }

        do {
            let code = try LaunchLinkValidator.extractCode(
                from: link.url, delimiter: configuration.launchCodeDelimiter)
            lastHandledLaunchURL = key

            guard configuration.autoSignInFromLaunch else {
                // Manual mode: capture, do not exchange. The game calls
                // trySignInFromLaunch() when it is ready — which may be after a relaunch, so
                // the code is written down rather than held.
                try capture(launchCode: code)
                return true
            }
            await events.emit(.signInStarted)
            _ = try await exchangeLaunchCode(code)
            return true
        } catch let error as GogError {
            // Launch sign-in has no explicit caller, so its failure is broadcast rather than
            // returned (and also thrown, for a host that awaited this call).
            await events.emit(.launchSignInFailed(error))
            throw error
        }
    }

    /// Manual mode: exchange a code captured earlier by `trySignInFromLaunch(url:)`.
    ///
    /// Returns `false` when no launch code was captured — in which case nothing is pending
    /// and no event will fire, exactly as the contract describes.
    @discardableResult
    public func trySignInFromLaunch() async throws -> Bool {
        guard let code = loadPendingLaunchCode() else { return false }
        // Cleared BEFORE the exchange, not after. The code is single-use, so a failed attempt
        // has still spent it; leaving it stored would let the game retry a dead credential on
        // every relaunch for the rest of its 120s, failing identically each time.
        clearPendingLaunchCode()
        await events.emit(.signInStarted)
        do {
            _ = try await exchangeLaunchCode(code)
            return true
        } catch let error as GogError {
            await events.emit(.launchSignInFailed(error))
            throw error
        }
    }

    /// True when a launch code is captured and waiting (manual mode only).
    ///
    /// Survives process death — a code captured before a jetsam is still here on relaunch,
    /// within its 120s life.
    public var hasCapturedLaunchCode: Bool { loadPendingLaunchCode() != nil }

    private func exchangeLaunchCode(_ code: String) async throws -> GogUser {
        // The reverse-handoff return leg lands on the SAME path as a forward launch, so the
        // pending PKCE flow is what tells them apart — not the URL.
        let flow: GogSignInFlow = await pkce.hasPendingFlow() ? .reverseHandoff : .forwardLaunch
        return try await signIn(code: code, flow: flow)
    }

    // MARK: - The provider the coins layer consumes

    /// A live session snapshot, refreshing first if the token is near expiry.
    ///
    /// Token and scope come from ONE read of one stored value, so they can never describe
    /// different accounts.
    public func snapshot() async throws -> GogSessionSnapshot {
        guard let session = loadSession() else {
            throw GogError.unauthorized
        }
        let current = now()
        guard session.needsRefresh(now: current) else {
            return GogSessionSnapshot(accessToken: session.accessToken,
                                      userScope: session.userScope)
        }
        let refreshed = try await refresh(session)
        return GogSessionSnapshot(accessToken: refreshed.accessToken,
                                  userScope: refreshed.userScope)
    }

    /// `nonisolated` so it can be handed to `GogCoins` as a plain closure.
    public nonisolated var sessionProvider: GogSessionProvider {
        { try await self.snapshot() }
    }

    /// Stop every event stream and drop the in-memory launch state. Called from
    /// `GOG.shutdown()`.
    ///
    /// A captured launch code is deliberately NOT dropped here. It is persisted precisely so
    /// that it survives the process going away, and a shutdown is a gentler version of that —
    /// clearing it would make an orderly teardown lose what a crash preserves.
    func finishEvents() async {
        lastHandledLaunchURL = nil
        await events.finishAll()
    }

    /// Force a refresh — for wiring a reactive retry after an unexpected 401.
    @discardableResult
    public func forceRefresh() async throws -> GogSessionSnapshot {
        guard let session = loadSession() else { throw GogError.unauthorized }
        let refreshed = try await refresh(session)
        return GogSessionSnapshot(accessToken: refreshed.accessToken,
                                  userScope: refreshed.userScope)
    }

    // MARK: - Refresh

    private func refresh(_ session: StoredSession) async throws -> StoredSession {
        if let inFlight = refreshTask {
            return try await inFlight.value
        }
        let task = Task { try await self.performRefresh(session) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(_ session: StoredSession) async throws -> StoredSession {
        let body = RefreshRequestBody(refreshToken: session.refreshToken)
        do {
            let dto: RefreshResponseDTO = try await http.send(
                .post("/auth/refresh", body: try JSONEncoder().encode(body),
                      accessToken: nil, idempotent: false),
                as: RefreshResponseDTO.self)

            let updated = StoredSession(
                accessToken: dto.accessToken,
                refreshToken: dto.refreshToken,
                user: dto.user,
                // Recomputed from user.id, NOT carried over. If the server ever returns a
                // different user for this refresh token, the scope must follow the user —
                // silently keeping the old scope is how a session inherits another account's
                // pending operations.
                userScope: Self.userScope(for: dto.user.id),
                expiresIn: dto.expiresIn,
                receivedAt: now())
            try persist(updated)
            return updated
        } catch let error as GogError {
            switch error {
            case .unauthorized, .accountBanned:
                // The refresh token is dead or the account is banned. Either way the stored
                // session is worthless; clearing it prevents a retry loop against a token
                // that will never work again.
                try? save(StoredIdentity(session: nil,
                                         pendingLaunchCode: loadIdentity().pendingLaunchCode))
                await events.emit(.signedOut(.sessionExpired))
            default:
                // 🔴 Transient — and a transient failure must not become an auth failure.
                // Android is explicit here: "NEVER sign out on a network blip", and it goes
                // further, handing back the EXISTING access token as a success because it
                // refreshes 60s early so the old one is usually still valid.
                //
                // We refresh at 80% of the token's life, so there is typically ~20% of it
                // left — an even safer margin for the same move. The one thing Android's
                // 60s margin cannot check, we can: if the token really has expired, handing
                // it back would buy the caller a 401 instead of an honest error, so that
                // case still throws.
                if !session.isExpired(now: now()) {
                    GogLog.warn("token refresh failed transiently (\(error)); continuing with "
                                + "the current token, which has not expired yet")
                    return session
                }
            }
            throw error
        }
    }

    // MARK: - Storage

    /// The whole record: session and any pending launch code, read together.
    private func loadIdentity() -> StoredIdentity {
        guard let data = (try? store.get(Self.sessionKey)) ?? nil else { return .empty }
        guard let identity = StoredIdentity.decode(data) else {
            GogLog.warn("session store: the stored record could not be read; treating as "
                        + "signed out")
            return .empty
        }
        return identity
    }

    private func loadSession() -> StoredSession? { loadIdentity().session }

    private func save(_ identity: StoredIdentity) throws {
        if identity.isEmpty {
            try store.remove(Self.sessionKey)
        } else {
            try store.set(try JSONEncoder().encode(identity), for: Self.sessionKey)
        }
    }

    /// 🔴 Android's `saveSessionAndClearPending`, and atomic for the same reason.
    ///
    /// A signed-in player must never still be holding the launch code that signed them in.
    /// The code is spent the moment the server answers, so a surviving copy can only ever
    /// produce a 401 and a `launchSignInFailed` the player did nothing to cause — and the
    /// window in which that copy exists is a window a jetsam can land in. One `store.set` of
    /// one value closes it: both changes land or neither does.
    private func persist(_ session: StoredSession) throws {
        try save(StoredIdentity(session: session, pendingLaunchCode: nil))
    }

    // MARK: - The pending launch code

    /// The captured code, if one is stored, still valid, and for this game.
    ///
    /// Self-healing on read: an expired or foreign record is dropped here rather than offered
    /// to the game, mirroring `PKCEFlowStore.consume`. Reporting a dead code as available buys
    /// the player an opaque exchange failure instead of an honest "not signed in".
    private func loadPendingLaunchCode() -> String? {
        let identity = loadIdentity()
        guard let pending = identity.pendingLaunchCode else { return nil }

        if pending.isExpired(now: now()) {
            GogLog.warn("launch: discarded a captured code older than "
                        + "\(Int(PendingLaunchCode.ttl))s without an exchange")
            try? save(StoredIdentity(session: identity.session, pendingLaunchCode: nil))
            return nil
        }
        guard pending.gameId == configuration.gameId else {
            GogLog.warn("launch: stored code was captured for a different game; discarding")
            try? save(StoredIdentity(session: identity.session, pendingLaunchCode: nil))
            return nil
        }
        return pending.code
    }

    /// Write the captured code down. Throws for the same reason `PKCEFlowStore.begin` does:
    /// reporting a capture we could not persist promises the game something we cannot keep.
    private func capture(launchCode code: String) throws {
        let identity = loadIdentity()
        try save(StoredIdentity(session: identity.session,
                                pendingLaunchCode: PendingLaunchCode(code: code,
                                                                     gameId: configuration.gameId,
                                                                     capturedAt: now())))
    }

    /// 🔴 Android's `resumePendingHandoff`, minus the resume — see the comment below.
    ///
    /// Called once from `GOG.initialize()`, unconditionally and before anything else looks at
    /// stored state, so an abandoned sign-in cannot leave a verifier or a code sitting in the
    /// Keychain past its bound. Read-time self-healing is not a substitute: it only fires when
    /// someone happens to ask.
    ///
    /// **Why there is no resume half.** Android calls this on focus regain too, and completes
    /// the exchange headlessly, because its reverse handoff runs in a SEPARATE activity: the
    /// game process can die while the player is in the hub, and the returning Intent still
    /// reaches a proxy that persists the code before the core wakes. iOS has no equivalent
    /// exposure and no equivalent opportunity — `ASWebAuthenticationSession` is in-process, so
    /// if the process dies the sheet dies with it and the code is never minted or delivered to
    /// anywhere. There is nothing to resume. What survives the difference is the sweep.
    func sweepStaleSignInState() async {
        await pkce.sweepIfStale(now: now())
        _ = loadPendingLaunchCode()   // self-healing: drops an over-age or foreign record
    }

    private func clearPendingLaunchCode() {
        let identity = loadIdentity()
        guard identity.pendingLaunchCode != nil else { return }
        try? save(StoredIdentity(session: identity.session, pendingLaunchCode: nil))
    }
}
