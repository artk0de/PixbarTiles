import AppKit
import PixelClockKit
import SwiftUI

/// The tile settings window: one window whose content swaps, because ten open
/// tile windows is not a state worth supporting. The tile it is opened for is
/// the model's `detailTileKey`, and the window follows it — raised when a row
/// asks, re-targeted when another one does.
///
/// Controls on the left, the clock on the right. The preview is THE FACE —
/// the connector's reading drawn by the same canvas code the push draws,
/// encoded by the kit's own writer — so what the controls flip cannot be a
/// lie about what the clock would show.
struct TileSettingsWindow: View {
    @ObservedObject var model: AppModel
    let settings: TileSettingsModel
    private let claudeCode: () -> ClaudeCodeLinkModel
    /// Which half of the settings is showing: what makes THIS tile special,
    /// or the rules every tile shares.
    @State private var section: Section = .tile
    /// Whether the anecdote history is up over this window.
    ///
    /// A sheet here and a panel swap there, over one `HistoryList`. The
    /// comment on the panel's side — that a sheet vanishes when its host
    /// loses focus — is true of a menu bar extra's window and of nothing
    /// else: this is an ordinary window, and a sheet on it stays up.
    @State private var showingHistory = false

    enum Section: String, CaseIterable, Identifiable {
        case tile
        case common

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tile: "Tile"
            case .common: "Common"
            }
        }
    }

    init(
        model: AppModel,
        settings: TileSettingsModel,
        claudeCode: @autoclosure @escaping () -> ClaudeCodeLinkModel = ClaudeCodeLinkModel()
    ) {
        self.model = model
        self.settings = settings
        self.claudeCode = claudeCode
    }

    var body: some View {
        if let key = model.detailTileKey,
            let value = model.detailValue(for: key),
            let stored = model.storedPolicy(of: key)
        {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(value.name) · \(clockName(of: key))").font(.headline)
                    Picker("Section", selection: $section) {
                        ForEach(Section.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch section {
                    case .tile:
                        connectorBlock(for: key, value: value)
                    case .common:
                        TilePolicyEditor(policy: Binding(
                            get: { stored },
                            set: { settings.save(policy: $0, config: value.config) }
                        ))
                    }
                    // What the model said no to, under the controls that
                    // asked. Two lamp tiles claiming one corner at the same
                    // moment is the refusal a person actually meets, and it
                    // used to be discarded: the picker sprang back and the
                    // window said nothing at all.
                    if let refusal = settings.lastRefusal {
                        Label(refusal, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .frame(width: 250, alignment: .leading)
                Divider()
                previewColumn
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // A floor, as the other three windows have. This branch had
            // none: the controls column is a fixed 250 and the preview is a
            // fixed panel, so dragging the window narrower clipped one of
            // them off rather than laying them out smaller. The number is
            // what the two columns, the divider and the padding come to.
            .frame(minWidth: 560, minHeight: 320)
            .glassWindow()
            .sheet(isPresented: $showingHistory) { historySheet }
            // The window going away is the detail closing: the panel's
            // branch sees nil the next time it asks, and the facade's draft
            // is dropped with it.
            .onDisappear { model.closeDetail() }
        } else {
            // Said the way the other windows say it, and carrying the same
            // material. It was a bare `Text` in a fixed 320×160 box with no
            // background at all, so the one window that could be opened
            // unaimed was also the one that stopped looking like the app.
            ContentUnavailableView(
                "No tile selected",
                systemImage: "square.dashed",
                description: Text("Open it from a tile's gear in the clock's settings.")
            )
            .frame(minWidth: 360, minHeight: 220)
            .glassWindow()
        }
    }

    private func clockName(of key: TileKey) -> String {
        model.clocks.first { $0.id == key.clockId }?.name ?? ""
    }

    /// What has played, over the tile that plays it.
    ///
    /// The same `HistoryList` the panel swaps in — one list, two hosts. The
    /// height is fixed rather than the panel's stored one: that number is a
    /// size somebody dragged a menu bar surface to, and it has nothing to say
    /// about a sheet.
    private var historySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("History").font(.headline)
            HistoryList(model: model, height: 320)
            HStack {
                Spacer()
                Button("Done") { showingHistory = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    // MARK: - The controls column

    /// The tile's own block beside the shared policy editor: what this
    /// connector has that no other does. A connector with nothing of its own
    /// draws nothing there.
    @ViewBuilder
    private func connectorBlock(
        for key: TileKey, value: (name: String, config: TileConfig?)
    ) -> some View {
        // The tile's own clock's connector, so the block a tile shows is
        // decided by the instance that actually runs it.
        let connector = model.connector(for: key)
        if connector is WeatherConnector {
            WeatherTileControls(settings: settings)
        } else if connector is AnecdoteConnector {
            AnecdoteTileBlock(onHistory: {
                model.loadHistory()
                showingHistory = true
            })
        } else if connector is ClaudeUsageConnector {
            VStack(alignment: .leading, spacing: 10) {
                ClaudeTileBlock(
                    metric: value.config?.claude ?? .weekly,
                    onMetric: { settings.setClaudeMetric($0) }
                )
                usageFaceBlock
                // Machine-wide state, one file, not a tile's: whatever tile's
                // window it is edited from edits it for every Claude tile.
                ClaudeCodeSettings(link: claudeCode())
            }
        } else if connector is ZaiUsageConnector {
            VStack(alignment: .leading, spacing: 10) {
                ZaiTileBlock(
                    hasKey: model.hasZaiKey(for: key),
                    outcome: model.lastZaiKeyOutcome,
                    onSaveKey: { model.saveZaiKey($0, for: key) }
                )
                usageFaceBlock
            }
        } else if key.connectorId == VPNConnector.id {
            // Keyed on the connector id, not on `connector is VPNConnector`:
            // a lamp tile's connector is built per VPN by the clock's own
            // session, and a tile whose settings are being opened may not
            // have one in hand at all. The block is the tile's, not the
            // running instance's.
            lampBlock(for: key, config: value.config)
        } else {
            EmptyView()
        }
    }

    /// The shared usage face's two pickers — the same block on the Claude
    /// tile and the z.ai tile, because the face they tune is one.
    @ViewBuilder
    private var usageFaceBlock: some View {
        if let usageFace = settings.usageFace {
            UsageFaceBlock(config: usageFace, onChange: { settings.setUsageFace($0) })
        }
    }

    /// The lamp tile's block: which VPN, which corner, which colour, and
    /// what "down" looks like.
    ///
    /// The block itself has existed since the tile did, with its own tests,
    /// and nothing ever built one — so a VPN tile was the one tile in the
    /// app whose settings window had no settings in it.
    @ViewBuilder
    private func lampBlock(for key: TileKey, config: TileConfig?) -> some View {
        if let lamp = config?.lamp {
            VPNTileBlock(
                presets: WatchedVPN.catalogue.map(\.displayName),
                preset: WatchedVPN.preset(id: lamp.vpn)?.displayName ?? lamp.vpn,
                slots: IndicatorSlot.allCases.map(\.lampTitle),
                slot: lamp.slot.lampTitle,
                colour: Color(hex: lamp.upColour),
                downBehaviour: lamp.whenDown == .off ? .off : .blink,
                onPreset: { name in
                    guard let chosen = WatchedVPN.catalogue.first(where: { $0.displayName == name })
                    else { return }
                    settings.changeLampVPN(to: chosen.id)
                },
                onSlot: { title in
                    guard let chosen = IndicatorSlot.allCases.first(where: { $0.lampTitle == title })
                    else { return }
                    saveLamp(lamp, on: key) { $0.slot = chosen }
                },
                onColour: { colour in
                    saveLamp(lamp, on: key) { $0.upColour = colour.hexString }
                },
                onDownBehaviour: { behaviour in
                    saveLamp(lamp, on: key) {
                        switch behaviour {
                        case .off:
                            $0.whenDown = .off
                        case .blink:
                            // Its own colour, kept when there already is one:
                            // a lamp toggled off and back on must not forget
                            // what it blinked.
                            if case .blink = $0.whenDown { break }
                            $0.whenDown = .blink(VPNTilePalette.alarm)
                        }
                    }
                }
            )
        } else {
            // A lamp tile with no lamp on it — a record written before the
            // config existed, or one whose config failed to decode. Says so
            // instead of drawing four pickers over nothing.
            Text("This tile has no lamp settings. Remove it and add it again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveLamp(
        _ lamp: VPNTileConfig, on key: TileKey, _ change: (inout VPNTileConfig) -> Void
    ) {
        guard let stored = model.storedPolicy(of: key) else { return }
        var edited = lamp
        change(&edited)
        settings.save(policy: stored, config: .vpn(edited))
    }

    // MARK: - The preview column

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On the clock").font(.caption).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.black)
                    .strokeBorder(.separator, lineWidth: 1)
                if let data = settings.preview, let frames = PixelPreviewFrames(gif: data) {
                    // Every frame, played at the GIF's own delay: what the
                    // clock does with a line too long for its panel is the
                    // thing the preview is being read for.
                    PixelPreview(frames: frames, scale: Self.previewScale)
                } else {
                    // The facade's own sentence — why there is no picture —
                    // rather than a guess. It used to read "This tile draws no
                    // preview" for every tile that is not the weather, which
                    // was a lie about Claude and z.ai, both of which have
                    // faces and both of which were failing for a reason the
                    // model had already worked out.
                    Text(settings.previewNote ?? "Rendering…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(8)
                }
            }
            .frame(width: previewSize.width, height: previewSize.height)
            if let clock = model.clocks.first(where: { $0.id == model.detailTileKey?.clockId }) {
                Text("\(clock.name) · \(clock.model.spokenName) · \(panelWords(of: clock.model))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// One clock pixel drawn as this many points. Six is what the design
    /// names, and it is the one number both the box and the image use, so an
    /// empty preview and a drawn one are the same size — the window does not
    /// jump when the first render lands.
    private static let previewScale: CGFloat = 6

    /// The box the preview lives in: the clock's own panel, magnified. A
    /// TC002 is 52×16 and an AWTRIX 32×8, so the two are not the same shape
    /// and a fixed box would letterbox one of them.
    private var previewSize: CGSize {
        let panel = panelPixels(of: clockModelOfDetail)
        return CGSize(
            width: panel.width * Self.previewScale, height: panel.height * Self.previewScale
        )
    }

    private var clockModelOfDetail: ClockModel {
        model.clocks.first { $0.id == model.detailTileKey?.clockId }?.model ?? .ulanziTC002
    }

    private func panelPixels(of model: ClockModel) -> CGSize {
        switch model {
        case .ulanziTC002: CGSize(width: PixelCanvas.width, height: PixelCanvas.height)
        case .awtrix3: CGSize(width: AwtrixScene.panelWidth, height: AwtrixScene.panelHeight)
        }
    }

    private func panelWords(of model: ClockModel) -> String {
        let panel = panelPixels(of: model)
        return "\(Int(panel.width))×\(Int(panel.height))"
    }
}

/// The weather tile's controls: the place, and the three answers the spec
/// names — the scale, the humidity, the felt temperature. Each edits the
/// DRAFT and flips the preview as it does; the save is one button, because a
/// half-saved setting is a preview that says one thing and a clock that
/// shows another.
struct WeatherTileControls: View {
    let settings: TileSettingsModel

    var body: some View {
        if let draft = settings.draft {
            VStack(alignment: .leading, spacing: 10) {
                WeatherTileBlock(place: draft.place, onSave: { settings.savePlace($0) })
                Picker("Layout", selection: Binding(
                    get: { draft.layout },
                    set: { settings.setLayout($0) }
                )) {
                    Text("Anchor").tag(WeatherTileConfig.Layout.anchor)
                    Text("Pages").tag(WeatherTileConfig.Layout.pages)
                    Text("Hybrid").tag(WeatherTileConfig.Layout.hybrid)
                }
                .pickerStyle(.segmented)
                Picker("Change every", selection: Binding(
                    get: { draft.changeEvery },
                    set: { settings.setChangeEvery($0) }
                )) {
                    ForEach(Self.changeEverySteps(draft), id: \.self) {
                        Text(UsageFaceBlock.everyCaption($0)).tag($0)
                    }
                }
                Picker("Units", selection: Binding(
                    get: { draft.units },
                    set: { settings.setUnits($0) }
                )) {
                    Text("°C — Celsius").tag(WeatherTileConfig.Units.celsius)
                    Text("°F — Fahrenheit").tag(WeatherTileConfig.Units.fahrenheit)
                }
                Picker("Wind unit", selection: Binding(
                    get: { draft.windUnit },
                    set: { settings.setWindUnit($0) }
                )) {
                    Text("m/s").tag(WindUnit.metresPerSecond)
                    Text("km/h").tag(WindUnit.kilometresPerHour)
                    Text("mph").tag(WindUnit.milesPerHour)
                }
                // The unit of a line the face does not show is a setting
                // with nothing to act on.
                .disabled(draft.showsWind == false)
                Toggle("Colour by feels-like", isOn: Binding(
                    get: { draft.feelsLikeColour },
                    set: { settings.setFeelsLikeColour($0) }
                ))
                Toggle("Show feels-like", isOn: Binding(
                    get: { draft.showsFeelsLike },
                    set: { settings.setShowFeelsLike($0) }
                ))
                Toggle("Show humidity", isOn: Binding(
                    get: { draft.showsHumidity },
                    set: { settings.setShowHumidity($0) }
                ))
                Toggle("Show wind", isOn: Binding(
                    get: { draft.showsWind },
                    set: { settings.setShowsWind($0) }
                ))
                Toggle("Show today's high and low", isOn: Binding(
                    get: { draft.showsHiLo },
                    set: { settings.setShowsHiLo($0) }
                ))
                Toggle("Show rain chance", isOn: Binding(
                    get: { draft.showsRainChance },
                    set: { settings.setShowsRainChance($0) }
                ))
                Toggle("Show UV index", isOn: Binding(
                    get: { draft.showsUV },
                    set: { settings.setShowsUV($0) }
                ))
                Toggle("Show sunrise and sunset", isOn: Binding(
                    get: { draft.showsSunEvents },
                    set: { settings.setShowsSunEvents($0) }
                ))
                Toggle("Show hourly chart", isOn: Binding(
                    get: { draft.showsHourly },
                    set: { settings.setShowsHourly($0) }
                ))
                // No "Save settings" beside it any more. Every control here
                // writes as it is touched, like every other tile's, so a
                // button offering to save what is already saved is a button
                // that teaches the opposite of what the window does.
                Button("Reset to defaults") { settings.resetToDefaults() }
                    .controlSize(.small)
            }
        } else {
            EmptyView()
        }
    }

    /// The offered intervals, plus the stored one when a record carries a
    /// value the design does not offer — a picker whose selection matches no
    /// tag draws blank, which reads as a setting lost (as `UsageFaceBlock`).
    private static func changeEverySteps(_ draft: WeatherTileConfig) -> [TimeInterval] {
        let steps = WeatherTileConfig.changeEverySteps
        return steps.contains(draft.changeEvery) ? steps : (steps + [draft.changeEvery]).sorted()
    }
}
