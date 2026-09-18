import Foundation

/// The two hosts, and what each one is FOR.
///
/// Both are ours — the §4.1 anchor requires the vouching host to be one GOG serves AASA for,
/// which was never "exactly one hostname", only "never partner-owned domains". The split is
/// required, not cosmetic:
///
/// Apple's TN3155: a Universal Link with the **same domain as the previous navigation** does
/// not open the app — the browser assumes the user means to keep browsing. With hub sign-in
/// and game launch on one host, the hub-not-installed fallback becomes Safari at `…/auth` →
/// sign in → navigate to `…/launch/<uuid>` → same domain, game never opens, and a live 120s
/// credential is stranded in the browser with nobody to receive it. TN3155 prescribes the fix
/// directly: *"Using a different subdomain prevents the web browser from treating the link as
/// navigation."*
///
/// It also moots an ambiguity nobody can test without a Team ID: Apple's note that
/// `UIApplication.open` on a Universal Link *to your website* won't open *your app* is
/// ambiguous between "that app" and "your whole associated domain", and the forward launch is
/// the hub calling `open()` on a host it is also associated with.
///
/// **The roles do not overlap.** The hub must never claim `/launch/*` — two apps claiming one
/// path is undefined OS behaviour — and a launch link must never arrive on the hub host,
/// because that would put the two legs back on one domain and re-open the failure above.
public enum GogHosts {

    /// Claimed by the HUB app, path `/auth`. Serves the hub's web sign-in.
    public static let hub = "hub.godofgaming.online"

    /// Claimed by EACH GAME, path `/launch/<its-own-game-id>`. Serves launch links and the
    /// hub-not-installed fallback pages.
    public static let link = "link.godofgaming.online"

    static let launchPathPrefix = "/launch/"
    static let authPath = "/auth"
}

/// Where the launch code rides in the URL.
///
/// 🔴 **This is an OPEN DECISION.** The default below is a recommendation, not a
/// ratification, and it is deliberately a single switch so that settling it is a one-line
/// change rather than a code-writing task.
///
/// The case for `.fragment`: a query string is part of the HTTP request line, so on every
/// open where the app is not installed the live 120-second credential is written to server
/// access logs and `Referer` headers **before any page code runs**. A fragment is never
/// transmitted, and Universal Links still hand the app the complete URL via
/// `NSUserActivity.webpageURL`, so nothing is lost on the installed path.
///
/// The case for `.query`: it is what the frozen contract says and what Android ships today,
/// so `.fragment` is an iOS-only divergence until an Android release converges them.
///
/// **Whichever is active, the other is REJECTED, loudly.** "Accept both" would mean knowingly
/// consuming a credential that has already leaked.
public enum LaunchCodeDelimiter: String, Sendable, Equatable {
    /// `…/launch/<id>#code=…` — recommended.
    case fragment
    /// `…/launch/<id>?code=…` — the current frozen contract, and what Android ships.
    case query
}

/// A request to hand the player to the hub for sign-in.
public struct ReverseHandoffRequest: Sendable, Equatable {
    /// Open this with `ASWebAuthenticationSession`. Always on the hub host.
    public let url: URL
    /// The S256 challenge sent to the hub. Its verifier is already persisted.
    public let codeChallenge: String
}

/// Builds the hub-facing URL. One place, so the host cannot drift.
public enum GogHubURL {
    /// `https://hub.godofgaming.online/auth?game_id=<uuid>&code_challenge=<base64url-sha256>`
    ///
    /// There is deliberately NO `redirect_uri` parameter. The hub derives the return target
    /// from `game_id` against the catalogue, never from the caller, which makes the entire
    /// open-redirect class structurally absent rather than defended against.
    public static func reverseHandoff(gameId: UUID, codeChallenge: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = GogHosts.hub
        components.path = GogHosts.authPath
        components.queryItems = [
            URLQueryItem(name: "game_id", value: gameId.uuidString.lowercased()),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
        ]
        // Force-unwrap is safe: every component is a literal or a UUID/base64url string.
        return components.url!
    }
}
