// Tests/PixbarKitTests/UlanziLegacyPageTests.swift
import Foundation
import Testing
@testable import PixbarKit

private func scene() -> UlanziScene {
    var canvas = PixelCanvas()
    canvas.fill(.white)
    return UlanziScene(frames: [UlanziFrame(duration: 1, draw: [canvas.drawCommands()])])
}

/// The app's pages on a TC002 were named `pct-<tile>` while it was
/// PixelClockTiles, and are `pbt-<tile>` now. TC002 pages outlive the process,
/// so the first launch after the rename finds the old ones still in the knob
/// cycle: they are ours, and the startup sweep takes them back — whether or not
/// the record carried over with the defaults — while anybody else's page stays
/// exactly where it is. The tiles' next deliveries put them back as `pbt-…`.
@Suite struct UlanziLegacyPageTests {
    let transport = ScriptedUlanziTransport()
    let record = MemoryAppRecord()

    func makeSession() -> UlanziClockSession {
        let device = UlanziDevice(host: "192.168.1.72", transport: transport)
        return UlanziClockSession(
            device: device,
            custody: UlanziCustody(device: device, record: record, clockId: "clock-1"),
            sleep: { _ in }
        )
    }

    /// Every request after `from`: the list read, a delete, an upsert.
    func wire(after from: Int = 0) -> [String] {
        transport.requests.dropFirst(from).map { request in
            if request.url?.path == "/api/customList" { return "list" }
            let name = request.url?.query.map { String($0.dropFirst("name=".count)) } ?? "?"
            return (request.httpBody ?? Data()).isEmpty ? "delete \(name)" : "push \(name)"
        }
    }

    @Test func theTilesPageIsNamedWithTheNewPrefix() {
        #expect(UlanziCustody.pageName(forTile: "weather") == "pbt-weather")
    }

    // No record at all — a clock added again, or defaults that did not come
    // across: the prefix alone says the page is ours.
    @Test func theSweepTakesBackOldPagesTheRecordNeverHeard() async {
        transport.list = ["pct-weather", "somebody-else", "weather", "pct-claude"]
        let session = makeSession()

        await session.sweep(liveTiles: ["weather", "claude"])

        #expect(wire() == ["list", "delete pct-weather", "delete pct-claude"])
        #expect(record.names(forClock: "clock-1") == [])
    }

    // The record carried over with the defaults still names the old pages: they
    // go once, not twice, and leave the record.
    @Test func theSweepTakesBackOldPagesTheRecordStillHolds() async {
        record.save(["pct-weather", "pct-claude"], forClock: "clock-1")
        transport.list = ["pct-weather", "pct-claude", "somebody-else"]
        let session = makeSession()

        await session.sweep(liveTiles: ["weather", "claude"])

        #expect(wire() == ["list", "delete pct-weather", "delete pct-claude"])
        #expect(record.names(forClock: "clock-1") == [])
    }

    // An old page the clock no longer lists — a reboot since — has nothing to
    // delete; it only leaves the record.
    @Test func anOldPageTheClockLostOnlyLeavesTheRecord() async {
        record.save(["pct-weather"], forClock: "clock-1")
        transport.list = ["somebody-else"]
        let session = makeSession()

        await session.sweep(liveTiles: ["weather"])

        #expect(wire() == ["list"])
        #expect(record.names(forClock: "clock-1") == [])
    }

    // After the sweep, the tile's next delivery puts its page back under the
    // new name.
    @Test func theOldPageIsReplacedByTheNewOne() async {
        transport.list = ["pct-weather"]
        let session = makeSession()
        await session.sweep(liveTiles: ["weather"])
        let before = transport.requests.count

        _ = await session.deliver(UlanziDelivery(scene: scene()), toTile: "weather")

        #expect(wire(after: before) == ["push pbt-weather"])
        #expect(record.names(forClock: "clock-1") == ["pbt-weather"])
    }

    // The literals: the prefix a page is named with, and the one that still
    // marks a page as ours from before the rename.
    @Test func thePrefixesAreTheAppsNowAndBefore() {
        #expect(UlanziCustody.pagePrefix == "pbt-")
        #expect(UlanziCustody.legacyPagePrefixes == ["pct-"])
    }
}
