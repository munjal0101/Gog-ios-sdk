import Foundation

/// The outcome of one interstitial opportunity.
public enum GogAdOutcome: Sendable, Equatable {
    /// An ad was displayed to the player.
    case shown
    /// No ad was displayed. A NORMAL, frequent, SUCCESSFUL outcome (invariant I7) — the server
    /// declining to serve, an expired directive, or a creative that could not be shown. Game
    /// flow must never depend on an ad rendering.
    case noAd
}

/// A struct rather than a bare enum so v1.1 can add data (network, revenue) additively —
/// changing the returned type would be a re-typing, forbidden until 2.0.
public struct GogAdResult: Sendable, Equatable {
    public let outcome: GogAdOutcome
    init(_ outcome: GogAdOutcome) { self.outcome = outcome }
}

// ─────────────────────────────────────────────────────────────────────────────
// Wire types. `/ads/next` is a DISCRIMINATED UNION: `{"type":"none"}` carries nothing
// else, while a house directive carries five more fields. Decoding is therefore two-stage —
// read the discriminator, then decode that variant with NON-OPTIONAL fields.
//
// A single flat DTO with everything optional would have been simpler and wrong: it would
// silently accept a `house` directive with no creative and resolve it as "no ad", which is
// precisely the wrong-success shape non-optional fields exist to prevent.
// ─────────────────────────────────────────────────────────────────────────────

struct AdEnvelopeDTO: Decodable, Sendable {
    let type: String
}

struct AdCreativeDTO: Decodable, Sendable, Equatable {
    /// Operator-facing and safe to log — unlike `impressionId`, which is not (I8).
    let id: String
    let imageUrl: String
    /// Nullable on the wire — verified against production.
    let clickUrl: String?

    /// 🔴 **Optional, with a default — matching `GogAdDirective.cs`.**
    ///
    /// Production sends it today, but Android parses it as `int?` on purpose: making the
    /// forced-view window dashboard-controllable is then a pure backend change with no SDK
    /// release. A non-optional field here would turn a server that stops sending it into a
    /// `malformedResponse` — an ERROR where Android shows the ad — which is the forward
    /// tolerance in I9 read backwards.
    private let rawForcedViewSeconds: Int?

    /// The window, resolved: the server's value when present, then clamped.
    ///
    /// 🔴 **The clamp is what makes the field safe to hand to an operator.** Android:
    /// *"a typo of 6000 cannot trap a player in an ad they are not allowed to dismiss."*
    /// Without it, a dashboard mistake leaves the close control hidden until the 90s
    /// failsafe rescues the player — 90 seconds after they wanted out.
    var forcedViewSeconds: Int {
        guard let raw = rawForcedViewSeconds else { return Self.defaultForcedViewSeconds }
        return min(max(raw, Self.minForcedViewSeconds), Self.maxForcedViewSeconds)
    }

    /// `GogAdDirective.cs`: `DefaultImageForcedViewSeconds = 4f` — mid-band of the approved
    /// 3–5s range, so a later tweak in either direction is a small move.
    static let defaultForcedViewSeconds = 4
    /// `MinForcedViewSeconds = 1f`
    static let minForcedViewSeconds = 1
    /// `MaxForcedViewSeconds = 30f`
    static let maxForcedViewSeconds = 30

    private enum CodingKeys: String, CodingKey {
        case id
        case imageUrl = "image_url"
        case clickUrl = "click_url"
        case rawForcedViewSeconds = "forced_view_seconds"
    }
}

struct AdHouseDTO: Decodable, Sendable {
    /// 🔴 I8: held INSIDE the SDK and never returned, never logged. It exists here only
    /// because the wire carries it; nothing reads it out.
    let impressionId: String
    let creative: AdCreativeDTO
    /// Seconds. The TTL is taken from THIS, on a monotonic clock, at receipt — never from
    /// `expires_at`, which is wall-clock and player-settable.
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case impressionId = "impression_id"
        case creative
        case expiresIn = "expires_in"
    }
}

/// What the SDK decided the server said.
enum AdDirective: Sendable {
    case house(AdHouseDTO)
    case admob
    case none
    /// Forward tolerance (I9): a discriminator this build does not know resolves to a
    /// module-safe default rather than an error.
    case unknownType(String)
}

enum AdDirectiveInterpreter {

    /// Build the `/ads/next` URL. Mirrors `GogAdDirective.BuildUrl` on Android exactly,
    /// including parameter order and the two optional parameters.
    static let path = "/ads/next"

    static func query(gameId: UUID, userId: String?, index: Int, trigger: String?) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "game_id", value: gameId.uuidString.lowercased()),
            URLQueryItem(name: "index", value: String(index)),
        ]
        // Optional and additive: it unlocks city-targeted creatives. Best-effort — never fail
        // an ad over targeting.
        if let userId, !userId.isEmpty { items.append(URLQueryItem(name: "user_id", value: userId)) }
        if let trigger, !trigger.isEmpty { items.append(URLQueryItem(name: "trigger", value: trigger)) }
        return items
    }

    /// Two-stage decode. Throws `.malformedResponse` when the discriminator says one thing and
    /// the payload is another — that is a real fault, not a "no ad".
    static func interpret(_ data: Data) throws -> AdDirective {
        let decoder = JSONDecoder()
        let envelope: AdEnvelopeDTO
        do { envelope = try decoder.decode(AdEnvelopeDTO.self, from: data) }
        catch { throw GogErrorMapper.decodeFailure(error) }

        switch envelope.type {
        case "none":
            return .none
        case "admob":
            return .admob
        case "house":
            do { return .house(try decoder.decode(AdHouseDTO.self, from: data)) }
            catch { throw GogErrorMapper.decodeFailure(error) }
        default:
            return .unknownType(envelope.type)
        }
    }
}
