import AppKit
import PixbarKit
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
    ///
    /// `Half` rather than `Section`, which is what it used to be called: a
    /// nested `Section` SHADOWS `SwiftUI.Section` throughout this type, and
    /// the controls column is a grouped form made of them now.
    @State private var half: Half = .tile
    /// Whether the anecdote history is up over this window.
    ///
    /// A sheet here and a panel swap there, over one `HistoryList`. The
    /// comment on the panel's side — that a sheet vanishes when its host
    /// loses focus — is true of a menu bar extra's window and of nothing
    /// else: this is an ordinary window, and a sheet on it stays up.
    @State private var showingHistory = false

    enum Half: String, CaseIterable, Identifiable {
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
            HStack(spacing: 0) {
                controlsColumn(for: key, value: value, stored: stored)
                Divider()
                previewColumn
            }
            // The tile and its clock are the WINDOW's name now, not a
            // headline inside it. `glassWindow()` hands the material to the
            // window and hides the toolbar band, so content is drawn under
            // the titlebar — and the headline that used to be the first thing
            // in this column was drawn under the title and the traffic
            // lights, on top of each other.
            .navigationTitle(value.name)
            .navigationSubtitle(clockName(of: key))
            // A floor that fits what is actually in here. The old 560×320 was
            // smaller than the controls, so the window could be dragged to a
            // size where the last toggles, the reset and half the preview
            // were simply cut off — with nothing scrolling to reach them.
            .frame(minWidth: 620, minHeight: 460)
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

    /// The half-picker in a band of its own, then the controls as a grouped
    /// form.
    ///
    /// A form, and that is the fix rather than a finish: the column was a
    /// plain `VStack` at a fixed 250, so a window dragged smaller CLIPPED the
    /// bottom of it — the last toggles and the reset went off the edge with
    /// no way to reach them. A grouped form is a scroll view, and it aligns
    /// every label to one gutter, which nine toggles under four pickers need
    /// more than any other surface in the app.
    ///
    /// The band's own padding is what clears the titlebar. `glassWindow()`
    /// hides the toolbar background so the material reads under the title,
    /// which also means the first control sits under it unless something
    /// stands it off — the 16 that used to be here was less than the
    /// titlebar is tall.
    @ViewBuilder
    private func controlsColumn(
        for key: TileKey, value: (name: String, config: TileConfig?), stored: TilePolicy
    ) -> some View {
        VStack(spacing: 0) {
            PixelSegmentedControl("Half", selection: $half, title: \.title)
                .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 10)
            Form {
                switch half {
                case .tile:
                    connectorBlock(for: key, value: value, stored: stored)
                case .common:
                    TilePolicyEditor(
                        policy: policyBinding(for: key, value: value, stored: stored),
                        refreshSteps: ladder(for: key),
                        // The three connectors whose own block carries the
                        // refresh under a name of its own. One stored value,
                        // one control, where its reader looks for it.
                        showsRefresh: namesItsOwnRefresh(key) == false
                    )
                }
                // What the model said no to, under the controls that asked.
                // Two lamp tiles claiming one corner at the same moment is
                // the refusal a person actually meets, and it used to be
                // discarded: the picker sprang back and the window said
                // nothing at all.
                if let refusal = settings.lastRefusal {
                    Label(refusal, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            // A grouped form paints an opaque scroll background over the
            // material behind it, as the Clocks tab did before this line.
            .scrollContentBackground(.hidden)
        }
        // A range, not a number. The fixed 250 could neither grow with a
        // window dragged wider nor shrink with one dragged narrower, so the
        // labels were cut off at the left edge instead of laying out smaller.
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
    }

    /// The one write every control on this surface goes through, so a refusal
    /// is said once in one place whichever half asked.
    private func policyBinding(
        for key: TileKey, value: (name: String, config: TileConfig?), stored: TilePolicy
    ) -> Binding<TilePolicy> {
        Binding(
            get: { stored },
            set: { settings.save(policy: $0, config: value.config) }
        )
    }

    /// The refresh intervals this tile's connector offers — the weather's
    /// minute-to-four-hours, the usage tiles' ten-seconds-to-four-hours, the
    /// general scale for everything else.
    private func ladder(for key: TileKey) -> [TimeInterval] {
        model.connector(for: key)?.refreshSteps ?? RefreshScale.steps
    }

    /// Whether this connector's own block carries the refresh itself.
    ///
    /// Keyed on the connector id rather than on the running instance, like the
    /// lamp block below: what a tile's surface looks like is the tile's
    /// question, not that of whichever instance happens to be in hand.
    private func namesItsOwnRefresh(_ key: TileKey) -> Bool {
        AppTileKinds.wiring(for: key.connectorId)?.namesItsOwnRefresh ?? false
    }

    /// The tile's own block beside the shared policy editor: what this
    /// tile's kind has that no other does, drawn by its wiring. Keyed on the
    /// connector id, not on the running instance: a tile whose settings are
    /// being opened may not have one in hand at all (a lamp's is built per
    /// VPN by the clock's own session), and the block is the tile's.
    @ViewBuilder
    private func connectorBlock(
        for key: TileKey, value: (name: String, config: TileConfig?), stored: TilePolicy
    ) -> some View {
        if let wiring = AppTileKinds.wiring(for: key.connectorId) {
            wiring.settingsBlock(TileBlockContext(
                key: key, parameters: value.config?.value, settings: settings, model: model,
                refresh: { label in
                    TileRefreshControl(
                        label: label,
                        ladder: ladder(for: key),
                        policy: policyBinding(for: key, value: value, stored: stored)
                    )
                },
                openHistory: {
                    model.loadHistory()
                    showingHistory = true
                },
                claudeCode: claudeCode
            ))
        }
    }

    // MARK: - The preview column

    private var previewColumn: some View {
        VStack(spacing: 8) {
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
            // A picture that comes with a sentence — the GitHub tile saying
            // why it has no reading, or which permission its token lacks —
            // says it under the picture.
            if settings.preview != nil, let note = settings.previewNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let clock = model.clocks.first(where: { $0.id == model.detailTileKey?.clockId }) {
                Text("\(clock.name) · \(clock.model.spokenName) · \(panelWords(of: clock.model))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // Centred in the half it has, rather than pinned to the top with a
        // `Spacer` under it. The panel is a small fixed picture and this
        // column is most of the window: pinned, the window read as a picture
        // with a large empty area below it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
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
    /// How often the sky is READ, handed in already bound to the tile's
    /// policy. Its neighbour "Change every" is a different setting on a
    /// different scale — three to fifteen seconds of dwell per state, not a
    /// poll — and the two were worth putting side by side precisely because
    /// they are so easily read as one.
    let fetchEvery: TileRefreshControl

    var body: some View {
        if let draft = settings.draft {
            // Four sections, because nine toggles under four pickers in one
            // undifferentiated run is a list a reader has to search rather
            // than scan — and the run was long enough to fall off the bottom
            // of the window. The grouping is the face's own: where it looks,
            // how it moves, what it counts in, what it draws.
            Section("Place") {
                WeatherTileBlock(
                    headline: settings.placeHeadline,
                    place: draft.place,
                    onSave: { settings.savePlace($0) },
                    onChoose: { settings.choosePlace($0) }
                )
            }
            Section("Layout") {
                LabeledContent("Arrangement") {
                    PixelSegmentedControl(
                        "Arrangement",
                        selection: Binding(
                            get: { draft.layout },
                            set: { settings.setLayout($0) }
                        ),
                        options: [
                            (WeatherTileConfig.Layout.anchor, "Anchor"),
                            (WeatherTileConfig.Layout.pages, "Pages"),
                            (WeatherTileConfig.Layout.hybrid, "Hybrid"),
                        ]
                    )
                }
            }
            // The two intervals together and apart from the arrangement,
            // because they are the pair a reader confuses: one is how long a
            // state stays on screen, the other how often the sky behind it is
            // read, and they differ by three orders of magnitude.
            Section("Timing") {
                SteppedSlider(
                    label: "Change every",
                    ladder: StepLadder(WeatherTileConfig.changeEverySteps),
                    value: draft.changeEvery,
                    caption: CodeUsageBlock.everyCaption,
                    onCommit: { settings.setChangeEvery($0) }
                )
                fetchEvery
            }
            Section("Units") {
                Picker("Temperature", selection: Binding(
                    get: { draft.units },
                    set: { settings.setUnits($0) }
                )) {
                    Text("°C — Celsius").tag(WeatherTileConfig.Units.celsius)
                    Text("°F — Fahrenheit").tag(WeatherTileConfig.Units.fahrenheit)
                }
                Picker("Wind", selection: Binding(
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
            }
            Section("What's shown") {
                Toggle("Colour by feels-like", isOn: Binding(
                    get: { draft.feelsLikeColour },
                    set: { settings.setFeelsLikeColour($0) }
                ))
                Toggle("Feels-like", isOn: Binding(
                    get: { draft.showsFeelsLike },
                    set: { settings.setShowFeelsLike($0) }
                ))
                Toggle("Humidity", isOn: Binding(
                    get: { draft.showsHumidity },
                    set: { settings.setShowHumidity($0) }
                ))
                Toggle("Wind", isOn: Binding(
                    get: { draft.showsWind },
                    set: { settings.setShowsWind($0) }
                ))
                Toggle("Today's high and low", isOn: Binding(
                    get: { draft.showsHiLo },
                    set: { settings.setShowsHiLo($0) }
                ))
                Toggle("Rain chance", isOn: Binding(
                    get: { draft.showsRainChance },
                    set: { settings.setShowsRainChance($0) }
                ))
                Toggle("UV index", isOn: Binding(
                    get: { draft.showsUV },
                    set: { settings.setShowsUV($0) }
                ))
                Toggle("Sunrise and sunset", isOn: Binding(
                    get: { draft.showsSunEvents },
                    set: { settings.setShowsSunEvents($0) }
                ))
                Toggle("Moon phase", isOn: Binding(
                    get: { draft.showsMoon },
                    set: { settings.setShowsMoon($0) }
                ))
                Toggle("Hourly chart", isOn: Binding(
                    get: { draft.showsHourly },
                    set: { settings.setShowsHourly($0) }
                ))
            }
            // Its own section, at the end. No "Save settings" beside it any
            // more: every control here writes as it is touched, like every
            // other tile's, so a button offering to save what is already
            // saved teaches the opposite of what the window does.
            Section {
                Button("Reset to defaults") { settings.resetToDefaults() }
            }
        } else {
            EmptyView()
        }
    }

    /// The offered intervals, plus the stored one when a record carries a
    /// value the design does not offer — a picker whose selection matches no
    /// tag draws blank, which reads as a setting lost (as `CodeUsageBlock`).
}
