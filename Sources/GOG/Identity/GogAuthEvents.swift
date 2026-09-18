import Foundation

/// A session, as the game sees it.
public struct GogSession: Sendable, Equatable {
    public let isSignedIn: Bool
    public let user: GogUser?
    static let signedOut = GogSession(isSignedIn: false, user: nil)
}

public enum GogSignOutReason: Sendable, Equatable {
    case userRequested
    case sessionExpired
}

/// News about the session.
///
/// **I1 — state is truth, events are news, never replays.** A subscriber that starts late
/// does NOT receive a replayed `signedIn`; it reads `currentSession` instead. This cost real
/// debugging time on Android: coins calls succeeded while the "signed in as…" label never
/// appeared, because the code gated on the event rather than the state. On iOS, check
/// `currentSession` on launch and use these only for changes.
public enum GogAuthEvent: Sendable, Equatable {
    /// A launch link was accepted and the exchange is about to run. Lets a game put up a
    /// spinner before the round trip, which is the whole reason Android raises it.
    case signInStarted
    case signedIn(GogUser)
    case signedOut(GogSignOutReason)
    /// Launch sign-in has no explicit caller, so its failure has nowhere to return to.
    case launchSignInFailed(GogError)
}

/// Fans one event out to every live subscriber. `AsyncStream` is single-consumer, so a
/// multicast is needed for the several places a game may listen from.
actor AuthEventHub {
    private var continuations: [UUID: AsyncStream<GogAuthEvent>.Continuation] = [:]

    func stream() -> AsyncStream<GogAuthEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(id) }
            }
        }
    }

    private func remove(_ id: UUID) { continuations[id] = nil }

    func emit(_ event: GogAuthEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    func finishAll() {
        for continuation in continuations.values { continuation.finish() }
        continuations.removeAll()
    }
}
