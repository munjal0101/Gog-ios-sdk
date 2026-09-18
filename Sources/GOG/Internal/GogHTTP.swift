import Foundation

/// A request in SDK terms, before it becomes wire bytes.
struct GogRequest: Sendable {
    let method: String
    /// Path only, e.g. "/me/wallet". Joined to the configured base URL — never a full URL,
    /// so no component can smuggle in a different host.
    let path: String
    /// Query items, built with URLComponents rather than appended to `path`.
    ///
    /// They are a separate field for a reason: `URL.appendingPathComponent` percent-encodes
    /// `?`, so a path carrying its own query string becomes `/ads/next%3Fgame_id=...` and the
    /// server answers 404. On the ads path that would present as "no ads ever" with no error
    /// anywhere — the exact silent-failure shape rule 3 exists to prevent.
    let query: [URLQueryItem]?
    let body: Data?
    let accessToken: String?
    /// Whether repeating this request is safe.
    ///
    /// GETs always are. A wallet POST is idempotent *because* it carries an
    /// idempotency_key — which is why the retry policy and the key design are one decision,
    /// not two. A POST without a key must never set this.
    let isIdempotent: Bool

    static func get(_ path: String, query: [URLQueryItem]? = nil, accessToken: String?) -> GogRequest {
        GogRequest(method: "GET", path: path, query: query, body: nil,
                   accessToken: accessToken, isIdempotent: true)
    }

    static func post(_ path: String, body: Data, accessToken: String?,
                     idempotent: Bool) -> GogRequest {
        GogRequest(method: "POST", path: path, query: nil, body: body,
                   accessToken: accessToken, isIdempotent: idempotent)
    }
}

/// The one HTTP + JSON-parse pipeline for the whole SDK.
///
/// Its entire reason to exist is that there is exactly ONE place where a result could fail
/// to be produced, and that place cannot fail to produce one: `send` either returns a
/// decoded value or throws a `GogError`. Both are exactly-once by language guarantee —
/// a function returns or throws, never neither and never both. That is the structural
/// version of what the C# core had to build by hand, and it is why the async idiom here is
/// `async throws` rather than callbacks.
///
/// Guarantees:
///   - 12s timeout (contract §1.4.2)
///   - retry ONCE for idempotent requests on a transient failure
///   - non-optional DTO fields, so a 200 missing a field throws instead of default-filling
///   - unknown JSON fields ignored (forward tolerance, I9) — free with JSONDecoder
///   - every error, from any path, produced by GogErrorMapper
actor GogHTTP {

    static let timeout: TimeInterval = 12

    /// Creative downloads get a SHORTER budget than JSON, matching `GogHttp.cs`: "a slow CDN
    /// must not hold the game while it waits for a picture. Paired with no retry — re-pulling
    /// a failed download doubles the stall, and a creative that will not load is a cheap NoAd."
    static let mediaTimeout: TimeInterval = 10
    private static let retryDelayNanoseconds: UInt64 = 500_000_000  // 0.5s

    private let baseURL: URL
    private let transport: GogTransport
    private let decoder: JSONDecoder

    init(baseURL: URL, transport: GogTransport) {
        self.baseURL = baseURL
        self.transport = transport
        self.decoder = JSONDecoder()
    }

    /// Raw bytes from a path on the configured base URL, with the same status mapping and the
    /// same single retry as `send`. Used where the body is not a JSON DTO the pipeline decodes
    /// for the caller — the ads directive, whose shape is a discriminated union decoded in two
    /// stages by its own interpreter.
    func sendRaw(_ request: GogRequest) async throws -> Data {
        let (data, response) = try await perform(request)
        guard (200...299).contains(response.status) else {
            throw GogErrorMapper.error(status: response.status, body: data, headers: response.headers)
        }
        return data
    }

    /// Fetch an absolute URL that is NOT on the configured base URL — an ad creative served
    /// from object storage. Deliberately separate from `sendRaw`, which joins a path to the
    /// one base URL constant so no component can smuggle in a different host; a creative URL
    /// legitimately points elsewhere, and saying so explicitly keeps that exception visible.
    func sendAbsolute(_ url: URL) async throws -> Data {
        let wire = GogWireRequest(url: url, method: "GET",
                                  headers: ["User-Agent": "gog-ios-sdk/\(GogSDKVersion.value)"],
                                  body: nil, timeout: Self.mediaTimeout)
        let (data, response) = try await transport.perform(wire)
        guard (200...299).contains(response.status) else {
            throw GogErrorMapper.error(status: response.status, body: data, headers: response.headers)
        }
        return data
    }

    func send<T: Decodable & Sendable>(_ request: GogRequest, as: T.Type = T.self) async throws -> T {
        let (data, response) = try await perform(request)

        guard (200...299).contains(response.status) else {
            throw GogErrorMapper.error(status: response.status,
                                       body: data,
                                       headers: response.headers)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GogErrorMapper.decodeFailure(error)
        }
    }

    // MARK: - Transport with the single retry

    private func perform(_ request: GogRequest) async throws -> (Data, GogWireResponse) {
        do {
            let result = try await transport.perform(wire(request))
            // A 5xx on an idempotent request is worth exactly one more attempt.
            if (500...599).contains(result.1.status), request.isIdempotent {
                try? await Task.sleep(nanoseconds: Self.retryDelayNanoseconds)
                return (try? await transport.perform(wire(request))) ?? result
            }
            return result
        } catch let error as GogError {
            guard request.isIdempotent, Self.isRetryable(error) else { throw error }
            try? await Task.sleep(nanoseconds: Self.retryDelayNanoseconds)
            return try await transport.perform(wire(request))
        }
    }

    /// 429 is deliberately NOT retried. It is a considered signal from the server, and an
    /// automatic repeat makes the condition it reports worse. It is surfaced with
    /// `retryAfter` so the caller decides.
    private static func isRetryable(_ error: GogError) -> Bool {
        if case .network(_, let retryable) = error { return retryable }
        return false
    }

    private func wire(_ request: GogRequest) -> GogWireRequest {
        var headers = [
            "Accept": "application/json",
            "User-Agent": "gog-ios-sdk/\(GogSDKVersion.value)",
        ]
        if request.body != nil { headers["Content-Type"] = "application/json" }
        if let token = request.accessToken { headers["Authorization"] = "Bearer \(token)" }

        var components = URLComponents(url: baseURL.appendingPathComponent(request.path),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = request.query
        return GogWireRequest(
            url: components.url ?? baseURL.appendingPathComponent(request.path),
            method: request.method,
            headers: headers,
            body: request.body,
            timeout: Self.timeout
        )
    }
}
