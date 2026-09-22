import AppKit
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The tile settings window's facade: which tile it holds, the draft its
// controls edit, and the preview that cannot lie — because it is the face's
// own canvas, encoded by the kit's own writer, drawn from the connector's
// own reading.

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")

/// The sky with everything the tile's answers read: humidity and a felt
/// temperature, so a flip of either control changes what the face composes.
private let skyWithAnswers = Data("""
{"current":{"time":"2026-08-19T02:45","interval":900,"weather_code":61,"is_day":1,
  "precipitation":0.4,"temperature_2m":4.2,"wind_speed_10m":9.0,
  "relative_humidity_2m":54,"apparent_temperature":-2.0}}
""".utf8)

@MainActor
private func weatherModel(
    tiles: [TileRecord]? = nil
) -> (model: AppModel, transport: SkyAndClockTransport) {
    let transport = SkyAndClockTransport(sky: skyWithAnswers)
    let model = testModel(
        connectors: [weatherConnector(over: transport), StubConnector(isAudible: false)],
        transport: transport,
        clocks: [desk],
        tiles: tiles
    )
    return (model, transport)
}

private func weatherTile(on clock: ClockRecord) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock.id, connectorId: "weather"),
        policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600),
        config: .weather(WeatherTileConfig(place: aDesk))
    )
}

@Test @MainActor func theWindowFollowsTheTileThePanelAimedItAt() async {
    let (model, _) = weatherModel(tiles: [weatherTile(on: desk)])
    let subject = TileSettingsModel(model: model, debounce: 0)
    let key = TileKey(clockId: desk.id, connectorId: "weather")

    model.openDetail(for: key)

    // The facade rides the model's own pulse, one hop after it — the same
    // catch-up the panel's projection waits for.
    #expect(await waitUntil { subject.key == key })
    #expect(subject.draft == WeatherTileConfig(place: aDesk))
    await model.teardown()
}

// The tile with no stored config of its own still opens: the draft starts
// from the shipped defaults, which is what the pre-settings face drew. The
// tiles a factory builds carry no config — exactly the record an upgraded
// install decodes.
@Test @MainActor func aTileWithNoStoredConfigStartsFromTheShippedDefaults() async {
    let (model, _) = weatherModel(tiles: nil)
    let subject = TileSettingsModel(model: model, debounce: 0)
    let key = TileKey(clockId: desk.id, connectorId: "weather")

    model.openDetail(for: key)
    #expect(await waitUntil { subject.key == key })

    #expect(subject.draft?.units == .celsius)
    #expect(subject.draft?.showsHumidity == true)
    await model.teardown()
}

// Requirement 7, as the facade carries it: a control flipped, the preview
// flips with it — different settings, different bytes, because the pixels
// are the face's own.
@Test @MainActor func flippingAControlFlipsThePreview() async {
    let (model, _) = weatherModel(tiles: [weatherTile(on: desk)])
    let subject = TileSettingsModel(model: model, debounce: 0)
    let key = TileKey(clockId: desk.id, connectorId: "weather")

    model.openDetail(for: key)
    #expect(await waitUntil { subject.preview != nil })
    let withHumidity = subject.preview

    subject.setShowHumidity(false)
    #expect(await waitUntil { subject.preview != nil && subject.preview != withHumidity })
    await model.teardown()
}

// The scale flips it too: the same sky at the other scale is another
// drawing, which is the whole reason the face names its unit.
@Test @MainActor func changingTheScaleFlipsThePreview() async {
    let (model, _) = weatherModel(tiles: [weatherTile(on: desk)])
    let subject = TileSettingsModel(model: model, debounce: 0)
    model.openDetail(for: TileKey(clockId: desk.id, connectorId: "weather"))
    #expect(await waitUntil { subject.preview != nil })
    let celsius = subject.preview

    subject.setUnits(.fahrenheit)
    #expect(await waitUntil { subject.preview != nil && subject.preview != celsius })
    await model.teardown()
}

// The draft is the draft, not a mirror of the record: a run elsewhere
// publishes the model, and the published world must not throw away what a
// hand is mid-way through editing.
@Test @MainActor func theDraftSurvivesAPublishFromElsewhere() async {
    let (model, _) = weatherModel(tiles: [weatherTile(on: desk)])
    let key = TileKey(clockId: desk.id, connectorId: "weather")
    let subject = TileSettingsModel(model: model, debounce: 0)

    model.openDetail(for: key)
    #expect(await waitUntil { subject.key == key })
    subject.setShowHumidity(false)
    #expect(subject.draft?.showsHumidity == false)

    // Any model publish, arrived after the flip: a manual run of the second
    // connector the model carries.
    model.runNow("stub")
    #expect(await waitUntil { model.lastResults["stub"] != nil })
    #expect(subject.draft?.showsHumidity == false)
    await model.teardown()
}

// The save is the draft into the record, policy untouched.
@Test @MainActor func savingWritesTheDraftIntoTheRecord() async {
    let (model, _) = weatherModel(tiles: [weatherTile(on: desk)])
    let subject = TileSettingsModel(model: model, debounce: 0)
    let key = TileKey(clockId: desk.id, connectorId: "weather")
    model.openDetail(for: key)
    #expect(await waitUntil { subject.key == key })

    subject.setShowFeelsLike(false)
    subject.saveConfig()

    #expect(
        await waitUntil { model.storedTile(key)?.config?.weatherConfig?.showsFeelsLike == false }
    )
    #expect(model.storedTile(key)?.config?.weatherConfig?.units == .celsius)
    await model.teardown()
}

// And a tile that is not weather has no draft — its controls are not this
// facade's — but the window still renders what the tile draws: the
// connector's own face, on the model of the clock the tile sits on.
// Requirement 6 is every tile's, not the weather's.
@Test @MainActor func aNonWeatherTileStillRendersItsOwnFace() async {
    let (model, _) = weatherModel(tiles: [
        TileRecord(
            key: TileKey(clockId: desk.id, connectorId: "stub"),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600)
        )
    ])
    let subject = TileSettingsModel(model: model, debounce: 0)
    let key = TileKey(clockId: desk.id, connectorId: "stub")

    model.openDetail(for: key)

    #expect(await waitUntil { subject.key == key })
    #expect(subject.draft == nil)
    #expect(await waitUntil { subject.preview != nil })
    await model.teardown()
}
