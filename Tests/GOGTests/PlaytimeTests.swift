import XCTest
@testable import GOG

/// The meter is a direct port of Android's, so these tests are about the ARITHMETIC —
/// particularly the active/idle cutover, which is the part that would silently produce
/// numbers that look plausible and disagree with Android.
final class PlaytimeMeterTests: XCTestCase {

    private let idle = PlaytimeMeter.idleTimeoutMs   // 40_000

    func testNothingAccruesWhileBackgrounded() {
        var meter = PlaytimeMeter()
        meter.onTick(10_000)
        meter.onTouch(11_000)
        XCTAssertNil(meter.drain(20_000))
        XCTAssertFalse(meter.isForeground)
    }

    func testForegroundTimeBeforeTheCutoverIsAllActive() {
        var meter = PlaytimeMeter()
        meter.onForeground(0)
        let delta = meter.drain(10_000)
        XCTAssertEqual(delta?.activeMs, 10_000)
        XCTAssertEqual(delta?.idleMs, 0)
    }

    /// The cutover: time up to `lastTouch + idleTimeout` is active, everything after is idle,
    /// and a single settle spanning the boundary must split rather than pick one.
    func testASegmentSpanningTheCutoverIsSplit() {
        var meter = PlaytimeMeter()
        meter.onForeground(0)
        let delta = meter.drain(idle + 15_000)
        XCTAssertEqual(delta?.activeMs, idle, "up to the cutover")
        XCTAssertEqual(delta?.idleMs, 15_000, "and after it")
        XCTAssertTrue(meter.isIdle)
    }

    func testATouchEndsIdleAndRestartsTheClock() {
        var meter = PlaytimeMeter()
        meter.onForeground(0)
        meter.onTick(idle + 5_000)          // now idle
        XCTAssertTrue(meter.isIdle)

        meter.onTouch(idle + 5_000)
        XCTAssertFalse(meter.isIdle)

        let delta = meter.drain(idle + 5_000 + 1_000)
        XCTAssertEqual(delta?.activeMs, idle + 1_000)
        XCTAssertEqual(delta?.idleMs, 5_000)
        XCTAssertEqual(delta?.touches, 1)
    }

    func testTouchesAreCountedOnlyInForeground() {
        var meter = PlaytimeMeter()
        meter.onTouch(1_000)                 // ignored — backgrounded
        meter.onForeground(2_000)
        meter.onTouch(3_000)
        meter.onTouch(4_000)
        XCTAssertEqual(meter.drain(5_000)?.touches, 2)
    }

    func testBackgroundingSettlesAndStopsAccrual() {
        var meter = PlaytimeMeter()
        meter.onForeground(0)
        meter.onBackground(5_000)
        let delta = meter.drain(60_000)      // long after
        XCTAssertEqual(delta?.activeMs, 5_000, "time while backgrounded must not accrue")
    }

    func testDrainResetsSoSlicesAreDeltasNotTotals() {
        var meter = PlaytimeMeter()
        meter.onForeground(0)
        XCTAssertEqual(meter.drain(1_000)?.activeMs, 1_000)
        XCTAssertEqual(meter.drain(2_000)?.activeMs, 1_000, "the second slice is a DELTA")
    }

    func testDrainReturnsNilWhenNothingAccrued() {
        var meter = PlaytimeMeter()
        meter.onForeground(0)
        _ = meter.drain(1_000)
        XCTAssertNil(meter.drain(1_000), "an empty delta is not worth an event")
    }

    /// A device clock that jumps backwards must not accrue negative time — which would
    /// produce a negative `active_ms` and be dropped by the server's deny-by-default
    /// validation, i.e. silently lost.
    func testClockGoingBackwardsRebasesRatherThanAccruingNegativeTime() {
        var meter = PlaytimeMeter()
        meter.onForeground(10_000)
        meter.onTick(5_000)                  // backwards
        let delta = meter.drain(6_000)
        XCTAssertEqual(delta?.activeMs, 1_000)
        XCTAssertGreaterThanOrEqual(delta?.activeMs ?? -1, 0)
    }

    func testMsUntilIdleDrivesTheWatchdog() {
        var meter = PlaytimeMeter()
        XCTAssertEqual(meter.msUntilIdle(0), -1, "not foregrounded")
        meter.onForeground(0)
        XCTAssertEqual(meter.msUntilIdle(0), idle)
        XCTAssertEqual(meter.msUntilIdle(idle - 1_000), 1_000)
        XCTAssertEqual(meter.msUntilIdle(idle + 1), 0, "never negative")
        meter.onTick(idle + 1)
        XCTAssertEqual(meter.msUntilIdle(idle + 1), -1, "already idle")
    }

    // ─── the server's bounds ─────────────────────────────────────────────────
    func testDeltaKnowsTheServersBounds() {
        XCTAssertTrue(PlaytimeDelta(activeMs: 60_000, idleMs: 0, touches: 4).isWithinServerBounds)
        XCTAssertFalse(PlaytimeDelta(activeMs: PlaytimeDelta.maxSliceMs + 1, idleMs: 0, touches: 0)
            .isWithinServerBounds, "the server drops it with a 4xx, which the uploader treats as delivered")
        XCTAssertFalse(PlaytimeDelta(activeMs: -1, idleMs: 0, touches: 0).isWithinServerBounds)
    }

    func testIdleTimeoutMatchesAndroid() {
        XCTAssertEqual(PlaytimeMeter.idleTimeoutMs, 40_000,
                       "the two platforms must produce comparable numbers")
    }
}

/// Banking, persistence and delivery.
final class PlaytimeCoordinatorTests: XCTestCase {

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var ms: Int64 = 1_700_000_000_000
        var now: @Sendable () -> Int64 { { [self] in lock.lock(); defer { lock.unlock() }; return ms } }
        func advance(_ delta: Int64) { lock.lock(); ms += delta; lock.unlock() }
    }

    private func make(_ transport: MockTransport, clock: Clock, queueURL: URL)
        -> GogPlaytime {
        GogPlaytime(gameId: TestSupport.gameId, deviceId: "device-1", appVersion: "1.2.3",
                    queue: PlaytimeQueue(fileURL: queueURL),
                    uploader: PlaytimeUploader(baseURL: TestSupport.configuration().baseURL,
                                               transport: transport),
                    clockMs: clock.now,
                    isoNow: { "2026-08-27T10:00:00Z" })
    }

    private func queueURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gogplay-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending-playtime.json")
    }

    func testASliceIsBankedAndUploadedAfterTheFlushInterval() async throws {
        let clock = Clock()
        let t = MockTransport.fixed(202, "{}")
        let playtime = make(t, clock: clock, queueURL: queueURL())

        await playtime.onForeground()
        clock.advance(GogPlaytime.flushIntervalMs)
        await playtime.tick()

        let calls = await t.callCount
        XCTAssertEqual(calls, 1)
        let pending = await playtime.pendingSliceCount()
        XCTAssertEqual(pending, 0, "delivered slices leave the queue")
    }

    func testTheEnvelopeMatchesWhatTheServerIngests() async throws {
        let clock = Clock()
        let t = MockTransport.fixed(202, "{}")
        let playtime = make(t, clock: clock, queueURL: queueURL())

        await playtime.onForeground()
        clock.advance(GogPlaytime.flushIntervalMs)
        await playtime.tick()

        let bodies = await t.rawBodies
        let body = try XCTUnwrap(bodies.first)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(json["sent_at"])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event["event_name"] as? String, "engagement.playtime")
        XCTAssertEqual(event["platform"] as? String, "ios")
        XCTAssertEqual(event["schema_version"] as? Int, 1)
        XCTAssertEqual(event["envelope_version"] as? Int, 1)
        XCTAssertEqual(event["game_id"] as? String, TestSupport.gameId.uuidString.lowercased())
        XCTAssertEqual(event["sdk_version"] as? String, GogSDKVersion.value)
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        // 60s of foreground with no input is NOT 60s of active play: the meter cuts over to
        // idle 40s after the last touch. Asserting the split end-to-end is what proves the
        // cutover survives the coordinator, not just the meter's own unit tests.
        XCTAssertEqual(payload["active_ms"] as? Int, 40_000)
        XCTAssertEqual(payload["idle_ms"] as? Int, 20_000)
        XCTAssertEqual(payload["touches"] as? Int, 0)
        XCTAssertEqual(payload["idle_timeout_ms"] as? Int, 40_000)
    }

    /// Persisted BEFORE delivery: a 5xx must leave the slice in the queue, not lose it.
    func testATransientUploadFailureKeepsTheSlice() async throws {
        let clock = Clock()
        let t = MockTransport.fixed(500, #"{"error":"internal error"}"#)
        let playtime = make(t, clock: clock, queueURL: queueURL())

        await playtime.onForeground()
        clock.advance(GogPlaytime.flushIntervalMs)
        await playtime.tick()

        let pending = await playtime.pendingSliceCount()
        XCTAssertEqual(pending, 1, "a 5xx is retryable; the measurement must survive")
    }

    /// A 4xx is permanent — the server validates deny-by-default, so retrying forever would
    /// be a queue that never drains.
    func testAPermanentRejectionDropsTheSlice() async throws {
        let clock = Clock()
        let t = MockTransport.fixed(400, #"{"error":"invalid input"}"#)
        let playtime = make(t, clock: clock, queueURL: queueURL())

        await playtime.onForeground()
        clock.advance(GogPlaytime.flushIntervalMs)
        await playtime.tick()

        let pending = await playtime.pendingSliceCount()
        XCTAssertEqual(pending, 0, "a rejected slice must not become a permanent retry loop")
    }

    func testTheQueueSurvivesAcrossInstances() async throws {
        let url = queueURL()
        let clock = Clock()
        let failing = MockTransport.fixed(500, "{}")
        let first = make(failing, clock: clock, queueURL: url)
        await first.onForeground()
        clock.advance(GogPlaytime.flushIntervalMs)
        await first.tick()
        let stranded = await first.pendingSliceCount()
        XCTAssertEqual(stranded, 1)

        // New process, same file, network back.
        let ok = MockTransport.fixed(202, "{}")
        let second = make(ok, clock: clock, queueURL: url)
        await second.onForeground()
        let recovered = await second.pendingSliceCount()
        XCTAssertEqual(recovered, 0, "the stranded slice is delivered on the next foreground")
        let calls = await ok.callCount
        XCTAssertEqual(calls, 1)
    }

    func testBackgroundingBanksImmediately() async throws {
        let clock = Clock()
        let t = MockTransport.fixed(202, "{}")
        let playtime = make(t, clock: clock, queueURL: queueURL())

        await playtime.onForeground()
        clock.advance(5_000)                 // well under the flush interval
        await playtime.onBackground()

        let calls = await t.callCount
        XCTAssertEqual(calls, 1, "a backgrounded app may never be resumed")
    }

    /// A slice the server would reject with a 4xx is a measurement silently lost, so it is
    /// better not to send one.
    func testAnOutOfBoundsSliceIsDroppedBeforeSending() async throws {
        let clock = Clock()
        let t = MockTransport.fixed(202, "{}")
        let playtime = make(t, clock: clock, queueURL: queueURL())

        await playtime.onForeground()
        clock.advance(PlaytimeDelta.maxSliceMs * 3)   // a device dozing for hours
        await playtime.tick()

        let calls = await t.callCount
        XCTAssertEqual(calls, 0, "the server's own bound is applied here first")
    }

    func testALongGapStartsANewSession() async throws {
        let clock = Clock()
        let t = MockTransport.fixed(202, "{}")
        let playtime = make(t, clock: clock, queueURL: queueURL())

        await playtime.onForeground()
        clock.advance(GogPlaytime.flushIntervalMs)
        await playtime.tick()
        await playtime.onBackground()

        clock.advance(GogPlaytime.sessionGapMs + 1)
        await playtime.onForeground()
        clock.advance(GogPlaytime.flushIntervalMs)
        await playtime.tick()

        let bodies = await t.rawBodies
        let sessionIds: [String] = bodies.compactMap { body in
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let events = json["events"] as? [[String: Any]],
                  let first = events.first else { return nil }
            return first["session_id"] as? String
        }
        XCTAssertEqual(sessionIds.count, 2)
        XCTAssertNotEqual(sessionIds[0], sessionIds[1], "a 30-minute gap is a new play session")
    }

    func testBatchesAreChunkedToTheServersLimit() {
        let event = PlaytimeEvent(
            eventId: "e", eventName: PlaytimeEvent.name, schemaVersion: 1, envelopeVersion: 1,
            occurredAt: "t", deviceId: "d", sessionId: "s", profileId: nil,
            gameId: "g", platform: "ios", appVersion: nil, sdkVersion: "0",
            payload: .init(activeMs: 1, idleMs: 0, touches: 0, idleTimeoutMs: 40_000),
            context: .init(os: "ios", osRelease: "1", deviceBrand: "Apple", deviceModel: "x"))
        let chunks = PlaytimeUploader.chunk(Array(repeating: event, count: 250))
        XCTAssertEqual(chunks.map(\.count), [100, 100, 50])
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// The scheduling-jitter invariant
//
// PlaytimeMeter.kt states it as a design requirement, not an observation:
//   "the active segment is credited up to `lastTouch + IDLE_TIMEOUT_MS` and idle accrues from
//    that instant onward — NOT from whenever the watchdog happened to fire. A late timer
//    (doze, a busy main thread) therefore cannot inflate active time; the numbers depend only
//    on the touch timestamps, not on scheduling jitter."
//
// It matters more on iOS than on Android: Android schedules a precise watchdog at the cutover
// via `msUntilIdle`, while this port ticks on a 1s timer and can be late by a whole second, or
// by much more under a busy main thread. If the split depended on tick timing at all, the two
// platforms would disagree in the SAME engagement table — and disagree by amounts that look
// like real player behaviour rather than like a bug.
// ─────────────────────────────────────────────────────────────────────────────
final class PlaytimeJitterInvarianceTests: XCTestCase {

    /// Runs one touch script, settling on whatever tick schedule is given, and returns the split.
    ///
    /// Events carry their KIND rather than being dispatched on whether their timestamp appears
    /// in the touch list — the first cut did the latter, so any tick that happened to land on a
    /// touch's millisecond became a second touch and the counts diverged. The meter was fine;
    /// the harness was not.
    private func split(touchesAt touches: [Int64],
                       ticksAt ticks: [Int64],
                       until end: Int64) -> (active: Int64, idle: Int64, touches: Int64) {
        enum Event { case touch, tick }
        var meter = PlaytimeMeter()
        meter.onForeground(0)
        let script = touches.map { ($0, Event.touch) } + ticks.map { ($0, Event.tick) }
        for (at, kind) in script.sorted(by: { $0.0 < $1.0 }) {
            switch kind {
            case .touch: meter.onTouch(at)
            case .tick:  meter.onTick(at)
            }
        }
        let d = meter.drain(end)!
        return (d.activeMs, d.idleMs, d.touches)
    }

    /// 🔴 The invariant: same touches, same end, wildly different tick schedules — same numbers.
    func testTheSplitDoesNotDependOnWhenTheWatchdogFires() {
        let touches: [Int64] = [1_000, 5_000, 5_500, 90_000]
        let end: Int64 = 300_000

        let never       = split(touchesAt: touches, ticksAt: [], until: end)
        let onceLate    = split(touchesAt: touches, ticksAt: [299_999], until: end)
        let everySecond = split(touchesAt: touches, ticksAt: Array(stride(from: 1_000, to: end, by: 1_000)), until: end)
        let ragged      = split(touchesAt: touches, ticksAt: [3, 44_999, 45_001, 130_000, 130_001, 299_998], until: end)
        let dense       = split(touchesAt: touches, ticksAt: Array(stride(from: 1, to: end, by: 37)), until: end)

        XCTAssertEqual(never.active, onceLate.active,    "a late watchdog must not change active time")
        XCTAssertEqual(never.active, everySecond.active, "nor a punctual one")
        XCTAssertEqual(never.active, ragged.active,      "nor an erratic one")
        XCTAssertEqual(never.active, dense.active,       "nor a very frequent one")
        for s in [onceLate, everySecond, ragged, dense] {
            XCTAssertEqual(never.idle, s.idle, "idle must be identical too")
            XCTAssertEqual(never.touches, s.touches)
        }
        // And the numbers are the right ones. Worked through rather than guessed — the first
        // version of this assertion said 130_000/170_000, which silently assumed the meter was
        // active from 0 all the way to the last cutover. It is not; there is a long idle gap in
        // the middle of this script:
        //
        //        0 →  45_500  ACTIVE   (touch at 5_500, + 40_000 cutover)
        //   45_500 →  90_000  IDLE     ( 44_500 — the gap before the next touch)
        //   90_000 → 130_000  ACTIVE   (touch at 90_000, + 40_000 cutover)
        //  130_000 → 300_000  IDLE     (170_000 — nothing more happens)
        //
        XCTAssertEqual(never.active, 45_500 + 40_000)
        XCTAssertEqual(never.idle,   44_500 + 170_000)
        XCTAssertEqual(never.active + never.idle, end, "time is conserved")
        XCTAssertEqual(never.touches, 4)
    }

    /// The same invariant over randomised schedules — a property, not three hand-picked cases.
    func testTheSplitIsScheduleIndependentOverRandomSchedules() {
        var rng = SystemRandomNumberGenerator()
        for trial in 0..<200 {
            let end: Int64 = 200_000
            let touches = (0..<Int.random(in: 1...6, using: &rng))
                .map { _ in Int64.random(in: 1...(end - 1), using: &rng) }.sorted()
            let baseline = split(touchesAt: touches, ticksAt: [], until: end)
            let ticks = (0..<Int.random(in: 0...40, using: &rng))
                .map { _ in Int64.random(in: 1...(end - 1), using: &rng) }
                .filter { !touches.contains($0) }.sorted()
            let jittered = split(touchesAt: touches, ticksAt: ticks, until: end)

            XCTAssertEqual(baseline.active, jittered.active,
                           "trial \(trial): touches \(touches) ticks \(ticks)")
            XCTAssertEqual(baseline.idle, jittered.idle, "trial \(trial)")
            XCTAssertEqual(baseline.active + baseline.idle, end, "trial \(trial): time must be conserved")
        }
    }
}
