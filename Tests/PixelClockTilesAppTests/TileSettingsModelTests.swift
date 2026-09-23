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

// The preview's own wiring question, and the defect it shipped with: it drew
// through `AppModel.registry`, the app-level copy the MENUS are named from.
// Those instances are inert on purpose — z.ai's is built `key: { nil }`,
// Claude's carries no metric, the weather's is closed over the FIRST clock's
// place — so a z.ai tile with a key saved previewed "check its key", a Claude
// tile set to the day previewed the week, and a weather tile on the second
// clock previewed the first clock's city. The connector a tile's own clock
// RUNS is the only one whose output that clock would receive.
@Test @MainActor func aTilesConnectorComesFromItsOwnClocksRegistry() async {
    let clocksOwn = ConnectorRegistry()
    clocksOwn.register(StubConnector(id: "weather", displayName: "The clock's own"))
    let model = testModel(
        connectors: [weatherConnector(over: SkyAndClockTransport(sky: skyWithAnswers))],
        clocks: [desk],
        makeClockRegistry: { _ in clocksOwn }
    )

    let fromTheClock = model.connector(for: TileKey(clockId: desk.id, connectorId: "weather"))
    #expect(fromTheClock is StubConnector)
    // And the app-level copy still answers for the menus, unchanged.
    #expect(model.registry.connector(id: "weather") is WeatherConnector)
    await model.teardown()
}

// A clock this model has no factory for — every hand-wired test, and the VPN
// tile, which is not a `Connector` at all — falls back to the app-level
// registry rather than answering nothing.
@Test @MainActor func aClockWithNoFactoryFallsBackToTheAppLevelRegistry() async {
    let model = testModel(
        connectors: [weatherConnector(over: SkyAndClockTransport(sky: skyWithAnswers))],
        clocks: [desk]
    )

    #expect(model.connector(for: TileKey(clockId: desk.id, connectorId: "weather")) != nil)
    #expect(model.connector(for: TileKey(clockId: desk.id, connectorId: "nobody")) == nil)
    await model.teardown()
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
    // On a TC002, because the humidity is a TC002 answer: the AWTRIX face is
    // the temperature and its sky icon, and nothing about humidity reaches
    // it. The preview used to draw the TC002 canvas for BOTH models, so this
    // flipped on an AWTRIX tile too — and that was the preview lying about
    // the clock it named underneath itself.
    let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.7")
    let transport = SkyAndClockTransport(sky: skyWithAnswers)
    let key = TileKey(clockId: kitchen.id, connectorId: "weather")
    let model = testModel(
        connectors: [weatherConnector(over: transport), StubConnector(isAudible: false)],
        transport: transport,
        clocks: [kitchen],
        tiles: [
            TileRecord(
                key: key,
                policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600),
                config: .weather(WeatherTileConfig(place: aDesk))
            )
        ]
    )
    let subject = TileSettingsModel(model: model, debounce: 0)

    model.openDetail(for: key)
    #expect(await waitUntil { subject.preview != nil })
    let withHumidity = subject.preview

    subject.setShowHumidity(false)
    #expect(await waitUntil { subject.preview != nil && subject.preview != withHumidity })
    await model.teardown()
}

// The other half of the same fact: an AWTRIX tile previews the AWTRIX face,
// which is 32×8 and not the TC002's 52×16. The GIF says which panel it is for
// in its own screen descriptor, so the check is on the bytes rather than on a
// picture nobody can compare.
@Test @MainActor func anAwtrixTilePreviewsTheAwtrixPanelNotTheTC002s() async {
    let (model, _) = weatherModel(tiles: [weatherTile(on: desk)])
    let subject = TileSettingsModel(model: model, debounce: 0)

    model.openDetail(for: TileKey(clockId: desk.id, connectorId: "weather"))
    #expect(await waitUntil { subject.preview != nil })

    let bytes = [UInt8](subject.preview ?? Data())
    // "GIF89a", then width low/high and height low/high.
    #expect(bytes.count > 10)
    #expect(bytes[6] == UInt8(AwtrixScene.panelWidth) && bytes[7] == 0)
    #expect(bytes[8] == UInt8(AwtrixScene.panelHeight) && bytes[9] == 0)
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

// A control that has been touched has been saved. Every other tile's
// controls work that way — the Claude metric, all four of the lamp's
// pickers — and the weather's did not: its units, its two answers and its
// place only moved a draft, the preview redrew at once and looked applied,
// and closing the window threw the lot away without a word.
@Test @MainActor func aFlippedControlIsWrittenWithoutASaveButton() async {
    let (model, _) = weatherModel(tiles: [weatherTile(on: desk)])
    let subject = TileSettingsModel(model: model, debounce: 0)
    let key = TileKey(clockId: desk.id, connectorId: "weather")
    model.openDetail(for: key)
    #expect(await waitUntil { subject.key == key })

    subject.setShowHumidity(false)

    #expect(
        await waitUntil { model.storedTile(key)?.config?.weatherConfig?.showsHumidity == false }
    )
    // And so is the scale, and so is the place — one rule for the whole
    // block rather than one control that persists and three that do not.
    subject.setUnits(.fahrenheit)
    #expect(await waitUntil { model.storedTile(key)?.config?.weatherConfig?.units == .fahrenheit })
    #expect(subject.savePlace("55.7558, 37.6173"))
    #expect(
        await waitUntil {
            model.storedTile(key)?.config?.weatherConfig?.place.latitude == 55.7558
        }
    )
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

// MARK: - The refusals the window used to swallow

// Every control wrote `_ = model.saveTile(...)`, and `saveTile` refuses: two
// lamp tiles claiming one corner at the same moment come back with the
// sentence naming the overlap. Dropped on the floor, the control sprang back
// to its old value and the window said nothing — the user's own change undone
// by an invisible hand.
@Test @MainActor func aRefusedSaveIsKeptAndSaidRatherThanDropped() async {
    let lamps = VPNTileMigration.tiles(on: desk.id)
    let (model, _) = weatherModel(tiles: lamps)
    let subject = TileSettingsModel(model: model, debounce: 0)
    let amnezia = lamps[1].key
    model.openDetail(for: amnezia)
    #expect(await waitUntil { subject.key == amnezia })

    // Onto the corner Pritunl already lights, in hours that overlap.
    guard var lamp = model.storedTile(amnezia)?.config?.lamp,
        let stored = model.storedPolicy(of: amnezia)
    else {
        Issue.record("the lamp tile lost its config")
        return
    }
    lamp.slot = .topRight
    #expect(subject.save(policy: stored, config: .vpn(lamp)) == false)
    #expect(subject.lastRefusal?.contains("claim the top lamp") == true)
    #expect(model.storedTile(amnezia)?.config?.lamp?.slot == .bottomRight)

    // And a save that goes through takes the reason off screen: a sentence
    // that outlives the question it answered is worse than none.
    #expect(subject.save(policy: stored, config: model.storedTile(amnezia)?.config) == true)
    #expect(subject.lastRefusal == nil)
    await model.teardown()
}

// The Preset picker moves the tile to another key, and the facade follows it
// rather than being left pointed at a tile that no longer exists.
@Test @MainActor func changingTheLampsVPNMovesTheWindowWithIt() async {
    let lamps = VPNTileMigration.tiles(on: desk.id).filter {
        $0.config?.lamp?.vpn == WatchedVPN.pritunl.id
    }
    let (model, _) = weatherModel(tiles: lamps)
    let subject = TileSettingsModel(model: model, debounce: 0)
    model.openDetail(for: lamps[0].key)
    #expect(await waitUntil { subject.key == lamps[0].key })

    #expect(subject.changeLampVPN(to: WatchedVPN.amnezia.id) == true)

    let moved = TileKey(
        clockId: desk.id, connectorId: VPNConnector.id, instance: WatchedVPN.amnezia.id
    )
    #expect(await waitUntil { subject.key == moved })
    #expect(subject.lastRefusal == nil)
    await model.teardown()
}

// MARK: - The TC002 face's settings

// Every one of the face's settings is a control like the scale: the draft
// moves, and the record is written without a save button. Each test moves
// its setting OFF the shipped default, so a setter that wrote nothing — or
// wrote the default back — cannot pass.
@MainActor
private func expectSetterLands(
    _ apply: (TileSettingsModel) -> Void,
    _ read: @escaping (WeatherTileConfig) -> Bool
) async {
    let (model, _) = weatherModel(tiles: [weatherTile(on: desk)])
    let subject = TileSettingsModel(model: model, debounce: 0)
    let key = TileKey(clockId: desk.id, connectorId: "weather")
    model.openDetail(for: key)
    #expect(await waitUntil { subject.key == key })
    #expect(subject.draft.map(read) == false)

    apply(subject)

    #expect(subject.draft.map(read) == true)
    #expect(await waitUntil { model.storedTile(key)?.config?.weatherConfig.map(read) == true })
    await model.teardown()
}

@Test @MainActor func settingTheLayoutIsWritten() async {
    await expectSetterLands({ $0.setLayout(.pages) }, { $0.layout == .pages })
}

@Test @MainActor func settingTheChangeIntervalIsWritten() async {
    await expectSetterLands({ $0.setChangeEvery(5) }, { $0.changeEvery == 5 })
}

@Test @MainActor func settingTheFeelsLikeColourIsWritten() async {
    await expectSetterLands({ $0.setFeelsLikeColour(false) }, { $0.feelsLikeColour == false })
}

@Test @MainActor func settingTheWindLineIsWritten() async {
    await expectSetterLands({ $0.setShowsWind(false) }, { $0.showsWind == false })
}

@Test @MainActor func settingTheWindUnitIsWritten() async {
    await expectSetterLands({ $0.setWindUnit(.milesPerHour) }, { $0.windUnit == .milesPerHour })
}

@Test @MainActor func settingTheHiLoLineIsWritten() async {
    await expectSetterLands({ $0.setShowsHiLo(false) }, { $0.showsHiLo == false })
}

@Test @MainActor func settingTheRainChanceLineIsWritten() async {
    await expectSetterLands({ $0.setShowsRainChance(false) }, { $0.showsRainChance == false })
}

@Test @MainActor func settingTheUVLineIsWritten() async {
    await expectSetterLands({ $0.setShowsUV(true) }, { $0.showsUV == true })
}

@Test @MainActor func settingTheSunEventsLineIsWritten() async {
    await expectSetterLands({ $0.setShowsSunEvents(true) }, { $0.showsSunEvents == true })
}

@Test @MainActor func settingTheHourlyChartIsWritten() async {
    await expectSetterLands({ $0.setShowsHourly(false) }, { $0.showsHourly == false })
}

// A TC002 weather tile previews the face it is sent — `WeatherFace.preview`,
// every frame at its own delay — not the still raster the clock used to get.
// A still is one frame; the face is an animation on a 52×16 panel.
@Test @MainActor func aTC002WeatherTilePreviewsTheAnimatedFace() async {
    let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.7")
    let transport = SkyAndClockTransport(sky: skyWithAnswers)
    let key = TileKey(clockId: kitchen.id, connectorId: "weather")
    let model = testModel(
        connectors: [weatherConnector(over: transport), StubConnector(isAudible: false)],
        transport: transport,
        clocks: [kitchen],
        tiles: [
            TileRecord(
                key: key,
                policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600),
                config: .weather(WeatherTileConfig(place: aDesk))
            )
        ]
    )
    let subject = TileSettingsModel(model: model, debounce: 0)

    model.openDetail(for: key)
    #expect(await waitUntil { subject.preview != nil })

    let played = subject.preview.flatMap(PixelPreviewFrames.init(gif:))
    #expect((played?.images.count ?? 0) > 1)
    #expect(played?.images.first?.width == PixelCanvas.width)
    #expect(played?.images.first?.height == PixelCanvas.height)
    await model.teardown()
}

// A control's change must survive the model ticking underneath it.
//
// The window schedules its render into `scheduled` and then writes the record;
// the subscription that watches the model for the window MOVING to another
// tile cancelled `scheduled` before it checked whether the window had moved at
// all. Both jobs shared one slot, so any publish inside the debounce — and a
// running app publishes constantly: a poll, a reachability answer, a push
// state — killed the render the edit had just asked for, then found the window
// had not moved and did nothing. The suite never saw it because a store write
// alone does not publish.
//
// The layout is the control the user reported it on, and the TC002 is where it
// shows: the face branches on it (`WeatherFace.timeline`), so two layouts are
// two pictures.
@Test @MainActor func aModelTickDoesNotThrowAwayTheRenderAnEditJustAskedFor() async {
    let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.7")
    let key = TileKey(clockId: kitchen.id, connectorId: "weather")
    let transport = SkyAndClockTransport(sky: skyWithAnswers)
    let model = testModel(
        connectors: [weatherConnector(over: transport), StubConnector(isAudible: false)],
        transport: transport,
        clocks: [kitchen],
        tiles: [
            TileRecord(
                key: key,
                policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600),
                config: .weather(WeatherTileConfig(place: aDesk))
            )
        ]
    )
    // A real debounce, so the tick lands while the render is still waiting.
    let subject = TileSettingsModel(model: model, debounce: 0.05)

    model.openDetail(for: key)
    #expect(await waitUntil { subject.preview != nil })
    let before = subject.preview

    subject.setLayout(.pages)
    // The poll, arriving mid-debounce. The window has not moved.
    model.objectWillChange.send()

    #expect(await waitUntil { subject.preview != nil && subject.preview != before })
    await model.teardown()
}

// Every layout takes, and every layout draws its own picture.
//
// Reported from the panel: Pages took, and after it neither Anchor nor Hybrid
// did. One control, three values, and only the first move worked — so the walk
// is all three in a row rather than one flip, which is the only shape that
// catches a value that takes once and then stops.
@Test @MainActor func everyLayoutTakesAndDrawsItsOwnPicture() async {
    let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.7")
    let key = TileKey(clockId: kitchen.id, connectorId: "weather")
    let transport = SkyAndClockTransport(sky: skyWithAnswers)
    let model = testModel(
        connectors: [weatherConnector(over: transport), StubConnector(isAudible: false)],
        transport: transport,
        clocks: [kitchen],
        tiles: [
            TileRecord(
                key: key,
                policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600),
                config: .weather(WeatherTileConfig(place: aDesk))
            )
        ]
    )
    let subject = TileSettingsModel(model: model, debounce: 0.01)

    model.openDetail(for: key)
    #expect(await waitUntil { subject.preview != nil })

    var drawn: [Data] = []
    for layout in [WeatherTileConfig.Layout.pages, .anchor, .hybrid] {
        let before = subject.preview
        subject.setLayout(layout)
        #expect(subject.draft?.layout == layout)
        #expect(await waitUntil { subject.preview != nil && subject.preview != before })
        #expect(model.storedTile(key)?.config?.weatherConfig?.layout == layout)
        drawn.append(subject.preview ?? Data())
    }
    // Three layouts, three pictures: two that draw the same thing would make
    // the walk above pass on a control that does nothing.
    #expect(Set(drawn).count == 3)

    await model.teardown()
}

// A click does not wait out a debounce.
//
// The debounce is there for a control that STREAMS — a drag that would cost a
// render per pixel. Nothing in this window streams: a segmented picker, a
// toggle and a submitted field each move once per gesture, and coalescing one
// move with nothing costs the whole interval before the picture answers. On a
// TC002 weather tile a render is 127-280 ms measured; the shipped 0.12 s was
// adding almost half again on top of every one of them, and the suite had been
// passing `debounce: 0` at nearly every call site to get anything done.
//
// Measured as a DIFFERENCE against a window built with a debounce, so the
// reading does not depend on how loaded the machine running it is: both pay the
// same render, only one pays the wait.
@Test @MainActor func aClickRendersWithoutWaitingOutADebounce() async {
    func timeOneLayoutChange(debounce: TimeInterval?) async -> TimeInterval {
        let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.7")
        let key = TileKey(clockId: kitchen.id, connectorId: "weather")
        let transport = SkyAndClockTransport(sky: skyWithAnswers)
        let model = testModel(
            connectors: [weatherConnector(over: transport), StubConnector(isAudible: false)],
            transport: transport,
            clocks: [kitchen],
            tiles: [
                TileRecord(
                    key: key,
                    policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600),
                    config: .weather(WeatherTileConfig(place: aDesk))
                )
            ]
        )
        // No argument is the SHIPPED construction, as the window makes it.
        let subject = debounce.map { TileSettingsModel(model: model, debounce: $0) }
            ?? TileSettingsModel(model: model)
        model.openDetail(for: key)
        _ = await waitUntil { subject.preview != nil }
        let before = subject.preview
        let started = Date()
        subject.setLayout(.pages)
        _ = await waitUntil({ subject.preview != nil && subject.preview != before }, limit: 5)
        let took = Date().timeIntervalSince(started)
        await model.teardown()
        return took
    }

    let waited = await timeOneLayoutChange(debounce: 1)
    let shipped = await timeOneLayoutChange(debounce: nil)
    // Nearly all of that second must be the window's wait rather than the
    // renderer's work — a slack under the 0.12 s that used to ship, so a window
    // that quietly reinstates it fails here.
    #expect(shipped < waited - 0.91)
}

// MARK: - Choosing a place by name

@MainActor private func aModelOnAWeatherTile() -> (AppModel, TileKey, TileSettingsModel) {
    let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.7")
    let key = TileKey(clockId: kitchen.id, connectorId: "weather")
    let transport = SkyAndClockTransport(sky: skyWithAnswers)
    let model = testModel(
        connectors: [weatherConnector(over: transport), StubConnector(isAudible: false)],
        transport: transport,
        clocks: [kitchen],
        tiles: [
            TileRecord(
                key: key,
                policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600),
                config: .weather(WeatherTileConfig(place: aDesk))
            )
        ]
    )
    return (model, key, TileSettingsModel(model: model))
}

// A row picked in the search carries its name across with its coordinates.
// The name is the whole reason the search is there: a pair of numbers is not
// a place anybody can check.
@Test @MainActor func choosingAPlaceKeepsTheNameItWasChosenBy() async {
    let (model, key, subject) = aModelOnAWeatherTile()
    model.openDetail(for: key)
    // The window lands on the tile a tick after the model publishes, and the
    // draft is loaded there.
    #expect(await waitUntil { subject.draft != nil })

    subject.choosePlace(PlaceCandidate(
        id: 524_901, name: "Москва", region: "Москва", country: "Россия",
        coordinates: Coordinates(latitude: 55.7558, longitude: 37.6173)
    ))

    #expect(subject.draft?.placeName == "Москва")
    #expect(subject.draft?.placeCountry == "Россия")
    #expect(subject.draft?.place.latitude == 55.7558)
    let stored = model.storedTile(key)?.config?.weatherConfig
    #expect(stored?.placeName == "Москва")
    #expect(stored?.place.longitude == 37.6173)

    await model.teardown()
}

// Typing a pair over a chosen place DROPS the name. A name kept beside
// coordinates it no longer describes is the one way this surface could say
// Moscow over a reading from somewhere else entirely.
@Test @MainActor func typingAPairOverAChosenPlaceForgetsItsName() async {
    let (model, key, subject) = aModelOnAWeatherTile()
    model.openDetail(for: key)
    // The window lands on the tile a tick after the model publishes, and the
    // draft is loaded there.
    #expect(await waitUntil { subject.draft != nil })
    subject.choosePlace(PlaceCandidate(
        id: 1, name: "Москва", region: nil, country: "Россия",
        coordinates: Coordinates(latitude: 55.7558, longitude: 37.6173)
    ))

    #expect(subject.savePlace("51.5074, -0.1278"))

    #expect(subject.draft?.placeName == nil)
    #expect(subject.draft?.placeCountry == nil)
    #expect(subject.draft?.place.latitude == 51.5074)
    #expect(model.storedTile(key)?.config?.weatherConfig?.placeName == nil)

    await model.teardown()
}

// What the surface says over the box, straight off the draft — so the line and
// the reading behind it cannot disagree.
@Test @MainActor func theLineOverTheBoxSaysTheDraftsOwnPlace() async {
    let (model, key, subject) = aModelOnAWeatherTile()
    model.openDetail(for: key)
    // The window lands on the tile a tick after the model publishes, and the
    // draft is loaded there.
    #expect(await waitUntil { subject.draft != nil })

    subject.choosePlace(PlaceCandidate(
        id: 1, name: "London", region: nil, country: "United Kingdom",
        coordinates: Coordinates(latitude: 51.5074, longitude: -0.1278)
    ))

    #expect(subject.placeHeadline == "United Kingdom, London (51.5074, -0.1278)")

    #expect(subject.savePlace("55.7558, 37.6173"))
    #expect(subject.placeHeadline == "55.7558, 37.6173")

    await model.teardown()
}
