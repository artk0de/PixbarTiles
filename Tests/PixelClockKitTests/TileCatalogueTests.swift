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

// The candidate's models come from the connector's own faces: a TC002 face
// puts the TC002 on the list, and the connector is offered on that clock.
@Test func aConnectorWithATC002FaceIsOfferedOnTheTC002() {
    let candidate = TileCandidate(TC002Too())

    #expect(candidate.models == [.awtrix3, .ulanziTC002])
    #expect(availability(candidate, on: desk) == .available)
}

@Test func aConnectorWithNoTC002FaceStaysUnsupportedOnTheTC002() {
    #expect(availability(TileCandidate(AWTRIXOnly()), on: desk) == .unavailable("not supported on TC002"))
}

// The shipped connectors read through their faces, as the spec's
// "Connectors and faces" table draws it: weather and claude carry real TC002
// faces and are offered on one; the vpn is a lamp with no face by design.
@Test func theShippedFacesDecideTheShippedCandidates() {
    let shippedWeather = TileCandidate(WeatherConnector(
        source: OpenMeteoSource(transport: SilentTransport()),
        location: { Coordinates(latitude: 55.7, longitude: 37.6) }
    ))
    let shippedClaude = TileCandidate(ClaudeUsageConnector(reporter: SilentReporter()))

    #expect(shippedWeather.models == [.awtrix3, .ulanziTC002])
    #expect(shippedClaude.models == [.awtrix3, .ulanziTC002])
    #expect(availability(shippedWeather, on: desk) == .available)
    #expect(availability(shippedClaude, on: desk) == .available)
    #expect(availability(vpn, on: desk) == .unavailable("not supported on TC002"))
}

private struct AWTRIXOnly: Connector {
    let id = "awtrix-only"
    let displayName = "AWTRIX only"
    let defaultInterval: TimeInterval = 600
    let isAudible = true
    func read() async throws -> Int { 0 }
    var awtrixFace: AwtrixFace<Int> { AwtrixFace { _ in AwtrixDelivery(text: "") } }
}

private struct TC002Too: Connector {
    let id = "tc002-too"
    let displayName = "TC002 too"
    let defaultInterval: TimeInterval = 600
    let isAudible = false
    func read() async throws -> Int { 0 }
    var awtrixFace: AwtrixFace<Int> { AwtrixFace { _ in AwtrixDelivery(text: "") } }
    var ulanziFace: UlanziFace<Int>? {
        UlanziFace { _ in UlanziDelivery(scene: UlanziScene(frames: [UlanziFrame(duration: 5)])) }
    }
}

/// Never called: the catalogue reads the candidate, and the candidate never
/// reaches the network.
private struct SilentTransport: Transport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        fatalError("the catalogue never reaches the network")
    }
}

private struct SilentReporter: ClaudeUsageReporting {
    func read() async throws -> ClaudeUsageReading? { nil }
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
