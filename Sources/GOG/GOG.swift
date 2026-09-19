import Foundation

/// The GOG SDK.
///
/// One entry point, mirroring `GogSdk.Initialize()` on Android: a game calls `initialize`
/// once and reaches everything else through the returned instance.
///
/// ```swift
/// let gog = try await GOG.initialize(GogConfiguration(gameId: myGameId))
///
/// // I1 — read STATE on launch. Do not gate on the signedIn event; a restored session
/// // deliberately does not replay it.
/// if gog.auth.currentSession.isSignedIn { showSignedInUI() }
///
/// let wallet = try await gog.coins.balance()
/// _ = try? await gog.ads.showInterstitial()
/// ```
@MainActor
public final class GOG {

    /// The live instance, or nil before `initialize`.
    public private(set) static var shared: GOG?
    public static var isInitialized: Bool { shared != nil }

    /// The SDK version. Equal, by ordinal string comparison, to the binding's version and to
    /// the value compiled into the shipped binary (contract §1.5).
    public static var version: String { GogSDKVersion.value }

    public let configuration: GogConfiguration
    public let auth: GogIdentity
    public let coins: GogCoins
    public let ads: GogAds
    /// Metered playtime. Not part of the frozen public surface — no game calls it; it runs
    /// itself off app lifecycle and input. Exposed only for diagnostics.
    public let playtime: GogPlaytime

    #if canImport(UIKit)
    private var playtimeHook: PlaytimeAutoHook?
    #endif

    private init(configuration: GogConfiguration, auth: GogIdentity,
                 coins: GogCoins, ads: GogAds, playtime: GogPlaytime) {
        self.configuration = configuration
        self.auth = auth
        self.coins = coins
        self.ads = ads
        self.playtime = playtime
    }

    /// Bring the SDK up.
    ///
    /// The version handshake runs FIRST and throws on a mismatch, before anything is marked
    /// initialized — so a partial or tampered install cannot half-boot.
    ///
    /// Calling this twice is ignored and returns the existing instance, with a log. Runtime
    /// reconfiguration does not exist: on Android, a second `Initialize()` with a different
    /// game id updated the managed config while the native core kept the old values, so coins
    /// posted against the new game while auth exchanged against the old. Refusing the second
    /// call is what makes that unrepresentable.
    @discardableResult
    public static func initialize(_ configuration: GogConfiguration) async throws -> GOG {
        if let existing = shared {
            GogLog.warn("initialize() called again — ignored. Runtime reconfiguration does not exist.")
            return existing
        }

        // §1.5 handshake, before any state is created.
        try configuration.validate()

        return try await initialize(configuration,
                                    store: Self.defaultSecureStore(),
                                    transport: URLSessionTransport(),
                                    indexStore: UserDefaultsImpressionIndexStore(),
                                    presenter: Self.defaultAdPresenter(),
                                    log: IdempotencyLog(fileURL: try IdempotencyLog.defaultFileURL()),
                                    playtimeQueue: PlaytimeQueue(fileURL: try PlaytimeQueue.defaultFileURL()))
    }

    /// Composition seam. Internal on purpose: it is how the wiring — which surface gets which
    /// dependency, and the order initialize does things in — is tested without a network, a
    /// Keychain, or a screen.
    @discardableResult
    static func initialize(_ configuration: GogConfiguration,
                           store: any SecureStore,
                           transport: any GogTransport,
                           indexStore: any ImpressionIndexStore,
                           presenter: any AdPresenter,
                           log: IdempotencyLog,
                           playtimeQueue: PlaytimeQueue? = nil,
                           runStartupTasks: Bool = true) async throws -> GOG {
        if let existing = shared {
            GogLog.warn("initialize() called again — ignored. Runtime reconfiguration does not exist.")
            return existing
        }
        try configuration.validate()

        let identity = try GogIdentity(configuration: configuration, store: store,
                                       transport: transport)
        let coins = try GogCoins(configuration: configuration,
                                 sessionProvider: identity.sessionProvider,
                                 transport: transport,
                                 idempotencyLog: log)
        let ads = GogAds(configuration: configuration,
                         transport: transport,
                         indexStore: indexStore,
                         presenter: presenter,
                         currentUserId: { await identity.currentSession.user?.id })

        let queue = try playtimeQueue ?? PlaytimeQueue(fileURL: PlaytimeQueue.defaultFileURL())
        let playtime = GogPlaytime(
            gameId: configuration.gameId,
            deviceId: GogDeviceId.resolve(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            queue: queue,
            uploader: PlaytimeUploader(baseURL: configuration.baseURL, transport: transport,
                                       accessToken: { try? await identity.getAccessToken() }))

        let instance = GOG(configuration: configuration, auth: identity, coins: coins,
                           ads: ads, playtime: playtime)
        shared = instance

        if runStartupTasks {
            // Sweep any abandoned sign-in state FIRST, mirroring Android's
            // `resumePendingHandoff` at the tail of its own initialize. Unconditional and
            // ahead of everything else that reads stored state, so a verifier or a code left
            // by a flow nobody finished cannot outlive its bound just because no one asked.
            Task { await identity.sweepStaleSignInState() }

            // Settle any wallet operation whose outcome was unknown when the process last
            // died. Detached: a reconciliation problem must never fail or delay initialize.
            Task { _ = await coins.reconcile() }

            // One server-gated interstitial opportunity at game open. AFTER the instance is
            // live so the ad path sees a booted SDK, and detached because an ad must never be
            // able to fail initialize itself.
            Task { await ads.autoShowOnOpen() }

            // One boot-time catalogue check. Turns an opaque runtime 404 at first sign-in
            // into a loud failure at integration time, and it is the ONLY thing that catches
            // a wrong game id at all — /ads/next answers 200 {"type":"none"} for a
            // well-formed but unknown id, so a game shipped with the wrong UUID earns
            // nothing, forever, silently.
            Task { await Self.verifyCatalogueEntry(configuration, transport: transport) }

            #if canImport(UIKit)
            // Playtime drives itself off lifecycle and input — no game code participates,
            // matching Android's activity-lifecycle callbacks.
            let hook = PlaytimeAutoHook(playtime: playtime)
            instance.playtimeHook = hook
            hook.start()
            #endif
        }

        return instance
    }

    /// Tear the SDK down. Ends every event stream; does not sign the player out.
    public static func shutdown() async {
        guard let instance = shared else { return }
        #if canImport(UIKit)
        instance.playtimeHook?.stop()
        instance.playtimeHook = nil
        #endif
        await instance.ads.resetState()
        // Bank whatever has accrued rather than losing it to teardown.
        await instance.playtime.onBackground()
        await instance.auth.finishEvents()
        shared = nil
    }

    /// Hand the SDK an incoming Universal Link.
    ///
    /// Call this from `scene(_:willConnectTo:options:)` (cold start — the common case, since
    /// the OS launches the app to handle the link) AND `scene(_:continue:)` (warm). Missing
    /// the cold path is the classic way this silently only works when the app is already
    /// running.
    ///
    /// Returns `false` when the URL is not this game's launch link, so every incoming URL can
    /// be passed through without special-casing. Redelivery of the same link is handled
    /// internally and costs nothing.
    @discardableResult
    public static func handle(url: URL) async throws -> Bool {
        guard let instance = shared else { return false }
        return try await instance.auth.trySignInFromLaunch(url: url)
    }

    // MARK: - Catalogue check

    /// One row of `GET /games`, reduced to what this check needs.
    private struct CatalogueRow: Decodable {
        let id: String
        /// Optional ON PURPOSE. If the server stops sending `kind`, this check must lose its
        /// opinion rather than refuse to boot — see `verifyCatalogueEntry`.
        let kind: String?
    }

    /// Warn loudly when the configured game id is absent from the catalogue, or is not a
    /// `native` game.
    ///
    /// **Fails OPEN on anything it cannot determine.** A network blip, an unreachable
    /// catalogue, or a server that stopped sending `kind` must not stop a game booting: the
    /// check exists to make a *misconfiguration* loud, and refusing to start over an
    /// inability to check would be a worse failure than the one it guards against. Only a
    /// definite answer is reported.
    ///
    /// It warns rather than throws for the same reason initialize does not await it: a
    /// diagnostic that can take the app down is not a diagnostic.
    static func verifyCatalogueEntry(_ configuration: GogConfiguration,
                                     transport: any GogTransport) async {
        let http = GogHTTP(baseURL: configuration.baseURL, transport: transport)
        let rows: [CatalogueRow]
        do { rows = try await http.send(.get("/games", accessToken: nil), as: [CatalogueRow].self) }
        catch { return }   // cannot tell — say nothing

        let wanted = configuration.gameId.uuidString.lowercased()
        guard let row = rows.first(where: { $0.id.lowercased() == wanted }) else {
            GogLog.warn("""
                game id \(wanted) is not in the GOG catalogue. Sign-in will fail with a                 generic 404 and ads will silently return "no ad" forever. Check the id against                 the GOG dashboard — and note the row may exist but be unpublished or                 soft-deleted.
                """)
            return
        }
        if let kind = row.kind, kind != "native" {
            GogLog.warn("""
                game id \(wanted) is registered as a '\(kind)' game. The GOG iOS SDK supports                 'native' games; POST /sso/codes will refuse to mint for this row, so sign-in                 cannot succeed.
                """)
        }
    }

    // MARK: - Platform defaults

    /// Internal, not private: the Unity bridge boots `GogIdentity` without this facade and must
    /// land on the SAME Keychain service, or a game that moved between the two would restore
    /// a signed-out player. `nonisolated` because the bridge is not on the main actor, and
    /// nothing here needs it.
    nonisolated static func defaultSecureStore() -> any SecureStore {
        #if canImport(Security)
        let service = (Bundle.main.bundleIdentifier ?? "com.gog.sdk") + ".gog.session"
        return KeychainSecureStore(service: service)
        #else
        // Linux/CI only. A shipping Apple build always takes the branch above.
        GogLog.warn("no Keychain on this platform — session storage is IN MEMORY and will not "
                    + "survive relaunch. This must never be a shipping build.")
        return InMemorySecureStore()
        #endif
    }

    private static func defaultAdPresenter() -> any AdPresenter {
        #if canImport(UIKit) && !os(watchOS)
        return UIKitAdPresenter()
        #else
        return NoOpAdPresenter()
        #endif
    }
}
