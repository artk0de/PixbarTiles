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
                            set: { _ = model.saveTile(key: key, policy: $0, config: value.config) }
                        ))
                    }
                    Spacer()
                }
                .frame(width: 250, alignment: .leading)
                Divider()
                previewColumn
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassWindow(cornerRadius: 16)
            // The window going away is the detail closing: the panel's
            // branch sees nil the next time it asks, and the facade's draft
            // is dropped with it.
            .onDisappear { model.closeDetail() }
        } else {
            Text("No tile selected.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(40)
                .frame(width: 320, height: 160)
        }
    }

    private func clockName(of key: TileKey) -> String {
        model.clocks.first { $0.id == key.clockId }?.name ?? ""
    }

    // MARK: - The controls column

    /// The tile's own block beside the shared policy editor: what this
    /// connector has that no other does. A connector with nothing of its own
    /// draws nothing there.
    @ViewBuilder
    private func connectorBlock(
        for key: TileKey, value: (name: String, config: TileConfig?)
    ) -> some View {
        let connector = model.registry.connector(id: key.connectorId)
        if connector is WeatherConnector {
            WeatherTileControls(settings: settings)
        } else if connector is AnecdoteConnector {
            AnecdoteTileBlock(onHistory: { model.openHistory() })
        } else if connector is ClaudeUsageConnector {
            VStack(alignment: .leading, spacing: 10) {
                ClaudeTileBlock(
                    metric: value.config?.claude ?? .weekly,
                    onMetric: { metric in
                        guard let stored = model.storedPolicy(of: key) else { return }
                        _ = model.saveTile(key: key, policy: stored, config: .claude(metric))
                    }
                )
                // Machine-wide state, one file, not a tile's: whatever tile's
                // window it is edited from edits it for every Claude tile.
                ClaudeCodeSettings(link: claudeCode())
            }
        } else if connector is ZaiUsageConnector {
            ZaiTileBlock(
                hasKey: model.hasZaiKey(for: key),
                outcome: model.lastZaiKeyOutcome,
                onSaveKey: { model.saveZaiKey($0, for: key) }
            )
        } else {
            EmptyView()
        }
    }

    // MARK: - The preview column

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On the clock").font(.caption).foregroundStyle(.secondary)
            if let data = settings.preview, let image = NSImage(data: data) {
                Image(nsImage: Self.scaled(image, by: 6))
                    .interpolation(.none)
                    .border(Color.secondary.opacity(0.4))
            } else {
                Text(settings.draft == nil ? "This tile draws no preview." : "Rendering…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 312, height: 96)
                    .border(Color.secondary.opacity(0.4))
            }
            if let clock = model.clocks.first(where: { $0.id == model.detailTileKey?.clockId }) {
                Text("\(clock.name) · \(clock.model.spokenName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// The panel's own pixels, six over one, drawn WITHOUT interpolation —
    /// smoothing a 52×16 face into porridge is the one way to make a true
    /// preview lie about what the clock looks like.
    private static func scaled(_ image: NSImage, by factor: CGFloat) -> NSImage {
        let size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
        let scaled = NSImage(size: size)
        scaled.lockFocusFlipped(true)
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: NSRect(origin: .zero, size: size))
        scaled.unlockFocus()
        return scaled
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
                Picker("Units", selection: Binding(
                    get: { draft.units },
                    set: { settings.setUnits($0) }
                )) {
                    Text("°C — Celsius").tag(WeatherTileConfig.Units.celsius)
                    Text("°F — Fahrenheit").tag(WeatherTileConfig.Units.fahrenheit)
                }
                Toggle("Show humidity", isOn: Binding(
                    get: { draft.showsHumidity },
                    set: { settings.setShowHumidity($0) }
                ))
                Toggle("Show feels-like", isOn: Binding(
                    get: { draft.showsFeelsLike },
                    set: { settings.setShowFeelsLike($0) }
                ))
                HStack {
                    Button("Save settings") { settings.saveConfig() }
                        .controlSize(.small)
                    Button("Reset to defaults") { settings.resetToDefaults() }
                        .controlSize(.small)
                }
            }
        } else {
            EmptyView()
        }
    }
}
