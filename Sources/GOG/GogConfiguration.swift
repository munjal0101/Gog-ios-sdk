import Foundation

/// SDK configuration. Immutable once handed to the SDK.
public struct GogConfiguration: Sendable {

    /// THE base URL. One constant, one source of truth, no stale default anywhere else in
    /// the SDK.
    ///
    /// This is not stylistic. A mint harness that carried its own default pointing at the
    /// dead Railway host "succeeded" partway through before failing confusingly, and it
    /// cost real time. Any future component that needs a base URL takes it from a
    /// `GogConfiguration` — it does not get to hold a fallback of its own.
    public static let defaultBaseURL = URL(string: "https://gog-api.fly.dev")!

    public let baseURL: URL

    /// The game's catalogue UUID. Platform-independent: the iOS build of a game uses the
    /// SAME game_id as its Android row.
    ///
    /// (Whether the catalogue is in fact one row per game or one row per game per platform
    /// is still an OPEN question owned by the backend lane. Nothing in this type depends on
    /// the answer — it holds whichever id it is given.)
    public let gameId: UUID

    /// The version string the calling BINDING was built with — the C# side of the Unity
    /// package, or any other wrapper. `nil` for a native SPM consumer, which has no binding
    /// and therefore nothing to handshake with.
    ///
    /// Contract §1.5: when a binding is present, its version and the core's must be equal by
    /// ORDINAL STRING EQUALITY, and a mismatch throws at configure time. The rationale is
    /// that binding and core ship together in one package, so any inequality means the
    /// install was tampered with or partially updated.
    public let bindingVersion: String?

    /// Where the launch code rides. See `LaunchCodeDelimiter` — this is an open decision and
    /// this is the one switch that settles it.
    public let launchCodeDelimiter: LaunchCodeDelimiter

    /// Capture launch links automatically. Mirrors `GogSettings.AutoSignInFromLaunch`,
    /// default `true`.
    ///
    /// When false, a launch link is only acted on if the host calls
    /// `GOG.handle(url:)` itself — the manual mode the contract describes for games that own
    /// their own link plumbing.
    public let autoSignInFromLaunch: Bool

    /// AdMob **application** id — `ca-app-pub-…~…`, with a TILDE.
    ///
    /// 🔴 The trap this validation exists for: the app id (tilde, belongs in build settings)
    /// and the ad **unit** id (`ca-app-pub-…/…`, SLASH, comes from `/ads/next`) look nearly
    /// identical and are routinely swapped. Swapping them is a launch crash or a silent
    /// no-fill. They must also belong to the SAME AdMob account or AdMob will not fill.
    ///
    /// A settings field, never an SDK constant.
    public let admobAppId: String?

    public init(gameId: UUID,
                baseURL: URL = GogConfiguration.defaultBaseURL,
                bindingVersion: String? = nil,
                launchCodeDelimiter: LaunchCodeDelimiter = .fragment,
                autoSignInFromLaunch: Bool = true,
                admobAppId: String? = nil) {
        self.gameId = gameId
        self.baseURL = baseURL
        self.bindingVersion = bindingVersion
        self.launchCodeDelimiter = launchCodeDelimiter
        self.autoSignInFromLaunch = autoSignInFromLaunch
        self.admobAppId = admobAppId
    }

    /// `ca-app-pub-<16 digits>~<10 digits>`. The tilde is the whole point — an ad UNIT id
    /// uses a slash and will not validate here.
    public static func isValidAdmobAppId(_ id: String) -> Bool {
        id.range(of: "^ca-app-pub-[0-9]{16}~[0-9]{10}$", options: .regularExpression) != nil
    }

    /// Fail closed at configure time rather than at first use.
    func validate() throws {
        // §1.5 handshake. Ordinal string equality — no semver parsing, deliberately.
        if let binding = bindingVersion, binding != GogSDKVersion.value {
            throw GogError.notConfigured(
                "GOG SDK version mismatch: the binding reports \"\(binding)\" but the native "
                + "core is \"\(GogSDKVersion.value)\". Binding and core ship together in one "
                + "package, so this means a partial or tampered install. Reinstall the GOG SDK "
                + "package rather than updating one half."
            )
        }
        // An unstamped core WARNS rather than throws. Throwing would make the package
        // unusable in local development, and the guarantee that actually matters — that a
        // shipped binding and core agree — is the check above. The release gate for
        // stamping is scripts/release/verify-version-square.mjs, run against BUILT
        // ARTIFACTS, which is the only reading that cannot lie.
        if GogSDKVersion.isUnstamped {
            GogLog.warn(
                "this build was not stamped by the release script "
                + "(GogSDKVersion.value == \"\(GogSDKVersion.value)\"). Fine for development; "
                + "never ship it."
            )
        }
        if baseURL.scheme?.lowercased() != "https" {
            throw GogError.notConfigured(
                "GOG base URL must be https. Got: \(baseURL.scheme ?? "nil")"
            )
        }
        // Fail at configure time rather than at first ad. A swapped unit id here is a launch
        // crash or a silent no-fill, and neither says what happened.
        if let admobAppId, !Self.isValidAdmobAppId(admobAppId) {
            throw GogError.notConfigured(
                "admobAppId \"\(admobAppId)\" is not an AdMob APPLICATION id. Expected "
                + "ca-app-pub-<16 digits>~<10 digits> — note the TILDE. An id with a SLASH is "
                + "an ad UNIT id, which comes from the server and must not be set here."
            )
        }
    }
}
