import Foundation

/// Ads — one call per interstitial opportunity.
///
/// The SDK reimplements NO decision logic: which creative, house vs AdMob, rotation, cadence
/// and city targeting are all resolved server-side and controlled from the GOG dashboard. By
/// the time a response arrives the decision is made; the client's whole job is to fetch the
/// directive and render it.
///
/// **I7 — ads never block the game.** `.noAd` is a success, not an error, and it is common.
/// The recommended integration is to treat a thrown error exactly like `.noAd` and carry on:
///
/// ```swift
/// _ = try? await gog.ads.showInterstitial()
/// continueToNextLevel()
/// ```
///
/// **This build serves house ads only.** An AdMob directive resolves to `.noAd` with a loud
/// warning until a Google Mobile Ads integration lands.
///
/// ── The three rules that fail SILENTLY ───────────────────────────────────────
/// Each one costs revenue with no error on either side, which is what makes them expensive:
///
/// 1. **TTL from `expires_in`, on a MONOTONIC clock, stamped at receipt** — never from
///    `expires_at`, which is wall-clock and player-settable. A player with a forward-set
///    clock would see every directive pre-expired: zero ads, no error, and unreproducible on
///    your own device.
/// 2. **The impression index persists and is game-invisible** — see `AdImpressionIndex`.
/// 3. **Errors are never collapsed into NoAd.** A failure to *fetch the directive* throws; a
///    server *decision not to serve* returns `.noAd`. A game that can never show an ad has to
///    be diagnosably different from one where none was eligible, or broken integrations earn
///    nothing, silently, forever.
@MainActor
public final class GogAds {

    private let configuration: GogConfiguration
    private let http: GogHTTP
    private let index: AdImpressionIndex
    private let presenter: any AdPresenter
    /// Monotonic seconds. `ProcessInfo.systemUptime` on device; injected in tests.
    private let monotonic: @Sendable () -> TimeInterval
    /// Best-effort, for city targeting only. Never fail an ad over targeting.
    private let currentUserId: @Sendable () async -> String?
    /// Whether the app is on screen, so the failsafe counts foreground time like Android's.
    private let foreground: any ForegroundMonitor
    /// Failsafe budget and poll interval. Both injected so the timeout is testable in
    /// milliseconds instead of ninety real seconds; production always uses the defaults.
    private let failsafeSeconds: TimeInterval
    private let failsafeTick: TimeInterval

    /// Concurrency guard. A rejected double-call must NOT consume an impression opportunity,
    /// so this is checked BEFORE the index is incremented.
    private var inFlight = false

    /// 🔴 Failsafe. If the overlay never resolves — input not reaching the close control, a
    /// view hierarchy problem, a presenter bug — the caller's `await` would never return and
    /// the game would sit there forever. That is the exact hang class this SDK exists to make
    /// impossible, so it is bounded here in the PIPELINE rather than only inside the overlay:
    /// this file is compiled and tested on every platform, the overlay is not.
    ///
    /// Same 90s as Android's `GogAdOverlay.FailsafeMaxLifetimeSeconds`, and — like Android's —
    /// **90 seconds of FOREGROUND time**, not of wall clock. See `sleepForegroundSeconds`: a
    /// wall-clock bound fires on a player who tapped the creative and spent two minutes on the
    /// advertiser's site, which is a success, not a hang.
    ///
    /// Resolves `.shown`, matching Android: by 90s on screen the forced-view window (max 30s)
    /// has necessarily elapsed, so the player did see the ad and `.shown` is truthful.
    static let presentationFailsafeSeconds: TimeInterval = 90

    init(configuration: GogConfiguration,
         transport: any GogTransport,
         indexStore: any ImpressionIndexStore,
         presenter: any AdPresenter,
         currentUserId: @escaping @Sendable () async -> String? = { nil },
         monotonic: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         foreground: any ForegroundMonitor = GogAds.defaultForegroundMonitor(),
         failsafeSeconds: TimeInterval = GogAds.presentationFailsafeSeconds,
         failsafeTick: TimeInterval = 0.5) {
        self.configuration = configuration
        self.http = GogHTTP(baseURL: configuration.baseURL, transport: transport)
        self.index = AdImpressionIndex(store: indexStore)
        self.presenter = presenter
        self.currentUserId = currentUserId
        self.monotonic = monotonic
        self.foreground = foreground
        self.failsafeSeconds = failsafeSeconds
        self.failsafeTick = failsafeTick
    }

    static func defaultForegroundMonitor() -> any ForegroundMonitor {
        #if canImport(UIKit) && !os(watchOS)
        return UIKitForegroundMonitor()
        #else
        return AlwaysForeground()
        #endif
    }

    /// Fetch and render one interstitial.
    @discardableResult
    public func showInterstitial() async throws -> GogAdResult {
        try await show(trigger: nil)
    }

    /// The automatic game-open opportunity, fired by `GOG.initialize()`.
    ///
    /// Tagged `trigger=open` so the SERVER decides via the game's `show_on_open` policy:
    /// games whose operator has not opted in get `none`, exactly as if this never happened.
    /// Fire-and-forget — there is no partner callback to strand, and I7 holds throughout.
    func autoShowOnOpen() async {
        do { _ = try await show(trigger: "open") }
        catch { GogLog.warn("open interstitial not shown: \(error)") }
    }

    /// Race the presentation against the failsafe. Whichever answers first wins; the loser is
    /// cancelled. `.shown` on timeout — see `presentationFailsafeSeconds`.
    ///
    /// 🔴 **Deliberately unstructured.** The obvious spelling is a `withTaskGroup` of two
    /// children, and it is wrong here: a task group awaits its children at scope exit, so if
    /// the presenter's continuation is never resumed — the precise failure this guard exists
    /// for — the group hangs after the timeout fires and the failsafe guarantees nothing.
    /// Racing two unstructured tasks into one continuation makes the caller's resumption
    /// depend on nothing but the timer.
    ///
    /// For the same reason `teardown()` runs AFTER the caller has been resumed. Taking the
    /// dead surface down still matters — otherwise the game plays on underneath a fullscreen
    /// ad whose close button now has nothing listening to it — but it is cleanup, and the
    /// caller must not be made to wait on the object it just stopped trusting.
    private func withFailsafe(_ present: @escaping @Sendable () async -> GogAdOutcome) async -> GogAdOutcome {
        let seconds = self.failsafeSeconds
        let tick = self.failsafeTick
        let monitor = self.foreground
        let clock = self.monotonic
        let presenter = self.presenter
        let race = FailsafeRace()

        return await withCheckedContinuation { (continuation: CheckedContinuation<GogAdOutcome, Never>) in
            let presentation = Task {
                let outcome = await present()
                if await race.claim() { continuation.resume(returning: outcome) }
            }
            let failsafe = Task {
                let completed = await sleepForegroundSeconds(seconds, monitor: monitor,
                                                             tick: tick, monotonic: clock)
                guard completed else { return }          // cancelled: the ad resolved normally
                guard await race.claim() else { return }
                GogLog.error(
                    "the ad overlay hit its \(Int(seconds))s failsafe and was torn down. The "
                    + "close control was never used, which usually means touch input is not "
                    + "reaching it — check for a view presented above the overlay, or a window "
                    + "at a higher window level.")
                continuation.resume(returning: .shown)
                await presenter.teardown()
            }
            Task { await race.register(presentation: presentation, failsafe: failsafe) }
        }
    }

    /// Drop any in-flight state and remove any live ad surface. Called from `GOG.shutdown()`.
    ///
    /// Mirrors Android's `GogAdOverlay.Teardown()`, which resolves a live ad as `NoAd`. The
    /// outcome falls out of the same place here: the surface goes away, the presenter's
    /// continuation resolves `.noAd`, and the caller's `showInterstitial()` returns `.noAd`.
    ///
    /// Android's version additionally has to resolve a stranded partner callback by hand,
    /// because its exactly-once guarantee is built around delegates. Not needed here — the
    /// caller is `await`-ing a function that returns on its own — so what is left is clearing
    /// the concurrency guard, and taking the surface down. **Leaving the surface up is the
    /// bug**: a shut-down SDK with a fullscreen ad still over the game is unreachable, since
    /// the only thing that could dismiss it was just torn down.
    func resetState() async {
        inFlight = false
        await presenter.teardown()
    }

    // MARK: - Pipeline

    private func show(trigger: String?) async throws -> GogAdResult {
        // BEFORE the index increment, deliberately.
        guard !inFlight else {
            GogLog.warn("showInterstitial was called while an interstitial was already in "
                        + "flight — resolving the second call as noAd. Await the first result "
                        + "before requesting another ad.")
            return GogAdResult(.noAd)
        }
        inFlight = true
        defer { inFlight = false }

        let slot = await index.next()
        let userId = await currentUserId()
        let query = AdDirectiveInterpreter.query(gameId: configuration.gameId,
                                                 userId: userId, index: slot, trigger: trigger)

        // No bearer: /ads/next is a public route. Fetching a token would put a refresh round
        // trip on the ad path for nothing, and would deny house ads to signed-out players.
        let data = try await http.sendRaw(
            GogRequest.get(AdDirectiveInterpreter.path, query: query, accessToken: nil))

        // 🔴 RULE 1: deadline stamped at RECEIPT, on the monotonic clock.
        let receivedAt = monotonic()

        // 🔴 RULE 3: a malformed directive is an ERROR, not a silent noAd. Only the server's
        // own decisions below become noAd.
        switch try AdDirectiveInterpreter.interpret(data) {

        case .none:
            return GogAdResult(.noAd)

        case .unknownType(let type):
            // Designed forward evolution (I9), not a fault.
            GogLog.warn("the server sent an ad directive of an unknown type ('\(type)'). This "
                        + "build resolves it as noAd. Update the GOG SDK to serve it.")
            return GogAdResult(.noAd)

        case .admob:
            GogLog.warn("the server served an AdMob interstitial for this game, but no Google "
                        + "Mobile Ads integration is present in this build — resolving to noAd. "
                        + "House creatives are unaffected. To serve house ads only, change this "
                        + "game's delivery mode in the GOG dashboard.")
            return GogAdResult(.noAd)

        case .house(let directive):
            return try await present(directive, receivedAt: receivedAt)
        }
    }

    private func present(_ directive: AdHouseDTO, receivedAt: TimeInterval) async throws -> GogAdResult {
        let deadline = receivedAt + TimeInterval(directive.expiresIn)

        // Defence in depth on the click target. The admin API enforces https on write, but an
        // arbitrary scheme must never reach UIApplication.open — `URL(string:)` will happily
        // build `intent://` or a custom scheme, and handing one to the system is a way to be
        // navigated somewhere nobody intended.
        let clickURL: URL? = directive.creative.clickUrl
            .flatMap(URL.init(string:))
            .flatMap { url in
                guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
                else {
                    GogLog.warn("ignoring a non-http(s) ad click URL on creative \(directive.creative.id)")
                    return nil
                }
                return url
            }

        guard let imageURL = URL(string: directive.creative.imageUrl) else {
            GogLog.warn("ad creative \(directive.creative.id) has an unusable image URL — noAd.")
            return GogAdResult(.noAd)
        }

        let imageData: Data
        do {
            imageData = try await http.sendAbsolute(imageURL)
        } catch {
            // I7: a creative we cannot fetch is noAd, never an error and never a hang. The
            // diagnostic names the CREATIVE — never the impression id, which stays inside the
            // SDK (I8).
            GogLog.warn("ad creative \(directive.creative.id) could not be loaded (\(error)) — noAd.")
            return GogAdResult(.noAd)
        }

        // Re-check freshness before PRESENTING. Deliberately not re-checked mid-render:
        // yanking a visible ad off the player's screen serves no one. The TTL gates starting
        // a render, not continuing one.
        guard monotonic() < deadline else {
            GogLog.warn("ad directive expired before it could be shown — noAd.")
            return GogAdResult(.noAd)
        }

        let outcome = await withFailsafe {
            await self.presenter.present(imageData: imageData,
                                         clickURL: clickURL,
                                         forcedViewSeconds: directive.creative.forcedViewSeconds)
        }
        return GogAdResult(outcome)
    }
}

/// Exactly-one-winner arbitration for `withFailsafe` (I2).
///
/// An actor rather than a lock because both arms are already async, and because "resume this
/// continuation exactly once" is the kind of invariant that must not depend on my getting
/// memory ordering right by hand. Double-resuming a `CheckedContinuation` is a hard crash.
private actor FailsafeRace {
    private var claimed = false
    private var tasks: [Task<Void, Never>] = []

    /// True for exactly one caller, ever.
    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        cancelAll()
        return true
    }

    func register(presentation: Task<Void, Never>, failsafe: Task<Void, Never>) {
        guard !claimed else { presentation.cancel(); failsafe.cancel(); return }
        tasks = [presentation, failsafe]
    }

    /// Cancelling the presentation arm does not, on its own, resume a `withCheckedContinuation`
    /// that the presenter never resumed — nothing can. That arm then stays suspended until
    /// `teardown()` resolves it, and if a broken presenter never does, one suspended task is
    /// leaked for the life of the process. That is the deliberate trade: a leaked task the
    /// player cannot see, instead of a game frozen behind an ad they cannot dismiss.
    private func cancelAll() {
        for task in tasks { task.cancel() }
        tasks = []
    }
}
