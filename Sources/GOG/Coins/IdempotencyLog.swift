import Foundation

/// A durable write-ahead log of wallet operations whose outcome is not yet known.
///
/// WHY THIS EXISTS. On Android the idempotency key is minted per call and persisted
/// nowhere, so a process death mid-request forgets the attempt — failure mode "lost win".
/// Worse, the convenience overload mints a FRESH key each call, so a game that implements
/// retry-after-restart with it double-credits, and no server-side control can catch that.
///
/// THE RULE THIS TYPE ENCODES: because a stable idempotency key makes a replay free, the
/// log resolves an entry ONLY on an outcome it is certain about, and keeps everything else.
/// Erring toward keeping costs at most one redundant request. Erring toward resolving
/// loses a player's coins permanently. The asymmetry is not close, so the bias is deliberate.
///
/// Storage is a JSON file in Application Support — NOT UserDefaults (this is durable
/// transactional state, not a preference) and NOT the Keychain (it is not a secret). It is
/// deliberately left eligible for iCloud backup: a restored backup replaying a stable key
/// is harmless by construction, which is the whole point of the key.
actor IdempotencyLog {

    /// Bounds. A cap that drops entries silently would read as "everything reconciled" when
    /// it did not, so every eviction is logged with what was dropped.
    static let maxEntries = 64
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL) {
        self.fileURL = fileURL
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Default location: <Application Support>/GOG/pending-wallet-ops.json
    static func defaultFileURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil,
                                       create: true)
        let dir = base.appendingPathComponent("GOG", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending-wallet-ops.json")
    }

    // MARK: - API

    /// Persist BEFORE the request goes out. If this throws, the caller proceeds anyway:
    /// an unrecorded op degrades to Android's behaviour (a possible lost win), which is
    /// strictly better than refusing to let the player earn at all.
    func record(_ op: PendingWalletOp, now: Date = Date()) throws {
        var ops = (try? load()) ?? []
        ops.removeAll { $0.opId == op.opId }
        ops.append(op)
        ops = prune(ops, now: now)
        try save(ops)
    }

    /// Remove an entry whose outcome is now certain.
    func resolve(_ opId: UUID) throws {
        var ops = (try? load()) ?? []
        let before = ops.count
        ops.removeAll { $0.opId == opId }
        guard ops.count != before else { return }
        try save(ops)
    }

    func pending(now: Date = Date()) throws -> [PendingWalletOp] {
        let ops = (try? load()) ?? []
        return prune(ops, now: now).sorted { $0.createdAt < $1.createdAt }
    }

    func count() throws -> Int { ((try? load()) ?? []).count }

    // MARK: - Internals

    private func prune(_ ops: [PendingWalletOp], now: Date) -> [PendingWalletOp] {
        var kept = ops.sorted { $0.createdAt < $1.createdAt }

        let expired = kept.filter { now.timeIntervalSince($0.createdAt) > Self.maxAge }
        if !expired.isEmpty {
            kept.removeAll { op in expired.contains(where: { $0.opId == op.opId }) }
            GogLog.warn(
                "idempotency log: dropped \(expired.count) operation(s) older than "
                + "\(Int(Self.maxAge / 86_400)) days without a known outcome — "
                + "\(expired.map { "\($0.kind.rawValue) \($0.amount)" }.joined(separator: ", "))"
            )
        }

        if kept.count > Self.maxEntries {
            let overflow = kept.prefix(kept.count - Self.maxEntries)
            GogLog.warn(
                "idempotency log: at capacity (\(Self.maxEntries)); dropped "
                + "\(overflow.count) oldest unresolved operation(s) — "
                + "\(overflow.map { "\($0.kind.rawValue) \($0.amount)" }.joined(separator: ", "))"
            )
            kept = Array(kept.suffix(Self.maxEntries))
        }
        return kept
    }

    /// The on-disk envelope.
    ///
    /// The version field exists because the alternative bit us once already: when
    /// `userScope` was added to `PendingWalletOp`, a bare `[PendingWalletOp]` file written
    /// by the previous build would fail to decode, `load()` would throw, the `try?` at every
    /// call site would swallow it, and EVERY pending operation would vanish with no error
    /// anywhere. A schema change must be loud, not lossy.
    private struct LogFile: Codable {
        let version: Int
        let ops: [PendingWalletOp]
    }

    static let schemaVersion = 1

    private func load() throws -> [PendingWalletOp] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }

        do {
            let file = try decoder.decode(LogFile.self, from: data)
            guard file.version == Self.schemaVersion else {
                GogLog.warn(
                    "idempotency log: on-disk schema is v\(file.version) but this build reads "
                    + "v\(Self.schemaVersion). \(file.ops.count) operation(s) will NOT be "
                    + "reconciled. This is a lost-credit condition, not a cosmetic one."
                )
                return []
            }
            return file.ops
        } catch {
            // Never silently return an empty log. An unreadable log means real pending
            // credits are being abandoned, and the only place that can be observed is here.
            GogLog.warn(
                "idempotency log: \(data.count) byte(s) at \(fileURL.lastPathComponent) could "
                + "not be read (\(error)). Any operations it held will NOT be reconciled."
            )
            return []
        }
    }

    private func save(_ ops: [PendingWalletOp]) throws {
        let data = try encoder.encode(LogFile(version: Self.schemaVersion, ops: ops))
        // .atomic so a crash mid-write cannot leave a truncated log — which would lose
        // every pending operation, not just the one being written.
        try data.write(to: fileURL, options: .atomic)
    }
}
