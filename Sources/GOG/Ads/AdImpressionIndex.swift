import Foundation

/// Where the impression index is kept. Behind a protocol so the counter's behaviour is
/// testable without touching the real defaults database.
protocol ImpressionIndexStore: Sendable {
    func load() -> Int
    func save(_ value: Int)
}

/// `UserDefaults` — **not** the Keychain.
///
/// The index is not a secret, and Android was explicitly corrected away from a secure store
/// here. What is frozen is the PROPERTY — persisted, monotonic, API-invisible — not the store.
struct UserDefaultsImpressionIndexStore: ImpressionIndexStore {
    /// Flat, and deliberately NOT namespaced by game id: there is exactly one game id per
    /// install, and keying by it would let a build-time game-id change rewind the counter,
    /// which is closer to "resettable" than a flat key.
    static let key = "com.gog.sdk.ads.impression_index"

    // `UserDefaults` is thread-safe but not annotated Sendable in corelibs Foundation.
    // It is only ever touched from inside the AdImpressionIndex actor.
    nonisolated(unsafe) let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> Int { defaults.integer(forKey: Self.key) }
    func save(_ value: Int) {
        defaults.set(value, forKey: Self.key)
        // Explicit, rather than left to the automatic flush at background/terminate: an
        // OOM kill gets no such callback, and an unflushed counter is a silently rewound one.
        // One small synchronous write per interstitial is acceptable at that frequency.
        defaults.synchronize()
    }
}

/// The impression index: SDK-internal, per-install, monotonic, persisted.
///
/// **Why it is internal and has no reset.** The server picks a creative from
/// `(game_id, index)`. If a game could restart the counter, every player would see the first
/// creative forever — the exact starvation this mechanism exists to prevent. Nothing in the
/// public surface reads, writes, or clears it.
///
/// **This is one of the three ad rules that fail silently.** A resetting index still looks
/// exactly like "ads work". There is currently only ONE house creative in the whole system,
/// so a broken index is undetectable by testing today — which is precisely the condition
/// under which this rule gets skipped.
actor AdImpressionIndex {
    private let store: any ImpressionIndexStore
    init(store: any ImpressionIndexStore) { self.store = store }

    /// Consume one impression opportunity: return the current value and persist the next.
    ///
    /// **Increments BEFORE the fetch, not after a success.** On success-only increment, a
    /// player on a flaky network — or an app the OS kills mid-fetch — replays the same index
    /// indefinitely and sees one creative forever. Consuming up front means a failed fetch
    /// SKIPS a creative, and a skipped creative is strictly better than a repeated one.
    ///
    /// Called once per *opportunity* — never per render, per transport retry, or per call
    /// rejected by the concurrency guard.
    func next() -> Int {
        let current = store.load()
        // Defensive: a corrupted or externally-written negative value restarts at 0 rather
        // than sending a negative index the server rejects with a 400.
        let safe = current < 0 ? 0 : current
        store.save(safe &+ 1)
        return safe
    }
}
