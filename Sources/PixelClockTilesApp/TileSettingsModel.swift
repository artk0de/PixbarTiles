import Combine
import Foundation
import Observation
import PixelClockKit

/// The tile settings window's facade: the tile it is opened for, the weather
/// draft its controls edit, and the preview those controls flip.
///
/// The preview is THE FACE, not a drawing of it: the connector reads the sky
/// and the same `canvas(for:config:)` the device push draws encodes to a GIF
/// through the kit's own writer, so the pixels on screen are the pixels a
/// poll would send. What makes that affordable is the debounce — every
/// control change costs a render — and what makes it honest is that the
/// draft, not the stored config, feeds it: the preview cannot show what the
/// tile is not about to become.
@MainActor
@Observable
final class TileSettingsModel {
    private let model: AppModel
    /// How long a control change waits before it costs a render.
    private let debounce: TimeInterval
    /// The subscription that hears which tile the window is for.
    private var pulse: AnyCancellable?
    /// The render waiting out the debounce, and the generation it belongs to
    /// — a cancelled render's answer is dropped, not shown late.
    private var scheduled: Task<Void, Never>?
    private var generation = 0

    /// The tile the window is opened for, mirrored from the model.
    private(set) var key: TileKey?
    /// The weather draft the controls edit, or nil for a tile that is not a
    /// weather tile. Saved explicitly; the preview answers the draft, not
    /// the record.
    private(set) var draft: WeatherTileConfig?
    /// The preview as GIF bytes — the kit writer's own output, shown at the
    /// panel's scale.
    private(set) var preview: Data?
    /// Why there is no preview, when the reason is more than "nothing was
    /// rendered yet": a connector that cannot be read (a key missing, a feed
    /// down) says so rather than leaving a blank a reader reads as breakage.
    private(set) var previewNote: String?

    init(model: AppModel, debounce: TimeInterval = 0.12) {
        self.model = model
        self.debounce = debounce
        key = model.detailTileKey
        loadDraft()
        pulse = model.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.tileChangedAfterTheChangeLands() }
        }
    }

    /// The stored config, as the draft starts from it. A tile that is not a
    /// weather tile has no draft: its controls are not this facade's.
    private func loadDraft() {
        guard let key, key.connectorId == WeatherConnector.appName,
            let stored = model.storedTile(key)
        else {
            draft = nil
            return
        }
        draft = stored.config?.weatherConfig ?? WeatherTileConfig(place: .default)
    }

    private func tileChangedAfterTheChangeLands() {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            guard let self else { return }
            // Reload only when the WINDOW moved to another tile: the model
            // publishes for every tile in the app, and a tick elsewhere must
            // not throw away the draft a hand is mid-way through.
            let landed = self.model.detailTileKey
            guard landed != self.key else { return }
            self.key = landed
            self.loadDraft()
            self.preview = nil
            self.schedulePreview()
        }
    }

    // MARK: - The draft's controls

    func setUnits(_ units: WeatherTileConfig.Units) {
        edit { $0.units = units }
    }

    func setShowHumidity(_ shown: Bool) {
        edit { $0.showsHumidity = shown }
    }

    func setShowFeelsLike(_ shown: Bool) {
        edit { $0.showsFeelsLike = shown }
    }

    /// Saves the draft's place, said in words, through the field's own
    /// parser. The one control that saves as it goes, because the place is
    /// the one control the field's Save button has always stood behind.
    @discardableResult
    func savePlace(_ typed: String) -> Bool {
        guard let typed = LocationField.parse(typed) else { return false }
        edit { $0.place = typed }
        return true
    }

    /// The draft back to the shipped defaults, the place kept — where the
    /// clock stands is not a setting anyone resets. The preview follows, so
    /// the reset is visible at once.
    func resetToDefaults() {
        guard let place = draft?.place else { return }
        draft = WeatherTileConfig(place: place)
        schedulePreview()
    }

    /// Writes the draft into the tile's record — the save the controls
    /// accumulate towards. The policy the record already carries goes
    /// through untouched.
    func saveConfig() {
        guard let key, let draft else { return }
        _ = model.saveTile(key: key, policy: model.storedPolicy(of: key) ?? TileDefaults.weather, config: .weather(draft))
    }

    private func edit(_ change: (inout WeatherTileConfig) -> Void) {
        guard draft != nil else { return }
        draft?.mutating(change)
        schedulePreview()
    }

    // MARK: - The preview

    /// One control change, one render — coalesced by the debounce: the
    /// scheduled render is cancelled and a later one takes its place, so
    /// dragging through three answers in a row costs the last one only.
    ///
    /// The weather is the one tile whose preview answers the DRAFT rather
    /// than the record — its controls edit a draft, and a preview that read
    /// the record would show what the tile is, not what it is about to
    /// become. Every other tile has no draft, and its preview is its face:
    /// the connector's own delivery for the model of the clock the tile sits
    /// on, drawn by the kit's rasterizers, encoded by the kit's writer.
    private func schedulePreview() {
        generation += 1
        let thisGeneration = generation
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(self.debounce))
            } catch { return }
            guard self.generation == thisGeneration, let key = self.key else { return }
            self.previewNote = nil
            let connector = self.model.registry.connector(id: key.connectorId)
            let draft = self.draft
            let clockModel = self.model.clocks.first { $0.id == key.clockId }?.model
            let isWeather = key.connectorId == WeatherConnector.appName
            let bytes = await Task.detached(priority: .userInitiated) { () -> (Data?, String?) in
                guard let connector else { return (nil, nil) }
                if isWeather, let draft, let weather = connector as? WeatherConnector {
                    guard let reading = try? await weather.read() else {
                        return (nil, "The sky could not be read — check the connection.")
                    }
                    let canvas = WeatherConnector.canvas(for: reading, config: draft)
                    return ((try? FullFrameGif.encode(frames: [canvas], delay: 5)), nil)
                }
                switch clockModel {
                case .ulanziTC002:
                    guard let delivery = try? await connector.produceUlanzi(),
                        let frame = delivery.scene.frames.first
                    else { return (nil, "This connector draws no face for a TC002.") }
                    var canvas = PixelCanvas()
                    canvas.apply(frame.draw)
                    return ((try? FullFrameGif.encode(frames: [canvas], delay: 5)), nil)
                case .awtrix3, nil:
                    guard let delivery = try? await connector.produce()
                    else {
                        return (
                            nil, "The tile could not be read — check its key and connection."
                        )
                    }
                    return (
                        try? FullFrameGif.encode(frames: [delivery.scene.canvas()], delay: 5), nil
                    )
                }
            }.value
            // A change that landed while this render ran has moved the
            // generation; its own render is the one that shows.
            guard self.generation == thisGeneration else { return }
            preview = bytes.0
            previewNote = bytes.1
        }
    }
}

private extension WeatherTileConfig {
    mutating func mutating(_ change: (inout WeatherTileConfig) -> Void) {
        change(&self)
    }
}
