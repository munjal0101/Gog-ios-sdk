import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // Linux: URLSession lives here
#endif

/// A prepared request, fully resolved. Deliberately our own Sendable value type rather
/// than `URLRequest`: it keeps every Foundation-networking detail inside
/// `URLSessionTransport`, which is the ONLY part of the pipeline that cannot be exercised
/// by a unit test. Everything above this line is testable on any platform.
struct GogWireRequest: Sendable {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data?
    let timeout: TimeInterval
}

/// A response reduced to the Sendable facts the pipeline actually uses.
struct GogWireResponse: Sendable {
    let status: Int
    /// Lower-cased keys — HTTP header names are case-insensitive and Foundation's casing
    /// is not guaranteed to be stable across platforms.
    let headers: [String: String]

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// The single seam between the SDK and the network.
///
/// This exists so the three failure modes that bit Android — a malformed 200, a
/// valid-JSON-wrong-shape 200, and a replay after process death — can be tested
/// deterministically, without a loopback server and without a Mac.
protocol GogTransport: Sendable {
    func perform(_ request: GogWireRequest) async throws -> (Data, GogWireResponse)
}

/// The production transport. The only file in the pipeline that touches URLSession.
struct URLSessionTransport: GogTransport {
    let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: Self.hardenedConfiguration())
    }

    /// A session configuration that CANNOT carry state across an account boundary.
    ///
    /// 🔴 Why this is not `URLSession.shared`. `URLCache` keys on the URL and ignores the
    /// Authorization header, and the API sets no `Cache-Control` on `GET /me/wallet`. On the
    /// shared session that combination means player A's balance can be served from cache to
    /// player B after a sign-out — same URL, no network call, no error. The shared session
    /// also carries a process-wide cookie jar and credential store that outlive a sign-out.
    ///
    /// This is the same class of bug as replaying a pending operation under the wrong
    /// account: state that belongs to one session being read under another. The SDK does not
    /// rely on the server sending the right headers for a correctness property it can
    /// guarantee itself.
    static func hardenedConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = GogHTTP.timeout
        return config
    }

    func perform(_ request: GogWireRequest) async throws -> (Data, GogWireResponse) {
        var req = URLRequest(url: request.url)
        req.httpMethod = request.method
        req.httpBody = request.body
        req.timeoutInterval = request.timeout
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }

        return try await withCheckedThrowingContinuation { cont in
            let task = session.dataTask(with: req) { data, response, error in
                if let error = error as NSError? {
                    cont.resume(throwing: GogError.network(Self.reason(for: error),
                                                           retryable: Self.isRetryable(error)))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    cont.resume(throwing: GogError.network(.transport("non-HTTP response"),
                                                           retryable: false))
                    return
                }
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    if let k = key as? String, let v = value as? String {
                        headers[k.lowercased()] = v
                    }
                }
                cont.resume(returning: (data ?? Data(),
                                        GogWireResponse(status: http.statusCode, headers: headers)))
            }
            task.resume()
        }
    }

    private static func reason(for error: NSError) -> GogNetworkReason {
        guard error.domain == NSURLErrorDomain else { return .transport(error.domain) }
        switch error.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDataNotAllowed:
            return .offline
        case NSURLErrorTimedOut:
            return .timedOut
        case NSURLErrorCancelled:
            return .cancelled
        default:
            // The numeric code only — never `localizedDescription`, which on some paths
            // embeds the failing URL, and our URLs carry credentials on the launch leg.
            return .transport("URLError \(error.code)")
        }
    }

    private static func isRetryable(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet:
            return true
        default:
            return false
        }
    }
}
