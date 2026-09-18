import Foundation
@testable import GOG

/// A scripted transport. This is the seam that lets the three Android-killing failure modes
/// be reproduced deterministically — no loopback server, no network, no Mac.
actor MockTransport: GogTransport {

    typealias Handler = @Sendable (GogWireRequest, Int) throws -> (Data, GogWireResponse)

    private var handler: Handler
    private(set) var requests: [GogWireRequest] = []
    private(set) var bodies: [[String: Any]] = []

    init(handler: @escaping Handler) { self.handler = handler }

    /// Always answer with this status and body.
    static func fixed(_ status: Int, _ body: String,
                      headers: [String: String] = [:]) -> MockTransport {
        MockTransport { _, _ in
            (Data(body.utf8), GogWireResponse(status: status, headers: headers))
        }
    }

    func perform(_ request: GogWireRequest) async throws -> (Data, GogWireResponse) {
        let attempt = requests.count
        requests.append(request)
        if let body = request.body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            bodies.append(json)
        }
        return try handler(request, attempt)
    }

    var callCount: Int { requests.count }
    var paths: [String] { requests.map { $0.url.path } }
    var authorizations: [String] { requests.compactMap { $0.headers["Authorization"] } }
    func idempotencyKeys() -> [String] { bodies.compactMap { $0["idempotency_key"] as? String } }

    // Sendable accessors — [[String: Any]] cannot cross an actor boundary in Swift 6.
    var urls: [URL] { requests.map { $0.url } }
    var rawBodies: [Data] { requests.compactMap { $0.body } }
    /// Sendable accessor for a query parameter across every recorded request.
    func queryValues(_ name: String) -> [String?] {
        requests.map { req in
            URLComponents(url: req.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == name }?.value
        }
    }
    var bodyCount: Int { bodies.count }
    func stringBody(_ key: String, at index: Int) -> String? {
        guard index < bodies.count else { return nil }
        return bodies[index][key] as? String
    }
    func bodyHasKey(_ key: String, at index: Int) -> Bool {
        guard index < bodies.count else { return false }
        return bodies[index][key] != nil
    }
    func setHandler(_ h: @escaping Handler) { handler = h }
}

/// A session that can be switched, so a test can express an ACCOUNT SWITCH — the thing no
/// single fixed provider could ever express, which is exactly why the mis-crediting bug
/// survived 21 passing tests.
actor SessionBox {
    private var snapshot: GogSessionSnapshot
    private(set) var reads = 0
    init(_ snapshot: GogSessionSnapshot) { self.snapshot = snapshot }
    func current() -> GogSessionSnapshot { reads += 1; return snapshot }
    func readCount() -> Int { reads }
    func signIn(as snapshot: GogSessionSnapshot) { self.snapshot = snapshot }
    nonisolated var provider: GogSessionProvider { { await self.current() } }
}

enum TestSupport {
    static let gameId = UUID(uuidString: "f07ff931-5e22-4414-a399-a85ec3c55b97")!

    static let playerA = GogSessionSnapshot(accessToken: "token-A", userScope: "scope-A")
    static let playerB = GogSessionSnapshot(accessToken: "token-B", userScope: "scope-B")

    static func configuration() -> GogConfiguration {
        GogConfiguration(gameId: gameId, baseURL: URL(string: "https://gog-api.fly.dev")!)
    }

    static func tempLogURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gogtests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending-wallet-ops.json")
    }

    @MainActor
    static func coins(transport: MockTransport,
                      logURL: URL,
                      session: GogSessionSnapshot = TestSupport.playerA) throws -> GogCoins {
        try GogCoins(configuration: configuration(),
                     sessionProvider: { session },
                     transport: transport,
                     idempotencyLog: IdempotencyLog(fileURL: logURL))
    }

    @MainActor
    static func coins(transport: MockTransport,
                      logURL: URL,
                      box: SessionBox) throws -> GogCoins {
        try GogCoins(configuration: configuration(),
                     sessionProvider: box.provider,
                     transport: transport,
                     idempotencyLog: IdempotencyLog(fileURL: logURL))
    }
}
