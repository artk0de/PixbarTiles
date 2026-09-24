import Foundation
import Testing
@testable import PixbarKit

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
    #expect(availability(anecdotes, on: desk) == .unavailable("not supported on TC-002 Pixbar"))
    #expect(availability(vpn, on: desk) == .unavailable("not supported on TC-002 Pixbar"))
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

    #expect(availability(anecdotes, on: desk, tiles) == .unavailable("not supported on TC-002 Pixbar"))
}

// A scene connector that says it sits on a clock once per key — a repository
// per GitHub tile — is still offered with one of its tiles already there. The
// candidate reads that off the connector rather than assuming every scene is
// single.
@Test func aPerKeyConnectorAlreadyOnTheClockIsStillListed() {
    let candidate = TileCandidate(PerKeyScene())

    #expect(candidate.instancing == .perKey)
    #expect(
        availability(candidate, on: kitchen, [placed("per-key", on: kitchen, instance: "a/x")])
            == .available
    )
}

// A scene connector that says nothing is single, which is what every one
// written before instancing was.
@Test func aSceneConnectorThatSaysNothingIsSingle() {
    #expect(TileCandidate(AWTRIXOnly()).instancing == .single)
}

// The VPN is a lamp, not a scene: an AWTRIX clock only, one tile per VPN —
// and its card wears the lamp's own shelf, mark and line on the store.
@Test func theVPNIsOfferedOnAWTRIXClocksOnePerVPN() {
    let candidate = TileCandidate(VPNConnector(isUp: { _ in true }))

    #expect(candidate.connectorId == "vpn")
    #expect(candidate.models == [.awtrix3])
    #expect(candidate.instancing == .perKey)
    #expect(candidate.isAudible == false)
    #expect(candidate.category == .network)
    #expect(candidate.storeIcon == "lock.shield")
    #expect(candidate.blurb == "A watched VPN, as a lamp on the clock")
}

// The store's presentation is one table keyed by connector id, so a tile
// wears one shelf, one mark and one line everywhere it is shown. A connector
// the table does not know defaults onto the Dev shelf, faceless; a candidate
// that says its presentation outright outranks the table.
@Test func theStorePresentationComesFromOneTable() {
    func presentation(_ connectorId: String) -> TileCandidate {
        TileCandidate(
            connectorId: connectorId, models: [.awtrix3], instancing: .single, isAudible: false
        )
    }

    let weather = presentation(WeatherConnector.appName)
    #expect(weather.category == .weather)
    #expect(weather.storeIcon == "cloud.sun")
    #expect(weather.blurb == "The sky where the clock is")

    let claude = presentation(ClaudeUsageConnector.id)
    #expect(claude.category == .dev)
    #expect(claude.storeIcon == "terminal")
    #expect(claude.blurb == "Claude usage, from the status line")

    #expect(presentation("anecdotes").category == .system)

    let stranger = presentation("custom-thing")
    #expect(stranger.category == .dev)
    #expect(stranger.storeIcon == "app.dashed")
    #expect(stranger.blurb == "")

    let stated = TileCandidate(
        connectorId: "custom-thing", models: [.awtrix3], instancing: .single, isAudible: false,
        category: .system, storeIcon: "gauge", blurb: "said outright"
    )
    #expect(stated.category == .system)
    #expect(stated.storeIcon == "gauge")
    #expect(stated.blurb == "said outright")
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
    #expect(availability(TileCandidate(AWTRIXOnly()), on: desk) == .unavailable("not supported on TC-002 Pixbar"))
}

// The shipped connectors read through their faces, as the spec's
// "Connectors and faces" table draws it: weather and claude carry real TC002
// faces and are offered on one; the vpn is a lamp with no face by design.
@Test func theShippedFacesDecideTheShippedCandidates() {
    let shippedWeather = TileCandidate(WeatherConnector(
        source: OpenMeteoSource(transport: SilentTransport()),
        location: { Coordinates(latitude: 55.7, longitude: 37.6) },
        config: { WeatherTileConfig(place: Coordinates(latitude: 55.7, longitude: 37.6)) }
    ))
    let shippedClaude = TileCandidate(ClaudeUsageConnector(reporter: SilentReporter()))

    #expect(shippedWeather.models == [.awtrix3, .ulanziTC002])
    #expect(shippedClaude.models == [.awtrix3, .ulanziTC002])
    #expect(availability(shippedWeather, on: desk) == .available)
    #expect(availability(shippedClaude, on: desk) == .available)
    #expect(availability(vpn, on: desk) == .unavailable("not supported on TC-002 Pixbar"))
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

private struct PerKeyScene: Connector {
    let id = "per-key"
    let displayName = "Per key"
    let defaultInterval: TimeInterval = 600
    let isAudible = false
    let instancing = Instancing.perKey
    func read() async throws -> Int { 0 }
    var awtrixFace: AwtrixFace<Int> { AwtrixFace { _ in AwtrixDelivery(text: "") } }
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
