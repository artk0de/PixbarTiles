// Tests/PixbarKitTests/UlanziClockSessionTests.swift
import Foundation
import Testing
@testable import PixbarKit

private func drawnScene(colour: Pixel) -> UlanziScene {
    var canvas = PixelCanvas()
    canvas.fill(colour)
    return UlanziScene(frames: [UlanziFrame(duration: 5, draw: [canvas.drawCommands()])])
}

@Suite struct UlanziClockSessionTests {
    let recorder = RecordingTransport()
    let record = MemoryAppRecord()
    let okEnvelope = Data(#"{"code":200,"message":"ok"}"#.utf8)

    func makeSession(clockId: String = "clock-1") -> UlanziClockSession {
        let device = UlanziDevice(host: "192.168.1.72", transport: recorder)
        return UlanziClockSession(
            device: device,
            custody: UlanziCustody(device: device, record: record, clockId: clockId)
        )
    }

    func makeOnline() {
        recorder.body = okEnvelope
    }

    @Test func deliverUpsertsTheTilesPageUnderItsCustodyName() async throws {
        makeOnline()
        let session = makeSession()

        let result = await session.deliver(
            UlanziDelivery(scene: drawnScene(colour: .white)), toTile: "weather"
        )

        #expect(result == .delivered)
        #expect(recorder.requests.count == 1)
        let request = try #require(recorder.requests.first)
        #expect(request.url?.query == "name=pct-weather")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["draw"] as? [[String: Any]])?.count == 1)
        #expect(record.names(forClock: "clock-1") == ["pct-weather"])
    }

    @Test func theTwentySecondTileFailsAndTheDeviceHearsNothing() async throws {
        makeOnline()
        let session = makeSession()
        for i in 0..<21 {
            let result = await session.deliver(
                UlanziDelivery(scene: drawnScene(colour: .white)), toTile: "tile\(i)"
            )
            #expect(result == .delivered)
        }
        let pushesBeforeTheCap = recorder.requests.count

        let result = await session.deliver(
            UlanziDelivery(scene: drawnScene(colour: .white)), toTile: "one-too-many"
        )

        guard case .failed = result else {
            Issue.record("expected .failed for the 22nd tile, got \(result)")
            return
        }
        #expect(recorder.requests.count == pushesBeforeTheCap)
    }

    @Test func firstSuccessAfterAFailureRePushesEveryRegisteredTile() async throws {
        makeOnline()
        let session = makeSession()
        _ = await session.deliver(
            UlanziDelivery(scene: drawnScene(colour: .white)), toTile: "weather"
        )

        // The clock goes away mid-delivery: claude's first push fails. A
        // transport failure — an HTTP 500 is the clock answering, not gone.
        recorder.failure = URLError(.timedOut)
        let failed = await session.deliver(
            UlanziDelivery(scene: drawnScene(colour: .black)), toTile: "claude"
        )
        guard case .failed = failed else {
            Issue.record("expected .failed while the clock is unreachable, got \(failed)")
            return
        }

        // Back online: the next successful push drags every page back with it.
        recorder.failure = nil
        _ = await session.deliver(
            UlanziDelivery(scene: drawnScene(colour: .white)), toTile: "weather"
        )

        let claudePosts = recorder.requests.filter { $0.url?.query == "name=pct-claude" }
        // The previously failed tile: its failed attempt, then the recovery
        // re-push that pulled it back in — the page is not left behind.
        #expect(claudePosts.count == 2)
        let weatherPosts = recorder.requests.filter { $0.url?.query == "name=pct-weather" }
        // First deliver and post-recovery deliver — no sweep re-push of its
        // own: weather is the tile whose successful push ended the outage.
        #expect(weatherPosts.count == 2)
    }

    @Test func markIdlePushesTheIdleFrameAndTheNextDeliveryOverwritesIt() async throws {
        makeOnline()
        let session = makeSession()

        _ = await session.markIdle(tileId: "weather")
        let pausedBody = try #require(recorder.requests.last?.httpBody)
        let paused = try #require(
            try JSONSerialization.jsonObject(with: pausedBody) as? [String: Any]
        )
        // The idle frame is the single dim dot: one filled circle, no bitmap.
        #expect((paused["draw"] as? [[String: Any]])?.first?["dfc"] != nil)

        _ = await session.deliver(
            UlanziDelivery(scene: drawnScene(colour: .white)), toTile: "weather"
        )
        let shownBody = try #require(recorder.requests.last?.httpBody)
        let shown = try #require(
            try JSONSerialization.jsonObject(with: shownBody) as? [String: Any]
        )
        #expect((shown["draw"] as? [[String: Any]])?.first?["db"] != nil)
    }

    @Test func tileRemovedDeletesThePageWithAnEmptyBodyAndDropsTheRecord() async throws {
        makeOnline()
        let session = makeSession()
        _ = await session.deliver(
            UlanziDelivery(scene: drawnScene(colour: .white)), toTile: "weather"
        )

        await session.tileRemoved("weather")

        let request = try #require(recorder.requests.last)
        #expect(request.url?.query == "name=pct-weather")
        // The empty body IS the delete (research §2.2) — a `{}` body would
        // leave the app in the knob cycle.
        #expect(request.httpBody ?? Data() == Data())
        #expect(record.names(forClock: "clock-1") == [])
    }

    @Test func shutdownReleasesEveryPageAndEmptiesTheRecord() async throws {
        makeOnline()
        let session = makeSession()
        _ = await session.deliver(
            UlanziDelivery(scene: drawnScene(colour: .white)), toTile: "weather"
        )
        _ = await session.deliver(
            UlanziDelivery(scene: drawnScene(colour: .black)), toTile: "claude"
        )

        await session.shutdown()

        let deletes = recorder.requests.suffix(2)
        #expect(deletes.count == 2)
        for request in deletes {
            #expect(request.httpBody ?? Data() == Data())
        }
        let named = Set(deletes.compactMap { $0.url?.query })
        #expect(named == ["name=pct-weather", "name=pct-claude"])
        #expect(record.names(forClock: "clock-1") == [])
    }

    @Test func sweepDeletesTheStaleNameBeforeLiveTilesPush() async throws {
        record.save(["pct-stale", "pct-weather"], forClock: "clock-1")
        recorder.body = UlanziCustodyTests.listAnswer(["pct-stale", "pct-weather"])
        let session = makeSession()

        await session.sweep(liveTiles: ["weather"])

        recorder.body = okEnvelope
        _ = await session.deliver(
            UlanziDelivery(scene: drawnScene(colour: .white)), toTile: "weather"
        )

        // First POST traffic: the stale name's empty-body delete. Then the
        // live tile's push, never before it. (The very first request is the
        // customList GET the sweep reads, which carries no query.)
        let posts = recorder.requests.filter { $0.httpMethod == "POST" }
        let first = try #require(posts.first)
        #expect(first.url?.query == "name=pct-stale")
        #expect(first.httpBody ?? Data() == Data())
        let last = try #require(posts.last)
        #expect(last.url?.query == "name=pct-weather")
    }
}

// MARK: - Showing a tile's page on request

/// The settings window brings its tile's page up (user-initiated, so D3's
/// "the Mac never turns the knob" is not in the way). What the session owes
/// that path: the page name, only while the clock lists it; the switch
/// itself; and an honest "cannot say" for the page on screen.
@Suite struct UlanziClockSessionPageTests {
    let recorder = RecordingTransport()
    let record = MemoryAppRecord()

    func makeSession() -> UlanziClockSession {
        let device = UlanziDevice(host: "192.168.1.72", transport: recorder)
        return UlanziClockSession(
            device: device,
            custody: UlanziCustody(device: device, record: record, clockId: "clock-1")
        )
    }

    @Test func aTileTheClockListsHasItsPageName() async throws {
        recorder.body = Data(#"{"apps":["pct-weather","pct-zai"],"count":2}"#.utf8)
        let session = makeSession()

        #expect(try await session.page(forTile: "weather") == "pct-weather")
        #expect(recorder.requests.map { $0.url?.path } == ["/api/customList"])
    }

    /// Not on the clock yet — added a moment ago, or wiped by a reboot — is no
    /// page: switching to a name the clock does not carry would do nothing
    /// useful at best.
    @Test func aTileTheClockDoesNotListHasNoPage() async throws {
        recorder.body = Data(#"{"apps":["pct-zai"],"count":1}"#.utf8)
        let session = makeSession()

        #expect(try await session.page(forTile: "weather") == nil)
    }

    @Test func showPagePostsTheSwitch() async throws {
        recorder.body = Data(#"{"message":"app switch requested","data":{"name":"pct-weather","index":100}}"#.utf8)
        let session = makeSession()

        try await session.showPage("pct-weather")

        let request = try #require(recorder.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/switchDiyApp")
        #expect(request.url?.query == "name=pct-weather")
    }

    /// The firmware cannot report which app is on screen (research §0), so
    /// the answer is nil and nothing is asked of the wire.
    @Test func theCurrentPageIsUnknownAndCostsNoRequest() async throws {
        let session = makeSession()

        #expect(try await session.currentPage() == nil)
        #expect(recorder.requests.isEmpty)
    }
}
