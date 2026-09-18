import Foundation

/// A launch code captured but not yet exchanged.
///
/// 🔴 **Why this is written down instead of held in a field.** In manual mode
/// (`autoSignInFromLaunch == false`) the SDK captures the code and then waits — for the game
/// to finish loading, show its splash, and call `trySignInFromLaunch()`. That wait is
/// unbounded, and the app is at its most reapable during it: a cold launch under memory
/// pressure, with an asset load in flight, is exactly when iOS jetsams.
///
/// If the code lived only in memory, that reap would lose it. And the launch URL is gone too —
/// it was delivered once, to a process that no longer exists. The player tapped Play in the
/// hub, watched the game start, and arrives signed out with no way back but returning to the
/// hub and tapping again. Android persists it (`PendingHandoff`); so do we.
struct PendingLaunchCode: Codable, Sendable, Equatable {
    let code: String
    let gameId: UUID
    let capturedAt: Date

    /// `GogAuthCore.PENDING_MAX_AGE_SEC = 300L`, matched deliberately.
    ///
    /// This is **storage hygiene, not a validity check**. The server's codes live about 120
    /// seconds, and it would be easy to bound this at 120 and call anything older invalid —
    /// but that puts a copy of the server's TTL in the client, where it will be wrong the
    /// day the server changes it, and wrong in the silent direction: refusing codes that
    /// would have worked. The server decides validity. This bound exists only so an
    /// abandoned record cannot sit in secure storage indefinitely, which is exactly what
    /// Android's comment on the same constant says ("a 300s-old record is dead by
    /// definition, code or no code").
    static let ttl: TimeInterval = 300

    func isExpired(now: Date) -> Bool { now.timeIntervalSince(capturedAt) > Self.ttl }
}

/// Everything about the player that must outlive the process, in ONE stored record.
///
/// 🔴 **One record, because the pair has to move together.** Android's
/// `saveSessionAndClearPending` writes the new session and drops the pending handoff in a
/// single `SharedPreferences.apply()`, so a kill between them is impossible. Two Keychain
/// items cannot give that: a crash after the session write and before the pending removal
/// leaves a spent code that the next launch will offer to the game, which spends a round trip
/// to earn a 401 and a `launchSignInFailed` the player did nothing to deserve. A crash in the
/// other order is worse — the code is gone from the server AND from us, and the session that
/// was paid for is lost.
///
/// Putting both in one value makes the write a single `store.set`, which is the same
/// all-or-nothing the Android store gets for free.
struct StoredIdentity: Codable, Sendable {
    /// Bumped only for a change that older builds could MISREAD. Additive fields do not
    /// qualify — `Codable` ignores what it does not know (I9).
    var version: Int = 1
    var session: StoredSession?
    var pendingLaunchCode: PendingLaunchCode?

    static let empty = StoredIdentity(session: nil, pendingLaunchCode: nil)

    var isEmpty: Bool { session == nil && pendingLaunchCode == nil }

    /// Decode tolerantly.
    ///
    /// The record used to be a bare `StoredSession` under the same key. Nothing has shipped,
    /// so no device can actually be holding one — but a developer with a build from last week
    /// on their phone can, and "your test account silently signed itself out" is a bad hour to
    /// hand someone for no reason.
    static func decode(_ data: Data) -> StoredIdentity? {
        // Every field of the envelope is optional or defaulted, so a bare legacy record
        // decodes as an EMPTY envelope instead of failing. Emptiness is the signal to try the
        // older shape — not a valid result to return.
        if let envelope = try? JSONDecoder().decode(StoredIdentity.self, from: data),
           !envelope.isEmpty {
            return envelope
        }
        if let legacy = try? JSONDecoder().decode(StoredSession.self, from: data) {
            GogLog.warn("session store: upgrading a pre-envelope session record")
            return StoredIdentity(session: legacy, pendingLaunchCode: nil)
        }
        return nil
    }
}
