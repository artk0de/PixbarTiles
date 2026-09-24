// Tests/PixelClockKitTests/UlanziRecoveryTests.swift
import Foundation
import Testing
@testable import PixelClockKit

private func scene(_ tag: Int) -> UlanziScene {
    var canvas = PixelCanvas()
    canvas.fill(.white)
    return UlanziScene(frames: [UlanziFrame(duration: tag, draw: [canvas.drawCommands()])])
}

/// A TC002 on a script: the whole clock off the network, one page's upserts
/// timing out, one page's refused in the `code` envelope, and what
/// `customList` answers. Records every request.
final class ScriptedUlanziTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var isDown = false
    private var timingOut: Set<String> = []
    private var refused: Set<String> = []
    private var listed: [String] = []

    var requests: [URLRequest] { lock.withLock { recorded } }
    var down: Bool {
        get { lock.withLock { isDown } }
        set { lock.withLock { isDown = newValue } }
    }
    /// Page names whose upserts time out.
    var timeouts: Set<String> {
        get { lock.withLock { timingOut } }
        set { lock.withLock { timingOut = newValue } }
    }
    /// Page names whose upserts the firmware refuses in its envelope.
    var refusals: Set<String> {
        get { lock.withLock { refused } }
        set { lock.withLock { refused = newValue } }
    }
    /// What `GET /api/customList` answers, bare as appVer 1.1.1 does.
    var list: [String] {
        get { lock.withLock { listed } }
        set { lock.withLock { listed = newValue } }
    }

    /// Page upserts (non-empty POST bodies) to this name so far.
    func posts(_ page: String) -> Int {
        requests.filter {
            $0.httpMethod == "POST" && $0.url?.path == "/api/custom"
                && $0.url?.query == "name=\(page)" && !($0.httpBody ?? Data()).isEmpty
        }.count
    }

    var listReads: Int { requests.filter { $0.url?.path == "/api/customList" }.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try lock.withLock { () throws -> Data in
            recorded.append(request)
            if isDown { throw URLError(.timedOut) }
            if request.url?.path == "/api/customList" {
                let names = listed.map { "\"\($0)\"" }.joined(separator: ",")
                return Data(#"{"apps":[\#(names)],"count":\#(listed.count)}"#.utf8)
            }
            let name = request.url?.query.map { String($0.dropFirst("name=".count)) } ?? ""
            if timingOut.contains(name) { throw URLError(.timedOut) }
            if refused.contains(name) { return Data(#"{"code":500,"message":"busy"}"#.utf8) }
            return Data(#"{"code":200,"message":"ok"}"#.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

/// A wall clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { current } }
    func set(_ offset: TimeInterval) { lock.withLock { current = Date(timeIntervalSince1970: 1_000_000 + offset) } }
}

/// What counts as the clock going away, and how often the pages are dragged
/// back afterwards. Only the transport failing is an outage: a clock that
/// answers — even to refuse — still has its pages. The drag-back runs one at a
/// time and backs off while it keeps failing, so a clock that is struggling is
/// not answered with more of the load that is making it struggle.
@Suite struct UlanziRecoveryTests {
    let transport = ScriptedUlanziTransport()
    let clock = TestClock()
    let record = MemoryAppRecord()

    func makeSession() -> UlanziClockSession {
        let device = UlanziDevice(host: "192.168.1.72", transport: transport)
        return UlanziClockSession(
            device: device,
            custody: UlanziCustody(device: device, record: record, clockId: "clock-1"),
            sleep: { _ in },
            now: { [clock] in clock.now }
        )
    }

    /// a, b and c each on their first frame.
    func boardOfThree(_ session: UlanziClockSession) async {
        for tile in ["a", "b", "c"] {
            _ = await session.deliver(UlanziDelivery(scene: scene(1)), toTile: tile)
        }
    }

    @Test func aRefusalIsNotAnOutage() async {
        let session = makeSession()
        await boardOfThree(session)

        transport.refusals = ["pct-c"]
        _ = await session.deliver(UlanziDelivery(scene: scene(2)), toTile: "c")
        transport.refusals = []
        _ = await session.deliver(UlanziDelivery(scene: scene(2)), toTile: "a")

        // No sweep: b is not re-pushed, and c only by its own next delivery.
        #expect(transport.posts("pct-b") == 1)
        #expect(transport.posts("pct-c") == 2)
    }

    @Test func aTimeoutIsAnOutageAndTheNextAnswerSweeps() async {
        let session = makeSession()
        await boardOfThree(session)

        transport.down = true
        _ = await session.deliver(UlanziDelivery(scene: scene(2)), toTile: "c")
        transport.down = false
        _ = await session.deliver(UlanziDelivery(scene: scene(2)), toTile: "a")

        #expect(transport.posts("pct-b") == 2)
        #expect(transport.posts("pct-c") == 3)
    }

    /// A sweep that fails does not start another at the next answer: the next
    /// one waits 60 s, then 120 s, then 300 s, and stays at 300 s.
    @Test func failedSweepsBackOffAndACleanOneResets() async {
        let session = makeSession()
        await boardOfThree(session)
        transport.down = true
        _ = await session.deliver(UlanziDelivery(scene: scene(2)), toTile: "a")
        transport.down = false
        transport.timeouts = ["pct-c"]

        var tag = 10
        /// One answered push from a at `offset`; true when it set off a sweep.
        func answerAt(_ offset: TimeInterval) async -> Bool {
            clock.set(offset)
            let before = transport.posts("pct-b")
            tag += 1
            _ = await session.deliver(UlanziDelivery(scene: scene(tag)), toTile: "a")
            return transport.posts("pct-b") > before
        }

        #expect(await answerAt(0))          // sweep 1, c times out
        #expect(await answerAt(59) == false)
        #expect(await answerAt(60))         // sweep 2
        #expect(await answerAt(179) == false)
        #expect(await answerAt(180))        // sweep 3
        #expect(await answerAt(479) == false)
        #expect(await answerAt(480))        // sweep 4 — capped at 300 s
        #expect(await answerAt(779) == false)
        transport.timeouts = []
        #expect(await answerAt(780))        // sweep 5, clean

        // Clean resets the backoff: the next outage is swept at once.
        transport.down = true
        _ = await session.deliver(UlanziDelivery(scene: scene(99)), toTile: "a")
        transport.down = false
        #expect(await answerAt(781))
    }

    /// Failures inside a sweep do not start a nested or back-to-back sweep.
    @Test func aSweepRunsOnceEvenWhenItsOwnPushesFail() async {
        let session = makeSession()
        await boardOfThree(session)
        transport.down = true
        _ = await session.deliver(UlanziDelivery(scene: scene(2)), toTile: "a")
        transport.down = false
        transport.timeouts = ["pct-b"]

        _ = await session.deliver(UlanziDelivery(scene: scene(3)), toTile: "a")

        // b attempted once by the sweep, c re-pushed once — nothing repeated.
        #expect(transport.posts("pct-b") == 2)
        #expect(transport.posts("pct-c") == 2)
    }
}
