// Tests/PixelClockKitTests/UlanziInterruptionTests.swift
import Foundation
import Testing
@testable import PixelClockKit

/// A one-frame scene told apart on the wire by its frame duration — the one
/// field of the upsert body that is a plain number, so a push reads back as
/// the letter it stands for without decoding pixels.
private func scene(_ tag: Int) -> UlanziScene {
    var canvas = PixelCanvas()
    canvas.fill(.white)
    return UlanziScene(frames: [UlanziFrame(duration: tag, draw: [canvas.drawCommands()])])
}

private let weatherTag = 11, zaiTag = 12, githubTag = 13
private let celebrationTag = 21, starsTag = 22, forkTag = 23
/// `UlanziScene.idle`'s own frame duration.
private let idleTag = 5

private let labels: [Int: String] = [
    weatherTag: "W", zaiTag: "Z", githubTag: "G",
    celebrationTag: "C", starsTag: "S", forkTag: "F", idleTag: "idle",
]

/// Stands in for the session's sleep. Records every duration asked for, and
/// either returns at once or parks until the test lets the next one go —
/// which is how a test holds an interruption window open and looks inside it.
///
/// Lock-guarded: the session's player task calls in from a task the test does
/// not own, and the test reads the log with no `await` ordering the two.
private final class ScriptedSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [TimeInterval] = []
    private var parked: [CheckedContinuation<Void, Never>] = []
    private let holds: Bool

    init(holds: Bool) { self.holds = holds }

    var durations: [TimeInterval] { lock.withLock { asked } }
    var parkedCount: Int { lock.withLock { parked.count } }

    func sleep(_ duration: TimeInterval) async {
        lock.withLock { asked.append(duration) }
        guard holds else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock { parked.append(continuation) }
        }
    }

    /// Wakes the oldest parked sleeper.
    func releaseNext() {
        let next = lock.withLock { parked.isEmpty ? nil : parked.removeFirst() }
        next?.resume()
    }
}

private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(waitBudget(nil))
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

@Suite struct UlanziInterruptionTests {
    let recorder = RecordingTransport()
    let record = MemoryAppRecord()

    init() {
        recorder.body = Data(#"{"code":200,"message":"ok"}"#.utf8)
    }

    fileprivate func makeSession(sleep: ScriptedSleep) -> UlanziClockSession {
        let device = UlanziDevice(host: "192.168.1.72", transport: recorder)
        return UlanziClockSession(
            device: device,
            custody: UlanziCustody(device: device, record: record, clockId: "clock-1"),
            sleep: { await sleep.sleep($0) }
        )
    }

    /// Every upsert so far as "page=letter", in wire order. Deletes (empty
    /// bodies) and GETs are left out.
    var pushes: [String] {
        recorder.requests.compactMap { request -> String? in
            guard request.httpMethod == "POST",
                  let query = request.url?.query, query.hasPrefix("name="),
                  let body = request.httpBody, !body.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let duration = json["duration"] as? Int
            else { return nil }
            return "\(query.dropFirst("name=".count))=\(labels[duration] ?? "?\(duration)")"
        }
    }

    /// weather showing W, zai showing Z, github showing G — the recorder
    /// forgotten afterwards, so a test reads only what its own step pushed.
    func boardOfThree(_ session: UlanziClockSession) async -> Int {
        _ = await session.deliver(UlanziDelivery(scene: scene(weatherTag)), toTile: "weather")
        _ = await session.deliver(UlanziDelivery(scene: scene(zaiTag)), toTile: "zai")
        _ = await session.deliver(UlanziDelivery(scene: scene(githubTag)), toTile: "github")
        return pushes.count
    }

    func github(with interruptions: [Interruption<UlanziScene>]) -> UlanziDelivery {
        UlanziDelivery(scene: scene(githubTag), interruptions: interruptions)
    }

    func pushes(after skipped: Int) -> [String] { Array(pushes.dropFirst(skipped)) }

    @Test func everyPageIsOverwrittenThenRestoredFromTheBoard() async throws {
        let sleep = ScriptedSleep(holds: false)
        let session = makeSession(sleep: sleep)
        let before = await boardOfThree(session)

        _ = await session.deliver(
            github(with: [Interruption(scene: scene(celebrationTag), scope: .everyPage, duration: 8)]),
            toTile: "github"
        )

        let expected = [
            "pct-github=G",
            "pct-weather=C", "pct-zai=C", "pct-github=C",
            "pct-weather=W", "pct-zai=Z", "pct-github=G",
        ]
        try await waitUntil { pushes(after: before).count >= expected.count }
        #expect(pushes(after: before) == expected)
        #expect(sleep.durations == [8])
    }

    @Test func ownPageTouchesOnlyItsTile() async throws {
        let sleep = ScriptedSleep(holds: false)
        let session = makeSession(sleep: sleep)
        let before = await boardOfThree(session)

        _ = await session.deliver(
            github(with: [Interruption(scene: scene(celebrationTag), scope: .ownPage, duration: 5)]),
            toTile: "github"
        )

        let expected = ["pct-github=G", "pct-github=C", "pct-github=G"]
        try await waitUntil { pushes(after: before).count >= expected.count }
        // A beat longer, so a stray push to another page has the time to show.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(pushes(after: before) == expected)
    }

    @Test func anIdlePageReturnsIdle() async throws {
        let sleep = ScriptedSleep(holds: false)
        let session = makeSession(sleep: sleep)
        let before = await boardOfThree(session)
        _ = await session.markIdle(tileId: "zai")

        _ = await session.deliver(
            github(with: [Interruption(scene: scene(celebrationTag), scope: .everyPage, duration: 8)]),
            toTile: "github"
        )

        let expected = [
            "pct-zai=idle",
            "pct-github=G",
            "pct-weather=C", "pct-zai=C", "pct-github=C",
            "pct-weather=W", "pct-zai=idle", "pct-github=G",
        ]
        try await waitUntil { pushes(after: before).count >= expected.count }
        #expect(pushes(after: before) == expected)
    }

    @Test func interruptionsInOneDeliveryPlayInOrderEachOnItsScope() async throws {
        let sleep = ScriptedSleep(holds: false)
        let session = makeSession(sleep: sleep)
        let before = await boardOfThree(session)

        _ = await session.deliver(
            github(with: [
                Interruption(scene: scene(starsTag), scope: .everyPage, duration: 8),
                Interruption(scene: scene(forkTag), scope: .ownPage, duration: 5),
            ]),
            toTile: "github"
        )

        let expected = [
            "pct-github=G",
            "pct-weather=S", "pct-zai=S", "pct-github=S",
            "pct-github=F",
            "pct-weather=W", "pct-zai=Z", "pct-github=G",
        ]
        try await waitUntil { pushes(after: before).count >= expected.count }
        #expect(pushes(after: before) == expected)
        #expect(sleep.durations == [8, 5])
    }

    @Test func deliverReturnsBeforeTheWindowCloses() async throws {
        let sleep = ScriptedSleep(holds: true)
        let session = makeSession(sleep: sleep)
        let before = await boardOfThree(session)

        // Returns with the sleep still parked: were `deliver` waiting on the
        // window, this await would never come back.
        let result = await session.deliver(
            github(with: [Interruption(scene: scene(celebrationTag), scope: .ownPage, duration: 8)]),
            toTile: "github"
        )
        #expect(result == .delivered)

        try await waitUntil { sleep.parkedCount == 1 }
        #expect(pushes(after: before) == ["pct-github=G", "pct-github=C"])
        sleep.releaseNext()
        try await waitUntil { pushes(after: before).count >= 3 }
        #expect(pushes(after: before) == ["pct-github=G", "pct-github=C", "pct-github=G"])
    }

    @Test func aSecondInterruptionInsideTheWindowExtendsIt() async throws {
        let sleep = ScriptedSleep(holds: true)
        let session = makeSession(sleep: sleep)
        let before = await boardOfThree(session)

        _ = await session.deliver(
            github(with: [Interruption(scene: scene(starsTag), scope: .everyPage, duration: 8)]),
            toTile: "github"
        )
        try await waitUntil { sleep.parkedCount == 1 }
        // Two seconds into the first window: a second delivery, its own
        // celebration queued behind the one playing.
        _ = await session.deliver(
            UlanziDelivery(
                scene: scene(weatherTag),
                interruptions: [Interruption(scene: scene(forkTag), scope: .ownPage, duration: 5)]
            ),
            toTile: "weather"
        )
        sleep.releaseNext()
        try await waitUntil { sleep.parkedCount == 1 }
        sleep.releaseNext()

        let expected = [
            "pct-github=G",
            "pct-weather=S", "pct-zai=S", "pct-github=S",
            // weather's own push is deferred — its page is covered.
            "pct-weather=F",
            "pct-weather=W", "pct-zai=Z", "pct-github=G",
        ]
        try await waitUntil { pushes(after: before).count >= expected.count }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(pushes(after: before) == expected)
        #expect(sleep.durations == [8, 5])
    }

    @Test func aDeliveryToACoveredPageIsDeferredToTheRestore() async throws {
        let sleep = ScriptedSleep(holds: true)
        let session = makeSession(sleep: sleep)
        let before = await boardOfThree(session)

        _ = await session.deliver(
            github(with: [Interruption(scene: scene(celebrationTag), scope: .ownPage, duration: 8)]),
            toTile: "github"
        )
        try await waitUntil { sleep.parkedCount == 1 }

        let covered = await session.deliver(
            UlanziDelivery(scene: scene(starsTag)), toTile: "github"
        )
        let uncovered = await session.deliver(
            UlanziDelivery(scene: scene(forkTag)), toTile: "zai"
        )
        #expect(covered == .delivered)
        #expect(uncovered == .delivered)
        #expect(pushes(after: before) == ["pct-github=G", "pct-github=C", "pct-zai=F"])

        sleep.releaseNext()
        try await waitUntil { pushes(after: before).count >= 4 }
        // The restore carries the newest board frame, not the one the window
        // opened over.
        #expect(pushes(after: before).last == "pct-github=S")
    }

    @Test func theRecoverySweepLeavesACoveredPageAlone() async throws {
        let sleep = ScriptedSleep(holds: true)
        let session = makeSession(sleep: sleep)
        let before = await boardOfThree(session)

        _ = await session.deliver(
            github(with: [Interruption(scene: scene(celebrationTag), scope: .ownPage, duration: 8)]),
            toTile: "github"
        )
        try await waitUntil { sleep.parkedCount == 1 }

        // An outage and its end: the first success sweeps every page back —
        // every page but the covered one.
        recorder.failure = URLError(.timedOut)
        _ = await session.deliver(UlanziDelivery(scene: scene(zaiTag)), toTile: "zai")
        recorder.failure = nil
        _ = await session.deliver(UlanziDelivery(scene: scene(zaiTag)), toTile: "zai")

        #expect(!pushes(after: before).dropFirst(2).contains { $0.hasPrefix("pct-github=") })
        sleep.releaseNext()
        try await waitUntil { pushes(after: before).last == "pct-github=G" }
        #expect(pushes(after: before).last == "pct-github=G")
    }

    @Test func aRemovedTileIsNotRestored() async throws {
        let sleep = ScriptedSleep(holds: true)
        let session = makeSession(sleep: sleep)
        let before = await boardOfThree(session)

        _ = await session.deliver(
            github(with: [Interruption(scene: scene(celebrationTag), scope: .everyPage, duration: 8)]),
            toTile: "github"
        )
        try await waitUntil { sleep.parkedCount == 1 }
        await session.tileRemoved("zai")
        sleep.releaseNext()

        let expected = [
            "pct-github=G",
            "pct-weather=C", "pct-zai=C", "pct-github=C",
            "pct-weather=W", "pct-github=G",
        ]
        try await waitUntil { pushes(after: before).count >= expected.count }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(pushes(after: before) == expected)
        #expect(record.names(forClock: "clock-1").contains("pct-zai") == false)
    }

    @Test func shutdownStopsTheWindowWithoutAnotherPush() async throws {
        let sleep = ScriptedSleep(holds: true)
        let session = makeSession(sleep: sleep)
        let before = await boardOfThree(session)

        _ = await session.deliver(
            github(with: [
                Interruption(scene: scene(starsTag), scope: .everyPage, duration: 8),
                Interruption(scene: scene(forkTag), scope: .ownPage, duration: 5),
            ]),
            toTile: "github"
        )
        try await waitUntil { sleep.parkedCount == 1 }
        await session.shutdown()
        let afterShutdown = recorder.requests.count
        sleep.releaseNext()

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(recorder.requests.count == afterShutdown)
        #expect(pushes(after: before).count == 4)
    }

    @Test func theBoardNeverHoldsTheCelebration() async throws {
        let sleep = ScriptedSleep(holds: true)
        let session = makeSession(sleep: sleep)
        _ = await boardOfThree(session)

        _ = await session.deliver(
            github(with: [Interruption(scene: scene(celebrationTag), scope: .everyPage, duration: 8)]),
            toTile: "github"
        )
        try await waitUntil { sleep.parkedCount == 1 }

        // Mid-window, with every page showing the celebration on the wire.
        #expect(await session.boardFrame(forTile: "weather") == scene(weatherTag))
        #expect(await session.boardFrame(forTile: "github") == scene(githubTag))
        sleep.releaseNext()
    }
}
