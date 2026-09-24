import Combine
import Foundation
import Observation
import PixelClockKit

/// The tile settings window's facade: the tile it is opened for, the weather
/// draft its controls edit, and the preview those controls flip.
///
/// The preview is THE FACE, not a drawing of it: the connector reads the sky
/// and the same `WeatherFace` timeline the device push ships encodes to a GIF
/// through the kit's own writer, so the pixels on screen are the pixels a
/// poll would send. Every control change costs a render, started the moment
/// the control moves; what makes it honest is that the draft, not the stored
/// config, feeds it, so the preview cannot show what the tile is not about to
/// become.
@MainActor
@Observable
final class TileSettingsModel {
    private let model: AppModel
    /// How long a control change waits before it costs a render. Zero in the
    /// app, and that is the shipped answer rather than an oversight: see
    /// `schedulePreview`.
    private let debounce: TimeInterval
    /// The subscription that hears which tile the window is for.
    private var pulse: AnyCancellable?
    /// The render waiting out the debounce, and the generation it belongs to
    /// — a cancelled render's answer is dropped, not shown late.
    private var scheduled: Task<Void, Never>?
    private var generation = 0
    /// What a pair of coordinates is called, when the record does not say.
    private let naming: any PlaceNaming
    /// The lookup in flight, so a place that moves twice is asked about once.
    private var named: Task<Void, Never>?
    /// The look at whether the WINDOW has moved to another tile.
    ///
    /// Its own slot, and that is a fix rather than a tidy. It used to share
    /// `scheduled` with the render, and it cancels before it checks: so every
    /// publish from the model — a poll, a reachability answer, a push state,
    /// several a second in a running app — killed whatever render an edit had
    /// just asked for, then found the window had not moved and did nothing.
    /// Flipping a control wrote the record and left the preview showing the
    /// answer before it.
    private var reload: Task<Void, Never>?

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

    init(
        model: AppModel,
        debounce: TimeInterval = 0,
        // Named nothing by default, so no test and no surface goes to a
        // geocoder without saying so. The app passes the real one.
        naming: any PlaceNaming = NoPlaceNaming()
    ) {
        self.model = model
        self.debounce = debounce
        self.naming = naming
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
        nameThePlaceIfItHasNone()
    }

    /// Asks what the draft's coordinates are CALLED, and keeps the answer.
    ///
    /// Only when the record does not already say. The answer is saved onto
    /// the tile rather than held here, so a tile is named once: Apple's
    /// geocoder rate-limits per app, and a window opened twice must not cost
    /// two lookups of a place that has not moved.
    ///
    /// Silent on failure by design. A name is an improvement on a surface
    /// that works without one — the headline falls back to the numbers — and
    /// a lookup nobody asked for has no business raising anything.
    private func nameThePlaceIfItHasNone() {
        guard let draft, draft.placeName == nil, draft.placeCountry == nil else { return }
        let place = draft.place
        named?.cancel()
        named = Task { [weak self] in
            guard let self else { return }
            let found = await self.naming.name(of: place)
            guard found.name != nil || found.country != nil else { return }
            // The place may have moved while the answer was in the air — a
            // name written over coordinates it does not describe is the one
            // failure this whole field exists to avoid.
            guard self.draft?.place == place else { return }
            self.edit {
                $0.placeName = found.name
                $0.placeCountry = found.country
            }
        }
    }

    private func tileChangedAfterTheChangeLands() {
        reload?.cancel()
        reload = Task { [weak self] in
            guard let self else { return }
            // Reload only when the WINDOW moved to another tile: the model
            // publishes for every tile in the app, and a tick elsewhere must
            // not throw away the draft a hand is mid-way through — nor the
            // render that draft just asked for, which is what cancelling the
            // shared slot up here used to do.
            let landed = self.model.detailTileKey
            guard landed != self.key else { return }
            self.key = landed
            self.loadDraft()
            self.preview = nil
            self.lastRefusal = nil
            // The render IS dropped when the window really moved — by
            // `schedulePreview`'s own cancel, where it belongs.
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

    // The TC002 face's settings — the same edit as the scale: the draft
    // moves, the preview follows, the record is written.

    func setLayout(_ layout: WeatherTileConfig.Layout) {
        edit { $0.layout = layout }
    }

    func setChangeEvery(_ seconds: TimeInterval) {
        edit { $0.changeEvery = seconds }
    }

    func setFeelsLikeColour(_ felt: Bool) {
        edit { $0.feelsLikeColour = felt }
    }

    func setShowsWind(_ shown: Bool) {
        edit { $0.showsWind = shown }
    }

    func setWindUnit(_ unit: WindUnit) {
        edit { $0.windUnit = unit }
    }

    func setShowsHiLo(_ shown: Bool) {
        edit { $0.showsHiLo = shown }
    }

    func setShowsRainChance(_ shown: Bool) {
        edit { $0.showsRainChance = shown }
    }

    func setShowsUV(_ shown: Bool) {
        edit { $0.showsUV = shown }
    }

    func setShowsSunEvents(_ shown: Bool) {
        edit { $0.showsSunEvents = shown }
    }

    func setShowsMoon(_ shown: Bool) {
        edit { $0.showsMoon = shown }
    }

    func setShowsHourly(_ shown: Bool) {
        edit { $0.showsHourly = shown }
    }

    /// Saves the draft's place, said in numbers, through the field's own
    /// parser.
    ///
    /// The name goes with it. A pair typed by hand describes somewhere the
    /// stored name may know nothing about, and a name left beside coordinates
    /// it no longer fits is the one way this surface could say Moscow over a
    /// reading from London.
    @discardableResult
    func savePlace(_ typed: String) -> Bool {
        guard let typed = LocationField.parse(typed) else { return false }
        edit {
            $0.place = typed
            $0.placeName = nil
            $0.placeCountry = nil
        }
        // And named again from the new numbers, so the line over the box
        // describes where the reading is FROM whichever way the place got
        // there.
        nameThePlaceIfItHasNone()
        return true
    }

    /// Saves a place CHOSEN from the search, name and all.
    ///
    /// Through the same `edit` a typed pair goes through, so choosing a row
    /// costs exactly the render and the save that typing does — this is a
    /// typing aid, not a second way into the record.
    func choosePlace(_ candidate: PlaceCandidate) {
        edit {
            $0.place = candidate.coordinates
            $0.placeName = candidate.name
            $0.placeCountry = candidate.country
        }
    }

    /// Where the clock is, as the surface says it over the box: the country,
    /// the city, and the numbers behind them. Read off the DRAFT, so the line
    /// and the reading under it cannot disagree.
    var placeHeadline: String {
        guard let draft else { return "" }
        return LocationField.headline(
            name: draft.placeName, country: draft.placeCountry, place: draft.place
        )
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

    // MARK: - The usage face's settings

    /// The shared usage face's two settings as the tile has them, or nil for
    /// a tile that does not draw that face. A Claude or z.ai tile with no
    /// config yet — a z.ai tile nobody pasted a key into — is at the defaults.
    var parameters: CodeUsage.Parameters? {
        guard let key, Self.isCodeUsageTile(key) else { return nil }
        return model.storedTile(key)?.config?.parameters ?? .standard
    }

    /// Writes the usage face's settings into the tile's record, keeping what
    /// else the record says — the Claude metric, the z.ai key handle. The
    /// preview follows, so the new timing is on screen at once.
    func setParameters(_ parameters: CodeUsage.Parameters) {
        guard let key, Self.isCodeUsageTile(key) else { return }
        let stored = model.storedTile(key)?.config
        let config: TileConfig = switch key.connectorId {
        case ClaudeUsageConnector.id:
            .claude(ClaudeTileConfig(parameters: parameters))
        default:
            // The handle is DERIVED, never minted: a tile tuned before its
            // key was pasted names the account the key will be filed under.
            .zai(ZaiTileConfig(
                keyAccount: stored?.key?.keyAccount ?? ZaiTileConfig.account(for: key),
                parameters: parameters
            ))
        }
        guard save(policy: model.storedPolicy(of: key) ?? TileDefaults.codeUsage, config: config)
        else { return }
        schedulePreview()
    }

    /// The GitHub block's save: the short name and the celebration length.
    /// The repository is kept as stored whatever the edit says — it is the
    /// tile's identity — and a blank short name is no short name.
    func setGitHubConfig(_ edited: GitHubTileConfig) {
        guard let key, key.connectorId == GitHubConnector.connectorId,
            let policy = model.storedPolicy(of: key)
        else { return }
        var config = edited
        config.repo = model.storedTile(key)?.config?.github?.repo ?? key.instance
        let shortName = edited.shortName?.trimmingCharacters(in: .whitespaces)
        config.shortName = shortName?.isEmpty == false ? shortName : nil
        guard save(policy: policy, config: .github(config)) else { return }
        schedulePreview()
    }

    /// Keyed on the connector id, like the lamp block: the settings are the
    /// tile's, whatever instance is running it.
    private static func isCodeUsageTile(_ key: TileKey) -> Bool {
        key.connectorId == ClaudeUsageConnector.id
            || key.connectorId == ZaiUsageConnector.connectorId
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

    /// One control change, one render, started at once.
    ///
    /// The debounce it used to wait out bought nothing. It is there for a
    /// control that STREAMS — a drag costing a render per pixel — and nothing
    /// in this window streams: a segmented picker, a toggle and a submitted
    /// field each move once per gesture. Coalescing one move with nothing cost
    /// the whole interval before the picture answered, on top of a render
    /// measured at 127-280 ms for the TC002 weather face. A burst still
    /// coalesces without it: a later render cancels the one before it and the
    /// generation drops a late answer. The suite had been passing
    /// `debounce: 0` at nearly every call site to get anything done, which was
    /// the reading to believe.
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
            if self.debounce > 0 {
                do {
                    try await Task.sleep(for: .seconds(self.debounce))
                } catch { return }
            }
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
            picture(frames, delays: Array(repeating: delay, count: frames.count))
        }

        /// A timeline whose frames each carry their own delay.
        static func picture(_ frames: [PixelCanvas], delays: [TimeInterval]) -> Rendered {
            guard frames.isEmpty == false else {
                return Rendered(gif: nil, note: "This tile draws nothing on this clock.")
            }
            guard let gif = try? FullFrameGif.encode(frames: frames, delays: delays) else {
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
                // The face the clock is sent, as one sequence — Anchor's two
                // loops merged — every frame at its own delay, played the way
                // the usage face's GIF is.
                let frames = WeatherFace.preview(
                    reading: reading, config: draft, now: Date(), timeZone: .current
                )
                return .picture(
                    frames.map(\.canvas),
                    delays: frames.map { TimeInterval($0.milliseconds) / 1000 }
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
            // A page that ships as ONE full-panel GIF — the usage face's
            // timeline — previews as that GIF: the very bytes the clock is
            // sent, every frame with its own delay, not a redraw of them.
            if frame.draw.isEmpty, frame.image.count == 1, let image = frame.image.first,
                image.position.x == 0, image.position.y == 0,
                let gif = Data(base64Encoded: image.base64)
            {
                return Rendered(gif: gif, note: nil)
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
