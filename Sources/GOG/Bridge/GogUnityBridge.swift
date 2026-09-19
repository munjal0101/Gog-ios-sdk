import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// The Unity binding's native seam on iOS.
//
// This is the counterpart of android-core's `GogAuthCore`, which `AndroidAuthBridge.cs`
// drives over JNI. `IosAuthBridge.cs` drives THIS over `[DllImport("__Internal")]`.
//
// 🔴 SCOPE MIRRORS ANDROID EXACTLY: auth + playtime, nothing else. Coins and ads live in C#
// on both platforms (GogCoins.cs / GogAds.cs over UnityWebRequest), so this file must NOT
// boot the `GOG` facade — that would run a second ad-at-open and a second wallet sweep
// alongside the C# ones, and the player would see two interstitials at game open.
//
// ABI rules, all of them load-bearing:
//   - Every string crossing IN is UTF-8 and borrowed for the duration of the call only.
//   - Every string RETURNED by a function is `strdup`ed, and the caller hands it back to
//     `gog_bridge_free`. The binding receives it as an `IntPtr` and decodes the UTF-8 itself
//     rather than trusting the marshaller's string conversion — the allocator and the
//     encoding are then both stated in one place instead of assumed in two.
//   - Every async result arrives as ONE JSON object, on the MAIN thread, through the C
//     function pointer the call supplied, tagged with the caller's request id. On iOS the
//     main thread is Unity's main thread, so a reverse P/Invoke there is always legal.
//   - Nothing here assumes it was CALLED on the main thread. The C# side does call from
//     there, but a game calling from a worker must get a result, not a trap.
// ─────────────────────────────────────────────────────────────────────────────

/// `void (*)(int32_t requestId, const char *json)`
public typealias GogBridgeCallback = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

/// `void (*)(int32_t kind, const char *json)` — see `UnityBridgeEvent`.
public typealias GogBridgeEventCallback = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

/// Unsolicited transitions the binding must hear about. Raw values are ABI.
enum UnityBridgeEvent: Int32 {
    /// The refresh token died (401) or the account was banned. The stored session is gone.
    /// Android's `GogStateListener.onSignedOut`.
    case sessionExpired = 1
}

// MARK: - The bridge, minus the C

/// Everything the C entry points do, without the C.
///
/// Separate so that result encoding, the error-token table and event filtering are tested in
/// Swift against a scripted transport — the C layer below it is a line or two per function.
struct UnityBridgeCore: Sendable {
    let identity: GogIdentity
    let gameId: UUID

    /// `GogAuth.SignInWithCode` — the escape hatch for a game with its own link plumbing.
    ///
    /// `.forwardLaunch`, because a code handed over by game code carries no promise that a
    /// verifier exists. If one IS pending the exchange still attaches it; the flow only decides
    /// what a MISSING verifier means.
    func signIn(code: String) async -> String {
        do { return BridgeResult.user(try await identity.signIn(code: code, flow: .forwardLaunch)) }
        catch { return BridgeResult.failure(error) }
    }

    /// `GogAuth.SignInWithGog` — the reverse handoff through the hub's web sign-in.
    func signInWithGog() async -> String {
        do { return BridgeResult.user(try await identity.signInWithGog()) }
        catch { return BridgeResult.failure(error) }
    }

    /// `GogAuth.GetAccessToken` — refreshing first if the token is near expiry.
    func accessToken() async -> String {
        do { return BridgeResult.token(try await identity.getAccessToken()) }
        catch { return BridgeResult.failure(error) }
    }

    /// A Universal Link handed over by `GogDeepLink`.
    ///
    /// `handled: false` means the URL is not this game's launch link at all, which the binding
    /// logs; the SDK stays silent about it, exactly as `trySignInFromLaunch(url:)` does.
    func handleLaunch(url: URL) async -> String {
        do {
            guard try await identity.trySignInFromLaunch(url: url) else {
                return BridgeResult.launch(handled: false, user: nil)
            }
            return BridgeResult.launch(handled: true, user: await identity.currentUser)
        } catch {
            return BridgeResult.failure(error)
        }
    }

    func signOut() async { await identity.signOut() }

    /// `GogAuth.CurrentSession` is a plain property on the C# side, so this is synchronous.
    func currentUserJSON() -> String? {
        identity.storedUserSnapshot().map(BridgeResult.userObject)
    }

    /// Whether `url` is THIS game's launch link — synchronous, so the binding can raise
    /// `OnSignInStarted` before the round trip rather than after it.
    func isLaunchLink(_ url: URL) -> Bool {
        (try? LaunchLinkValidator.validate(url, expecting: gameId)) != nil
    }

    /// Forward ONLY the unsolicited sign-out.
    ///
    /// The identity's stream also carries `signedIn` and `signedOut(.userRequested)`, but the
    /// binding already raises those itself from the explicit call that caused them — Android
    /// forwards only the headless transitions for the same reason. Forwarding them too would
    /// fire every `OnSignedIn` twice.
    func watchSessionExpiry(_ onExpired: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        let identity = self.identity
        return Task {
            for await event in await identity.eventStream() {
                if case .signedOut(.sessionExpired) = event { onExpired() }
            }
        }
    }
}

// MARK: - The wire format

/// The one JSON object every async call resolves with.
///
/// Error REASONS are this SDK's own stable tokens rather than Android's strings: the binding
/// maps them in `IosAuthBridge.MapReason`, and a table-driven test on each side pins the set.
enum BridgeResult {

    private struct Wire: Encodable {
        var ok: Bool
        var handled: Bool?
        var token: String?
        var user: GogUser?
        var reason: String?
        var message: String?
        var retryable: Bool?
    }

    static func user(_ user: GogUser) -> String { encode(Wire(ok: true, user: user)) }

    static func token(_ token: String) -> String { encode(Wire(ok: true, token: token)) }

    static func launch(handled: Bool, user: GogUser?) -> String {
        encode(Wire(ok: true, handled: handled, user: user))
    }

    static func failure(_ error: Error) -> String {
        guard let gog = error as? GogError else {
            return encode(Wire(ok: false, reason: "internal",
                               message: "Unexpected error: \(type(of: error))", retryable: false))
        }
        return encode(Wire(ok: false, reason: reason(for: gog),
                           message: gog.description, retryable: retryable(gog)))
    }

    static let notInitialized = encode(Wire(ok: false, reason: "not_initialized",
                                            message: "GogSdk.Initialize() was not called.",
                                            retryable: false))

    /// A bare `GogUser` object — what `currentUserJSON` returns.
    static func userObject(_ user: GogUser) -> String {
        guard let data = try? JSONEncoder().encode(user) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Stable token per case. Exhaustive ON PURPOSE: a new `GogError` case is a compile error
    /// here, not a silent "internal" on the C# side.
    static func reason(for error: GogError) -> String {
        switch error {
        case .network:              return "network"
        case .unauthorized:         return "unauthorized"
        case .rateLimited:          return "rate_limited"
        case .insufficientFunds:    return "insufficient_funds"
        case .earnTooLarge:         return "earn_too_large"
        case .idempotencyKeyReused: return "idempotency_key_reused"
        case .invalidInput:         return "invalid_input"
        case .unknownGame:          return "unknown_game"
        case .cityRequired:         return "city_required"
        case .server:               return "server"
        case .malformedResponse:    return "malformed_response"
        case .accountBanned:        return "account_banned"
        case .signInCancelled:      return "sign_in_cancelled"
        case .invalidOrExpiredCode: return "invalid_or_expired_code"
        case .signInInProgress:     return "sign_in_in_progress"
        case .launchLinkInvalid:    return "launch_link_invalid"
        case .notConfigured:        return "not_configured"
        }
    }

    /// The transport's own opinion. The binding still overrides it by CONTEXT — a network
    /// failure on a code exchange is not retryable, because the code is probably spent.
    private static func retryable(_ error: GogError) -> Bool {
        if case .network(_, let retryable) = error { return retryable }
        return false
    }

    private static func encode(_ wire: Wire) -> String {
        guard let data = try? JSONEncoder().encode(wire) else {
            return #"{"ok":false,"reason":"internal","message":"result could not be encoded"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Process-wide state

/// The one live bridge. A lock rather than an actor because two of the entry points are
/// synchronous by contract (`CurrentSession`, the launch-link check) and must not await.
final class UnityBridgeHost: @unchecked Sendable {

    static let shared = UnityBridgeHost()

    private let lock = NSLock()
    private var core: UnityBridgeCore?
    private var playtime: GogPlaytime?
    private var eventTask: Task<Void, Never>?

    var current: UnityBridgeCore? {
        lock.lock(); defer { lock.unlock() }
        return core
    }

    /// Boot identity and playtime — and nothing else; see the scope note at the top.
    ///
    /// A second call is a no-op, mirroring `GogSdk.Initialize()`: runtime reconfiguration
    /// does not exist, which is what keeps C# and native from holding different game ids.
    func initialize(gameId rawGameId: String, apiBaseUrl rawBaseURL: String,
                    onSessionExpired: @escaping @Sendable () -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard core == nil else { return }

        guard let gameId = UUID(uuidString: rawGameId) else {
            throw GogError.notConfigured("Game ID \"\(rawGameId)\" is not a UUID.")
        }
        guard let baseURL = URL(string: rawBaseURL) else {
            throw GogError.notConfigured("API base URL \"\(rawBaseURL)\" is not a URL.")
        }
        // The version handshake is the binding's job, exactly as on Android: C# compares
        // `gog_bridge_sdk_version()` with its own constant before calling this.
        let configuration = GogConfiguration(gameId: gameId, baseURL: baseURL)
        let transport = URLSessionTransport()
        let identity = try GogIdentity(configuration: configuration,
                                       store: GOG.defaultSecureStore(),
                                       transport: transport)
        let bridge = UnityBridgeCore(identity: identity, gameId: gameId)

        // Same first move as `GOG.initialize`: nothing abandoned outlives its bound.
        Task { await identity.sweepStaleSignInState() }
        eventTask = bridge.watchSessionExpiry(onSessionExpired)
        playtime = Self.startPlaytime(configuration: configuration, transport: transport,
                                      identity: identity)
        core = bridge
    }

    /// Drop the bridge. Does NOT sign out — the stored session survives a
    /// `Shutdown()`/`Initialize()` cycle, as on Android.
    func shutdown() {
        lock.lock()
        let bridge = core, meter = playtime, events = eventTask
        core = nil; playtime = nil; eventTask = nil
        lock.unlock()

        events?.cancel()
        #if canImport(UIKit)
        Task { @MainActor in
            UnityPlaytimeHook.live?.stop()
            UnityPlaytimeHook.live = nil
        }
        #endif
        Task {
            // Bank what has accrued rather than losing it to teardown, as `GOG.shutdown` does.
            await meter?.onBackground()
            await bridge?.identity.finishEvents()
        }
    }

    /// Playtime rides along with init, exactly as android-core's `GogAuthCore.initialize`
    /// starts `GogPlaytime` — a studio gets it by updating the package, with no code.
    private static func startPlaytime(configuration: GogConfiguration,
                                      transport: any GogTransport,
                                      identity: GogIdentity) -> GogPlaytime? {
        guard let fileURL = try? PlaytimeQueue.defaultFileURL() else {
            GogLog.warn("playtime: no Application Support directory — metering is off")
            return nil
        }
        let playtime = GogPlaytime(
            gameId: configuration.gameId,
            deviceId: GogDeviceId.resolve(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            queue: PlaytimeQueue(fileURL: fileURL),
            uploader: PlaytimeUploader(baseURL: configuration.baseURL, transport: transport,
                                       accessToken: { try? await identity.getAccessToken() }))
        #if canImport(UIKit)
        Task { @MainActor in
            let hook = PlaytimeAutoHook(playtime: playtime)
            UnityPlaytimeHook.live = hook
            hook.start()
        }
        #endif
        return playtime
    }
}

#if canImport(UIKit)
/// The lifecycle/input hook is main-actor bound, so it lives apart from the lock-guarded state.
@MainActor
enum UnityPlaytimeHook {
    static var live: PlaytimeAutoHook?
}
#endif

/// A C function pointer, carried across a `Task` and back to the main thread.
struct BridgeReply: @unchecked Sendable {
    let requestId: Int32
    let callback: GogBridgeCallback

    func send(_ json: String) {
        let reply = self
        DispatchQueue.main.async {
            json.withCString { reply.callback(reply.requestId, $0) }
        }
    }
}

private struct BridgeEventSink: @unchecked Sendable {
    let callback: GogBridgeEventCallback
    func send(_ event: UnityBridgeEvent) {
        let sink = self
        DispatchQueue.main.async { "{}".withCString { sink.callback(event.rawValue, $0) } }
    }
}

private func string(_ pointer: UnsafePointer<CChar>?) -> String? {
    pointer.map { String(cString: $0) }
}

private func duplicate(_ value: String) -> UnsafeMutablePointer<CChar>? {
    strdup(value)
}

// MARK: - The C ABI
//
// `public` only because a symbol has to be exported to survive dead-stripping in a release
// build; the leading underscore keeps them out of anyone's autocomplete. The C names are the
// contract with `IosAuthBridge.cs`, and that file's `DllImport`s must match them exactly.

/// Release a string this bridge returned. The one allocator, named once.
@_cdecl("gog_bridge_free")
public func _gogBridgeFree(_ pointer: UnsafeMutablePointer<CChar>?) {
    free(pointer)
}

/// The core's version, for the binding↔core handshake (contract §1.5). Caller frees.
///
/// Read from `GogSDKVersion.compiled` — the bytes the release check finds with `strings` —
/// so the version C# compares at boot is the one that was verified in the artifact.
@_cdecl("gog_bridge_sdk_version")
public func _gogBridgeSDKVersion() -> UnsafeMutablePointer<CChar>? {
    duplicate(GogSDKVersion.compiled.description)
}

/// Boot the bridge. Returns NULL on success, or an error message the caller throws with
/// (and frees). `onEvent` receives `UnityBridgeEvent` kinds on the main thread.
@_cdecl("gog_bridge_initialize")
public func _gogBridgeInitialize(_ gameId: UnsafePointer<CChar>?,
                                 _ apiBaseUrl: UnsafePointer<CChar>?,
                                 _ onEvent: GogBridgeEventCallback?) -> UnsafeMutablePointer<CChar>? {
    let sink = onEvent.map(BridgeEventSink.init)
    do {
        try UnityBridgeHost.shared.initialize(
            gameId: string(gameId) ?? "",
            apiBaseUrl: string(apiBaseUrl) ?? "",
            onSessionExpired: { sink?.send(.sessionExpired) })
        return nil
    } catch {
        return duplicate(String(describing: error))
    }
}

@_cdecl("gog_bridge_shutdown")
public func _gogBridgeShutdown() {
    UnityBridgeHost.shared.shutdown()
}

@_cdecl("gog_bridge_sign_in_with_code")
public func _gogBridgeSignInWithCode(_ requestId: Int32,
                                     _ code: UnsafePointer<CChar>?,
                                     _ callback: GogBridgeCallback?) {
    guard let callback else { return }
    let reply = BridgeReply(requestId: requestId, callback: callback)
    guard let bridge = UnityBridgeHost.shared.current else { return reply.send(BridgeResult.notInitialized) }
    let code = string(code) ?? ""
    Task { reply.send(await bridge.signIn(code: code)) }
}

@_cdecl("gog_bridge_sign_in_with_gog")
public func _gogBridgeSignInWithGog(_ requestId: Int32, _ callback: GogBridgeCallback?) {
    guard let callback else { return }
    let reply = BridgeReply(requestId: requestId, callback: callback)
    guard let bridge = UnityBridgeHost.shared.current else { return reply.send(BridgeResult.notInitialized) }
    Task { reply.send(await bridge.signInWithGog()) }
}

@_cdecl("gog_bridge_get_access_token")
public func _gogBridgeGetAccessToken(_ requestId: Int32, _ callback: GogBridgeCallback?) {
    guard let callback else { return }
    let reply = BridgeReply(requestId: requestId, callback: callback)
    guard let bridge = UnityBridgeHost.shared.current else { return reply.send(BridgeResult.notInitialized) }
    Task { reply.send(await bridge.accessToken()) }
}

@_cdecl("gog_bridge_handle_launch_url")
public func _gogBridgeHandleLaunchURL(_ requestId: Int32,
                                      _ url: UnsafePointer<CChar>?,
                                      _ callback: GogBridgeCallback?) {
    guard let callback else { return }
    let reply = BridgeReply(requestId: requestId, callback: callback)
    guard let bridge = UnityBridgeHost.shared.current else { return reply.send(BridgeResult.notInitialized) }
    guard let raw = string(url), let parsed = URL(string: raw) else {
        return reply.send(BridgeResult.launch(handled: false, user: nil))
    }
    Task { reply.send(await bridge.handleLaunch(url: parsed)) }
}

/// 1 when `url` is this game's launch link, else 0. Synchronous.
@_cdecl("gog_bridge_is_launch_link")
public func _gogBridgeIsLaunchLink(_ url: UnsafePointer<CChar>?) -> Int32 {
    guard let bridge = UnityBridgeHost.shared.current,
          let raw = string(url), let parsed = URL(string: raw) else { return 0 }
    return bridge.isLaunchLink(parsed) ? 1 : 0
}

/// The stored player as `{"id":…,"email":…}`, or NULL when signed out. Caller frees.
@_cdecl("gog_bridge_current_user_json")
public func _gogBridgeCurrentUserJSON() -> UnsafeMutablePointer<CChar>? {
    UnityBridgeHost.shared.current?.currentUserJSON().flatMap(duplicate)
}

/// Local sign-out. SYNCHRONOUS by contract (§2, C5): `GogAuth.SignOut()` raises
/// `OnSignedOut` as soon as this returns, and a `CurrentSession` read straight after it must
/// already say signed out. The work is one Keychain delete behind an actor that never needs
/// the main thread, so waiting here cannot deadlock; the bound is belt-and-braces.
@_cdecl("gog_bridge_sign_out")
public func _gogBridgeSignOut() {
    guard let bridge = UnityBridgeHost.shared.current else { return }
    let done = SignOutLatch()
    Task {
        await bridge.signOut()
        done.signal()
    }
    done.wait(seconds: 2)
}

/// A semaphore that may cross into a `Task` under Swift 6.
private final class SignOutLatch: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func signal() { semaphore.signal() }
    func wait(seconds: Double) { _ = semaphore.wait(timeout: .now() + seconds) }
}
