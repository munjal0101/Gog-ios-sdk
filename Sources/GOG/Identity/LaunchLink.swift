import Foundation

/// A launch link that passed every check this SDK can perform.
///
/// It deliberately does NOT carry a code — see `LaunchLinkValidator.extractCode`.
public struct ValidatedLaunchLink: Sendable, Equatable {
    public let gameId: UUID
    public let url: URL
}

/// Validation for `https://link.godofgaming.online/launch/<game_id>`.
///
/// Tighter than Android on purpose. `GogManifestInjector` emits an intent-filter with
/// `pathPrefix="/launch/<game_id>"`, so on Android `/launch/<uuid>anything-else` also
/// matches and the segment is strictly validated nowhere. AASA supports exact-path matching,
/// so iOS gets to be tighter for free — and this validator closes the loose-suffix gap
/// rather than reproducing it.
public enum LaunchLinkValidator {

    /// Launch links live on the LINK host only. See `GogHosts` for why the two hosts exist
    /// and why their roles must not overlap.
    public static var expectedHost: String { GogHosts.link }
    static let launchPathPrefix = GogHosts.launchPathPrefix

    /// Validate host, scheme, path shape, and that the segment is a well-formed UUID equal to
    /// the configured game. Throws `GogError.launchLinkInvalid` — never returns nil, never
    /// merely logs.
    public static func validate(_ url: URL, expecting gameId: UUID) throws -> ValidatedLaunchLink {
        guard url.scheme?.lowercased() == "https" else {
            throw GogError.launchLinkInvalid(.notHTTPS)
        }
        guard let host = url.host?.lowercased() else {
            throw GogError.launchLinkInvalid(.wrongHost(expected: expectedHost, got: "<none>"))
        }
        // 🔴 Neither of the next two is a known hole — in all the cases that prompted them the
        // host really is ours, and iOS only routes Universal Links on 443 anyway. They are here
        // because the set this validator accepts should be exactly the set the hub can emit, and
        // it was wider: a fuzz sweep got `https://evil.com@link.godofgaming.online/launch/<id>`
        // and `https://link.godofgaming.online:8443/launch/<id>` through. Narrowing costs
        // nothing and removes a class of argument about whether it matters.

        // Userinfo has no legitimate place in a launch link, and `evil.com@ourhost` is a
        // long-standing way to make a URL read as someone else's in anything that shows it.
        guard url.user == nil, url.password == nil else {
            throw GogError.launchLinkInvalid(
                .wrongHost(expected: expectedHost, got: "\(url.user ?? "")@\(url.host ?? "")"))
        }
        // Default port or 443, nothing else. Our server is on 443 and Universal Links do not
        // route on anything else, so any explicit alternative is someone else's endpoint.
        if let port = url.port, port != 443 {
            throw GogError.launchLinkInvalid(
                .wrongHost(expected: expectedHost, got: "\(url.host ?? ""):\(port)"))
        }

        let path = url.path

        // Role checks BEFORE the generic host check, so the two-host split fails with a
        // diagnostic that names the actual mistake rather than a vague "wrong host".
        //
        // A launch link that arrives on the HUB host, or an /auth link on the LINK host,
        // means someone has collapsed the two roles back onto one domain — which is
        // precisely the configuration TN3155 says will stop opening the app, and which
        // strands a live credential in Safari when it does.
        if host == GogHosts.hub, path.hasPrefix(launchPathPrefix) {
            throw GogError.launchLinkInvalid(.hostRoleMismatch(host: host, path: path))
        }
        if host == GogHosts.link, path == GogHosts.authPath || path.hasPrefix(GogHosts.authPath + "/") {
            throw GogError.launchLinkInvalid(.hostRoleMismatch(host: host, path: path))
        }

        guard host == expectedHost else {
            throw GogError.launchLinkInvalid(
                .wrongHost(expected: expectedHost, got: url.host ?? "<none>"))
        }
        guard path.hasPrefix(launchPathPrefix) else {
            throw GogError.launchLinkInvalid(.notLaunchPath(path))
        }
        // Exactly one more segment. This is the check Android's pathPrefix cannot make.
        let segment = String(path.dropFirst(launchPathPrefix.count))
        guard !segment.isEmpty, !segment.contains("/") else {
            throw GogError.launchLinkInvalid(.malformedGameIdSegment(segment))
        }
        guard let parsed = UUID(uuidString: segment) else {
            throw GogError.launchLinkInvalid(.malformedGameIdSegment(segment))
        }
        guard parsed == gameId else {
            throw GogError.launchLinkInvalid(.gameIdMismatch(expected: gameId, got: parsed))
        }
        return ValidatedLaunchLink(gameId: parsed, url: url)
    }

    /// Pull the code out of a validated launch link.
    ///
    /// The delimiter is a POLICY, not a guess: `configuration.launchCodeDelimiter` selects
    /// which position is accepted, and the other position is rejected as
    /// `.codeDeliveredInWrongPosition` rather than quietly accepted. See
    /// `LaunchCodeDelimiter` for why "accept both" is the wrong answer.
    public static func extractCode(from url: URL,
                                   delimiter: LaunchCodeDelimiter) throws -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let fromQuery = components?.queryItems?.first { $0.name == "code" }?.value
        let fromFragment = components?.fragment.flatMap { fragment -> String? in
            // A fragment may be a bare value or key=value pairs; parse it as a query string.
            var parser = URLComponents()
            parser.query = fragment
            return parser.queryItems?.first { $0.name == "code" }?.value
        }

        switch delimiter {
        case .fragment:
            if let code = fromFragment, !code.isEmpty { return code }
            if let leaked = fromQuery, !leaked.isEmpty {
                throw GogError.launchLinkInvalid(
                    .codeDeliveredInWrongPosition(expected: "fragment", got: "query"))
            }
        case .query:
            if let code = fromQuery, !code.isEmpty { return code }
            if let misplaced = fromFragment, !misplaced.isEmpty {
                throw GogError.launchLinkInvalid(
                    .codeDeliveredInWrongPosition(expected: "query", got: "fragment"))
            }
        }
        throw GogError.launchLinkInvalid(.missingCode)
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Historical note — the decision this used to block on.
    //
    // Extraction is now implemented behind `LaunchCodeDelimiter`, defaulting to `.fragment`.
    // Ratifying the decision means changing that default (or passing the other value in
    // `GogConfiguration`) — one line, no code to write. The rejection of the non-active form
    // is what keeps "configurable" from becoming "accepts both".
    // ─────────────────────────────────────────────────────────────────────────────
}
