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
    /// Why the last save did not happen, or nil when it did.
    ///
    /// Every control in the window used to write `_ = model.saveTile(...)`,
    /// and `saveTile` refuses: two lamp tiles claiming one corner at the same
    /// moment come back with the sentence naming the overlap. Discarded, the
    /// control sprang back to its old value with nothing said — the user's
    /// own change, undone by an invisible hand.
    private(set) var lastRefusal: String?

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
            self.lastRefusal = nil
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
    /// parser.
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
        saveConfig()
    }

    /// Writes the draft into the tile's record — the save the controls
    /// accumulate towards. The policy the record already carries goes
    /// through untouched.
    func saveConfig() {
        guard let key, let draft else { return }
        save(
            policy: model.storedPolicy(of: key) ?? TileDefaults.weather,
            config: .weather(draft)
        )
    }

    // MARK: - The saves every control funnels through

    /// One tile's save, with the model's answer kept rather than dropped.
    ///
    /// Every control in the window writes through here — the policy editor,
    /// the Claude metric, the lamp's four pickers — so a refusal is said once
    /// in one place instead of once per control, or, as it was, never.
    @discardableResult
    func save(policy: TilePolicy, config: TileConfig?) -> Bool {
        guard let key else { return false }
        switch model.saveTile(key: key, policy: policy, config: config) {
        case .saved:
            lastRefusal = nil
            return true
        case let .refused(reason):
            lastRefusal = reason
            return false
        }
    }

    /// The lamp block's Preset picker: a move to the key the new VPN names.
    @discardableResult
    func changeLampVPN(to vpnId: String) -> Bool {
        guard let key else { return false }
        switch model.changeLampVPN(key, to: vpnId) {
        case .saved:
            lastRefusal = nil
            return true
        case let .refused(reason):
            lastRefusal = reason
            return false
        }
    }

    /// Takes a refusal off screen — the window calls it when the tile it is
    /// open on changes, so a reason never outlives the tile that earned it.
    func clearRefusal() {
        lastRefusal = nil
    }

    /// A control moved: the draft changes, the preview follows, and the
    /// record is written.
    ///
    /// The write is the part that was missing, and its absence was the
    /// window's worst lie. Every other tile's controls save as they are
    /// touched — the Claude metric, all four of the lamp's pickers — while
    /// the weather's units, its two answers and even its place only moved a
    /// draft. The preview redrew at once and looked applied; closing the
    /// window threw the lot away without a word. One small "Save settings"
    /// button at the bottom of the column stood between the user and every
    /// change they had already watched happen.
    ///
    /// The draft stays, and is still what the preview reads: it is what lets
    /// a publish from elsewhere leave a half-finished edit alone. It is no
    /// longer the only place the edit lives.
    private func edit(_ change: (inout WeatherTileConfig) -> Void) {
        guard draft != nil else { return }
        draft?.mutating(change)
        schedulePreview()
        saveConfig()
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
            // The connector the tile's OWN clock runs, not the app-level copy
            // the menus are named from: that one is wired inert — z.ai with no
            // key, Claude with no metric, the weather closed over the FIRST
            // clock's place — so every preview drawn through it was about a
            // tile nobody has.
            let connector = self.model.connector(for: key)
            let draft = self.draft
            let lamp = self.model.storedTile(key)?.config?.lamp
            let clockModel = self.model.clocks.first { $0.id == key.clockId }?.model ?? .awtrix3
            let rendered = await Task.detached(priority: .userInitiated) { () -> Rendered in
                await Self.render(
                    connector: connector, draft: draft, lamp: lamp, on: clockModel
                )
            }.value
            // A change that landed while this render ran has moved the
            // generation; its own render is the one that shows.
            guard self.generation == thisGeneration else { return }
            preview = rendered.gif
            previewNote = rendered.note
        }
    }

    /// A render's two answers: the picture, or the reason there is none.
    private struct Rendered: Sendable {
        let gif: Data?
        let note: String?

        static func picture(_ frames: [PixelCanvas], delay: TimeInterval) -> Rendered {
            guard frames.isEmpty == false else {
                return Rendered(gif: nil, note: "This tile draws nothing on this clock.")
            }
            guard let gif = try? FullFrameGif.encode(frames: frames, delay: delay) else {
                return Rendered(gif: nil, note: "The face could not be encoded.")
            }
            return Rendered(gif: gif, note: nil)
        }

        static func nothing(_ note: String) -> Rendered { Rendered(gif: nil, note: note) }
    }

    /// How long one frame of a scroll is shown. The firmware walks a line
    /// across the panel at about this rate, and a preview that played it at
    /// reading speed would be a different animation from the clock's.
    private static let scrollFrameDelay: TimeInterval = 0.08
    /// A still face's frame delay. Any value plays the same; this one keeps
    /// the GIF's own timing honest rather than claiming a frame rate.
    private static let stillFrameDelay: TimeInterval = 5

    /// The face, drawn for the clock the tile actually sits on.
    ///
    /// Off the main actor, and static so it cannot reach the facade's state:
    /// everything it needs is handed in, which is what lets the render run
    /// while the window keeps answering.
    private static func render(
        connector: (any Connector)?, draft: WeatherTileConfig?, lamp: VPNTileConfig?,
        on clockModel: ClockModel
    ) async -> Rendered {
        guard let connector else {
            // The VPN tile is the one that lands here: it is a lamp on the
            // clock's corner, not a page, and it is not a `Connector` at all.
            // Said in words rather than drawn, and that is deliberate — the
            // indicator LEDs sit outside the 32×8 matrix, so a picture of
            // them would be a geometry this app invented. A sentence about
            // what the corner will do is the honest preview of a lamp.
            return .nothing(LampPreviewLine.text(for: lamp))
        }

        // The weather draws the DRAFT — the place, the scale and the two
        // answers as the controls have them this second — through the same
        // functions a poll draws with.
        if let draft, let weather = connector as? WeatherConnector {
            guard let reading = try? await weather.reading(at: draft.place) else {
                return .nothing("The sky could not be read — check the connection.")
            }
            switch clockModel {
            case .ulanziTC002:
                return .picture(
                    [WeatherConnector.canvas(for: reading, config: draft)], delay: stillFrameDelay
                )
            case .awtrix3:
                return frames(
                    of: WeatherConnector.output(for: reading, config: draft).scene
                )
            }
        }

        switch clockModel {
        case .ulanziTC002:
            guard let delivery = try? await connector.previewUlanzi() else {
                return .nothing("The tile could not be read — check its key and connection.")
            }
            guard let frame = delivery.scene.frames.first else {
                return .nothing("This tile draws no page on a TC002.")
            }
            var canvas = PixelCanvas()
            canvas.apply(frame.draw)
            return .picture([canvas], delay: stillFrameDelay)
        case .awtrix3:
            guard let delivery = try? await connector.preview() else {
                return .nothing("The tile could not be read — check its key and connection.")
            }
            return frames(of: delivery.scene)
        }
    }

    /// An AWTRIX scene as the clock plays it: one frame when the line fits,
    /// the frames of the firmware's scroll when it does not.
    private static func frames(of scene: AwtrixScene) -> Rendered {
        let drawn = scene.canvasFrames()
        return .picture(drawn, delay: drawn.count > 1 ? scrollFrameDelay : stillFrameDelay)
    }
}

private extension WeatherTileConfig {
    mutating func mutating(_ change: (inout WeatherTileConfig) -> Void) {
        change(&self)
    }
}
