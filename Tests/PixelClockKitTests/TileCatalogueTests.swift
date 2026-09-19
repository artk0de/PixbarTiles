import Foundation
import Testing
@testable import PixelClockKit

private let desk = ClockRecord(name: "Desk", model: .ulanziTC002, address: "10.0.0.2")
private let kitchen = ClockRecord(name: "Kitchen", model: .awtrix3, address: "10.0.0.3")
private let clocks = [desk, kitchen]

private let weather = TileCandidate(
    connectorId: "weather", models: [.awtrix3, .ulanziTC002], instancing: .single, isAudible: false
)
private let anecdotes = TileCandidate(
    connectorId: "anecdotes", models: [.awtrix3], instancing: .single, isAudible: true
)
private let vpn = TileCandidate(
    connectorId: "vpn", models: [.awtrix3], instancing: .perKey, isAudible: false
)

private func placed(_ connectorId: String, on clock: ClockRecord, instance: String = "") -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock.id, connectorId: connectorId, instance: instance),
        policy: TilePolicyRecord(TileDefaults.weather)
    )
}

private func availability(
    _ candidate: TileCandidate, on clock: ClockRecord, _ tiles: [TileRecord] = []
) -> TileAvailability {
    TileCatalogue.availability(of: candidate, on: clock, tiles: tiles, clocks: clocks)
}

@Test func aConnectorWithNoFaceForTheModelSaysSo() {
    #expect(availability(anecdotes, on: desk) == .unavailable("not supported on TC002"))
    #expect(availability(vpn, on: desk) == .unavailable("not supported on TC002"))
}

@Test func aConnectorWithAFaceForTheModelIsAvailable() {
    #expect(availability(weather, on: desk) == .available)
    #expect(availability(anecdotes, on: kitchen) == .available)
}

@Test func aSingleConnectorAlreadyOnThisClockIsNotListed() {
    #expect(availability(weather, on: kitchen, [placed("weather", on: kitchen)]) == .notListed)
}

@Test func aSilentConnectorOnAnotherClockIsStillAvailableHere() {
    #expect(availability(weather, on: desk, [placed("weather", on: kitchen)]) == .available)
}

@Test func anAudibleConnectorOnAnotherClockNamesTheClockItSpeaksThrough() {
    let elsewhere = ClockRecord(name: "Study", model: .awtrix3, address: "10.0.0.4")
    let tiles = [placed("anecdotes", on: elsewhere)]

    #expect(
        TileCatalogue.availability(
            of: anecdotes, on: kitchen, tiles: tiles, clocks: clocks + [elsewhere]
        ) == .unavailable("already speaking through Study")
    )
}

// Asked of the tiles as they are, not stamped when one was made: take the
// anecdotes off the study and the kitchen may have them.
@Test func theAnswerFollowsTheTilesAsTheyAreNow() {
    let elsewhere = ClockRecord(name: "Study", model: .awtrix3, address: "10.0.0.4")

    #expect(
        TileCatalogue.availability(
            of: anecdotes, on: kitchen, tiles: [], clocks: clocks + [elsewhere]
        ) == .available
    )
}

@Test func aPerKeyConnectorIsListedWhateverIsAlreadyOnTheClock() {
    #expect(availability(vpn, on: kitchen, [placed("vpn", on: kitchen, instance: "pritunl")]) == .available)
}

@Test func theFaceIsAskedBeforeAnythingPlacedAnywhere() {
    let tiles = [placed("anecdotes", on: desk), placed("anecdotes", on: kitchen)]

    #expect(availability(anecdotes, on: desk, tiles) == .unavailable("not supported on TC002"))
}

// The VPN is a lamp, not a scene: an AWTRIX clock only, one tile per VPN.
@Test func theVPNIsOfferedOnAWTRIXClocksOnePerVPN() {
    #expect(TileCandidate(VPNConnector(isUp: { _ in true })) == TileCandidate(
        connectorId: "vpn", models: [.awtrix3], instancing: .perKey, isAudible: false
    ))
}

// A scene connector supports the models it has faces for, and nothing says so
// but the faces. Until Phase 3b's UlanziFace lands, every shipped connector has
// an AWTRIX face and nothing else — which is what the candidate reports.
@Test func aSceneConnectorIsOfferedWhereItHasAFace() {
    #expect(TileCandidate(AWTRIXOnly()).models == [.awtrix3])
}

private struct AWTRIXOnly: Connector {
    let id = "awtrix-only"
    let displayName = "AWTRIX only"
    let defaultInterval: TimeInterval = 600
    let isAudible = true
    func read() async throws -> Int { 0 }
    var awtrixFace: AwtrixFace<Int> { AwtrixFace { _ in AwtrixDelivery(text: "") } }
}

// Rule 3 is about ANOTHER clock. No shipped connector is audible and keyed at
// once, so this is posed with a candidate made for it: a second instance on the
// same clock speaks through the same room, and naming this very clock as the
// one "already speaking" would be the rule refusing a tile for its own sibling.
@Test func anAudibleTileOnThisClockIsNotAnotherClock() {
    let radio = TileCandidate(
        connectorId: "radio", models: [.awtrix3], instancing: .perKey, isAudible: true
    )

    #expect(availability(radio, on: kitchen, [placed("radio", on: kitchen, instance: "bbc")]) == .available)
}
