import Foundation

/// Durable queue of banked slices that have not been accepted yet.
///
/// Same shape and the same reasoning as the wallet write-ahead log: a slice is written down
/// BEFORE the upload is attempted, so a process death between banking and delivery loses
/// nothing. Versioned envelope for the same reason too — a schema change that made the file
/// undecodable would silently discard every pending measurement.
actor PlaytimeQueue {
    private struct File: Codable { let version: Int; let events: [PlaytimeEvent] }
    static let schemaVersion = 1
    /// Bounded so an app that is never online does not grow the file without limit.
    /// `PlaytimeStore.kt: MAX_PENDING = 200` — "~3 hours of play at the one-per-minute
    /// flush cadence". Matched rather than chosen: the two platforms feed the same tables,
    /// so a device offline for a week should truncate its backlog identically on both.
    static let maxPending = 200

    private let fileURL: URL
    init(fileURL: URL) { self.fileURL = fileURL }

    static func defaultFileURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("GOG", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending-playtime.json")
    }

    func append(_ event: PlaytimeEvent) { write(load() + [event]) }
    func pending() -> [PlaytimeEvent] { load() }
    func remove(ids: Set<String>) {
        write(load().filter { !ids.contains($0.eventId) })
    }
    func count() -> Int { load().count }

    private func load() -> [PlaytimeEvent] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            guard file.version == Self.schemaVersion else {
                GogLog.warn("playtime queue: on-disk schema v\(file.version), this build reads "
                            + "v\(Self.schemaVersion) — \(file.events.count) slice(s) discarded")
                return []
            }
            return file.events
        } catch {
            GogLog.warn("playtime queue: \(data.count) byte(s) unreadable (\(error)) — "
                        + "any slices it held are lost")
            return []
        }
    }

    private func write(_ events: [PlaytimeEvent]) {
        var kept = events
        if kept.count > Self.maxPending {
            let dropped = kept.count - Self.maxPending
            GogLog.warn("playtime queue: at capacity (\(Self.maxPending)); dropped \(dropped) "
                        + "oldest undelivered slice(s)")
            kept = Array(kept.suffix(Self.maxPending))
        }
        guard let data = try? JSONEncoder().encode(File(version: Self.schemaVersion, events: kept))
        else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Metered playtime.
///
/// Not part of the frozen public surface — no game calls it. It runs itself off app
/// lifecycle and input, banks a delta about once a minute, and uploads. Internal on Android
/// for the same reason.
///
/// Timing constants are matched to Android so the two platforms produce comparable numbers.
public actor GogPlaytime {

    static let flushIntervalMs: Int64 = 60_000
    /// Foreground/background on iOS flaps during system alerts and control-centre pulls;
    /// a debounce keeps those from being recorded as real session boundaries.
    static let backgroundDebounceMs: Int64 = 700
    /// A gap this long starts a new session id.
    static let sessionGapMs: Int64 = 30 * 60 * 1000

    /// 🔴 The meter's clock. MONOTONIC, and it has to be.
    ///
    /// `PlaytimeMeter.kt` is unusually direct about this: *"the caller supplies it from a
    /// MONOTONIC source (SystemClock.elapsedRealtime on device, a fake in tests). **Wall-clock
    /// time must never reach here; an NTP correction mid-session would otherwise invent or
    /// erase minutes of play.**"* Every Android call site uses `elapsedRealtime()`.
    ///
    /// The first cut of this port defaulted to `Date().timeIntervalSince1970` — precisely the
    /// wall clock that comment forbids — so a routine NTP step would have silently added or
    /// removed play time from the same engagement tables Android feeds. Nothing would have
    /// errored; the numbers would just have been wrong.
    ///
    /// `systemUptime` is the same monotonic source the ad TTL and `ForegroundTimeline` already
    /// use, so the whole SDK now measures durations one way. Wall-clock timestamps still come
    /// from `isoNow` — `occurred_at` is an instant, not a duration, and wants the real date.
    ///
    /// Nothing persists across launches (`lastForegroundMs`, `lastBankMs` and `sessionId` are
    /// in-memory), so this clock resetting at reboot costs nothing.
    static let defaultClockMs: @Sendable () -> Int64 = {
        Int64(ProcessInfo.processInfo.systemUptime * 1000)
    }

    private var meter = PlaytimeMeter()
    private let queue: PlaytimeQueue
    private let uploader: PlaytimeUploader
    /// 🔴 MONOTONIC milliseconds. `nonisolated` so `PlaytimeAutoHook` reads its input
    /// timestamps from THIS clock and not one of its own — see `defaultClockMs`.
    nonisolated let clockMs: @Sendable () -> Int64
    private let isoNow: @Sendable () -> String
    private let newId: @Sendable () -> String

    private let gameId: String
    private let deviceId: String
    private let appVersion: String?
    private let sdkVersion: String
    private let context: PlaytimeEvent.Context

    private var sessionId: String
    private var lastForegroundMs: Int64 = 0
    private var lastBankMs: Int64 = 0

    init(gameId: UUID, deviceId: String, appVersion: String?,
         queue: PlaytimeQueue, uploader: PlaytimeUploader,
         context: PlaytimeEvent.Context = .current(),
         clockMs: @escaping @Sendable () -> Int64 = GogPlaytime.defaultClockMs,
         isoNow: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) },
         newId: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.gameId = gameId.uuidString.lowercased()
        self.deviceId = deviceId
        self.appVersion = appVersion
        self.sdkVersion = GogSDKVersion.value
        self.queue = queue
        self.uploader = uploader
        self.context = context
        self.clockMs = clockMs
        self.isoNow = isoNow
        self.newId = newId
        self.sessionId = newId()
    }

    // MARK: - Lifecycle, driven by the host

    public func onForeground() async {
        let now = clockMs()
        // A long gap since the last foreground is a new play session, not a continuation.
        if lastForegroundMs != 0, now - lastForegroundMs >= Self.sessionGapMs {
            sessionId = newId()
        }
        lastForegroundMs = now
        meter.onForeground(now)
        if lastBankMs == 0 { lastBankMs = now }
        await drainQueue()
    }

    public func onBackground() async {
        meter.onBackground(clockMs())
        // Bank on the way out: a backgrounded app may never be resumed.
        await bank()
        await drainQueue()
    }

    public func onInput() { meter.onTouch(clockMs()) }

    /// A coalesced burst of input events, with the timestamp of the LAST one.
    ///
    /// See `PlaytimeAutoHook`: Android's `TouchTapCallback` ticks the meter once per dispatched
    /// event on the same thread the meter lives on, which is free. Here the meter is behind an
    /// actor, so one hop per event at 120Hz is not — the hook batches instead, and hands the
    /// exact count across.
    public func onInput(count: Int64, atMs: Int64) { meter.onTouch(atMs, count: count) }

    /// Call about once a second from the host's display link or timer; cheap and idempotent.
    public func tick() async {
        let now = clockMs()
        meter.onTick(now)
        if now - lastBankMs >= Self.flushIntervalMs {
            await bank()
            await drainQueue()
        }
    }

    // MARK: - Banking and delivery

    private func bank() async {
        let now = clockMs()
        lastBankMs = now
        guard let delta = meter.drain(now) else { return }
        guard delta.isWithinServerBounds else {
            // Sending it would earn a 4xx, which the uploader treats as delivered — i.e. the
            // measurement would vanish. Say so instead.
            GogLog.warn("playtime: a slice exceeded the server's bounds "
                        + "(active \(delta.activeMs)ms, idle \(delta.idleMs)ms) and was dropped")
            return
        }
        let event = PlaytimeEvent(
            eventId: newId(), eventName: PlaytimeEvent.name,
            schemaVersion: 1, envelopeVersion: 1,
            occurredAt: isoNow(), deviceId: deviceId, sessionId: sessionId,
            profileId: nil, gameId: gameId, platform: "ios",
            appVersion: appVersion, sdkVersion: sdkVersion,
            payload: .init(activeMs: delta.activeMs, idleMs: delta.idleMs,
                           touches: delta.touches, idleTimeoutMs: PlaytimeMeter.idleTimeoutMs),
            context: context)
        // Persist BEFORE attempting delivery.
        await queue.append(event)
    }

    private func drainQueue() async {
        let pending = await queue.pending()
        guard !pending.isEmpty else { return }
        for batch in PlaytimeUploader.chunk(pending) {
            let outcome = await uploader.send(batch, sentAt: isoNow())
            guard outcome == .delivered else { return }   // stop on the first retryable failure
            await queue.remove(ids: Set(batch.map(\.eventId)))
        }
    }

    /// Diagnostics.
    public func pendingSliceCount() async -> Int { await queue.count() }
}

extension PlaytimeEvent.Context {
    static func current() -> PlaytimeEvent.Context {
        PlaytimeEvent.Context(os: "ios",
                              osRelease: osRelease(),
                              deviceBrand: "Apple",
                              deviceModel: DeviceModel.identifier())
    }

    /// 🔴 Deliberately NOT `UIDevice.current.systemVersion`.
    ///
    /// Apple declares `@MainActor class UIDevice`, and this runs from the playtime actor —
    /// so reading it here is a hard Swift 6 error: *"main actor-isolated class property
    /// 'current' can not be referenced from a nonisolated context"*. The first cut did exactly
    /// that, inside a `#if canImport(UIKit)` block that no compiler on this machine ever saw.
    ///
    /// `ProcessInfo.operatingSystemVersion` is nonisolated, needs no hop, and returns the same
    /// numbers `systemVersion` does — so this is not a workaround, it is the better call. It
    /// also deletes the `#if`, which means one code path instead of two and no second version
    /// that only compiles on CI.
    private static func osRelease() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0
            ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

/// The hardware identifier, read straight from `uname`.
///
/// Deliberately NOT behind `#if canImport(UIKit)`, though it was: nothing in here is UIKit —
/// `utsname` and `uname` are POSIX and work everywhere. The guard bought a second code path
/// that reported `deviceModel: "unknown"` off-device and was never exercised by a single test.
/// One path is now compiled and tested on every platform.
enum DeviceModel {
    /// The hardware identifier ("iPhone16,2"), not the marketing name — `UIDevice.model`
    /// only ever returns "iPhone", which is useless for the dashboards Android populates
    /// with `Build.MODEL`.
    static func identifier() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }
}
