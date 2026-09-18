import Foundation

/// One `engagement.playtime` event, in the envelope the server ingests.
///
/// Field names and shape are mirrored from the Android builder verbatim — the two platforms
/// feed the same analytics tables, so a renamed or missing field would land as a gap in the
/// dashboards rather than as an error anywhere.
struct PlaytimeEvent: Codable, Sendable, Equatable {
    let eventId: String
    let eventName: String
    let schemaVersion: Int
    let envelopeVersion: Int
    let occurredAt: String
    let deviceId: String
    let sessionId: String
    let profileId: String?
    let gameId: String
    let platform: String
    let appVersion: String?
    let sdkVersion: String
    let payload: Payload
    let context: Context

    struct Payload: Codable, Sendable, Equatable {
        let activeMs: Int64
        let idleMs: Int64
        let touches: Int64
        let idleTimeoutMs: Int64
        private enum CodingKeys: String, CodingKey {
            case activeMs = "active_ms"
            case idleMs = "idle_ms"
            case touches
            case idleTimeoutMs = "idle_timeout_ms"
        }
    }

    struct Context: Codable, Sendable, Equatable {
        let os: String
        let osRelease: String
        let deviceBrand: String
        let deviceModel: String
        private enum CodingKeys: String, CodingKey {
            case os
            case osRelease = "os_release"
            case deviceBrand = "device_brand"
            case deviceModel = "device_model"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case eventName = "event_name"
        case schemaVersion = "schema_version"
        case envelopeVersion = "envelope_version"
        case occurredAt = "occurred_at"
        case deviceId = "device_id"
        case sessionId = "session_id"
        case profileId = "profile_id"
        case gameId = "game_id"
        case platform
        case appVersion = "app_version"
        case sdkVersion = "sdk_version"
        case payload
        case context
    }

    static let name = "engagement.playtime"
}

struct PlaytimeBatch: Encodable, Sendable {
    let sentAt: String
    let events: [PlaytimeEvent]
    private enum CodingKeys: String, CodingKey {
        case sentAt = "sent_at"
        case events
    }
}

/// What the server said about a batch.
enum EventsDelivery: Sendable, Equatable {
    /// Accepted, or rejected in a way retrying cannot fix.
    case delivered
    /// A transport or server fault. Keep the rows and try again.
    case retry
}

/// Posts batches to `POST /events`.
///
/// **A 4xx counts as DELIVERED, not as a failure.** The server validates
/// deny-by-default — a malformed or out-of-bounds slice is rejected permanently, so retrying
/// it forever would be a queue that never drains. That is a deliberate asymmetry with 5xx,
/// and it is why `PlaytimeDelta.isWithinServerBounds` exists: a slice the server will refuse
/// is a measurement silently lost, so it is better not to send one.
actor PlaytimeUploader {

    /// The server's own MAX_EVENTS_PER_BATCH.
    static let maxBatch = 100

    private let http: GogHTTP
    private let accessToken: @Sendable () async -> String?

    init(baseURL: URL, transport: any GogTransport,
         accessToken: @escaping @Sendable () async -> String? = { nil }) {
        self.http = GogHTTP(baseURL: baseURL, transport: transport)
        self.accessToken = accessToken
    }

    func send(_ events: [PlaytimeEvent], sentAt: String) async -> EventsDelivery {
        guard !events.isEmpty else { return .delivered }
        let batch = PlaytimeBatch(sentAt: sentAt, events: events)
        guard let body = try? JSONEncoder().encode(batch) else {
            // Unencodable is our bug, not the server's; retrying cannot fix it.
            GogLog.warn("playtime: a batch could not be encoded and was dropped")
            return .delivered
        }
        do {
            _ = try await http.sendRaw(.post("/events", body: body,
                                             accessToken: await accessToken(),
                                             idempotent: false))
            return .delivered
        } catch let error as GogError {
            switch error {
            case .invalidInput, .unauthorized, .cityRequired, .unknownGame,
                 .invalidOrExpiredCode, .accountBanned:
                // 4xx — permanently rejected. Dropping is correct; a retry loop is not.
                GogLog.warn("playtime: \(events.count) event(s) rejected by the server (\(error)) — dropped")
                return .delivered
            default:
                return .retry
            }
        } catch {
            return .retry
        }
    }

    /// Split into server-sized chunks.
    static func chunk(_ events: [PlaytimeEvent]) -> [[PlaytimeEvent]] {
        stride(from: 0, to: events.count, by: maxBatch).map {
            Array(events[$0..<min($0 + maxBatch, events.count)])
        }
    }
}
