import AppKit
import PixelClockKit
import SwiftUI

/// When the next run is due, or what is holding it.
///
/// A time and a reason are the same slot because they answer the same question,
/// and only one of them is ever true. Naming an hour while something is holding
/// the schedule is the failure worth avoiding: the user plans around it.
enum NextRunLine {
    static func text(for next: NextRun?) -> String? {
        switch next {
        case nil: nil
        case let .due(date): "next \(date.formatted(date: .omitted, time: .shortened))"
        case let .held(reason): reason
        }
    }
}


struct MenuPanel: View {
    @ObservedObject var model: AppModel
    /// Observed separately from `model`: a nested `ObservableObject` publishes
    /// nothing to whoever holds it, so a view that wants the battery reading has
    /// to watch the monitor itself.
    @ObservedObject var monitor: DeviceMonitor
    /// Observed separately for the same reason `monitor` is: a nested
    /// `ObservableObject` publishes nothing to whoever holds it.
    @ObservedObject var discovery: DeviceBrowser
    /// Where the width is read at launch and written when a drag ends.
    ///
    /// Handed in rather than reached for, so a test can put a width in the
    /// defaults and see the panel drawn at it. Reaching for `.standard` inside
    /// the view would leave the one thing worth proving — that the stored number
    /// reaches the layout — testable only by writing into the preferences of
    /// whoever is running the suite.
    private let defaults: UserDefaults

    /// Written out rather than left to the memberwise one, only so `defaults`
    /// can be private and still be handed in.
    init(
        model: AppModel,
        monitor: DeviceMonitor,
        discovery: DeviceBrowser,
        defaults: UserDefaults = .standard
    ) {
        self.model = model
        self.monitor = monitor
        self.discovery = discovery
        self.defaults = defaults
    }

    /// Which surface is on screen — and the same defaults down every branch,
    /// because the width is one number for all of them.
    var body: some View {
        if model.settingsAreOpen {
            SettingsSheet(model: model, defaults: defaults)
        } else if model.historyIsOpen {
            HistoryMenu(model: model, defaults: defaults)
        } else if let key = model.detailTileKey {
            detail(for: key)
        } else {
            panel
        }
    }

    /// What a click opens: is the selected clock alive, and run something now.
    ///
    /// The panel is the selected clock's: one switch over its clocks, the
    /// status block for the selection, one row per tile on it, and the Add
    /// tile menu checked against it. Everything set once and forgotten went
    /// behind the gear in the last row.
    @ViewBuilder
    private var panel: some View {
        if model.hasNoClocks {
            // A launch that stored no clock: the state the user answers, not
            // a clock created in the dark (D6).
            NoClocksPanel(onAdd: { model.openSettings() })
                .padding(14)
                .panelWidth(from: defaults)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ClockSwitcher(
                    clocks: model.clocks.map {
                        ClockSwitcher.Entry(
                            id: $0.id, name: $0.name, model: modelName($0.model)
                        )
                    },
                    selection: Binding(
                        get: { model.selectedClockId ?? model.clocks.first?.id ?? UUID() },
                        set: { model.selectedClockId = $0 }
                    )
                )
                statusBlock
                discoverySection
                Divider()
                ForEach(model.tileRows, id: \.key) { row in
                    TileRow(value: row)
                }
                AddTileMenu(items: model.addTileMenuItems)
                Divider()
                lastRow
            }
            .padding(14)
            // The width the three surfaces share, and the border it is dragged
            // by. It is the CONTENT that carries the width rather than the
            // window: `MenuBarExtra` in `.window` style keeps its window at
            // the content's fitting size and re-imposes that on every layout
            // pass, so the content's width is the only thing the window will
            // agree to be. The measurement is in `docs/HANDOFF.md`, under the
            // panel's width belonging to the content.
            //
            // No second axis. The panel is exactly as tall as its rows and
            // there is nothing for a top or bottom edge to change; only the
            // History, which holds a list that outgrows any height, stores one.
            .panelWidth(from: defaults)
            // On this branch rather than on `body`, and that is the point: the
            // settings and the History are drawn by the same view, and a panel
            // that asked for a reading every time somebody came back from the
            // gear would spend a request on a surface that draws no battery at
            // all. The model coalesces repeats, so a SwiftUI rebuild handing
            // out a second appearance costs nothing.
            .onAppear { model.refreshOnPanelOpen() }
        }
    }

    /// The selected clock's status: connectivity, address, battery when the
    /// clock reports one — which the TC002 never does — and the discovery line
    /// when there is something to say. The readings are the SELECTED clock's;
    /// the monitor observed above stays the redraw handle.
    private var statusBlock: some View {
        ClockStatusBlock(
            state: model.monitor.state,
            address: model.selectedAddress,
            battery: model.selectedClockIsAwtrix ? model.monitor.battery : nil,
            discovery: discovery.state
        )
    }

    /// What is advertising itself on the network, kept apart from the status
    /// block above it.
    ///
    /// Two lines with two sources, deliberately not merged: the status is the
    /// monitor's answer about the address this app is pointed at, and this one
    /// is a Bonjour advertisement. A clock can advertise itself and still not
    /// answer `/api/stats` — so being seen here is not being reachable, and
    /// the panel never says it is. The row appears exactly when it is worth
    /// reading — the clock has moved, or has never been found — and it is the
    /// browse that is conditional here, not the row.
    private var discoverySection: some View {
        Group {
            if let line = DiscoveryStatusLine.text(for: discovery.state) {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Quit, and the gear.
    ///
    /// The gear shares the row rather than taking one of its own: it is a corner
    /// of what is already there, and a panel that grew a row to hold a settings
    /// button would have paid for the tidying with the space it was tidying.
    private var lastRow: some View {
        HStack {
            Button("Quit") { NSApplication.shared.terminate(nil) }
            Spacer()
            Button { model.openSettings() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Settings")
        }
    }

    // MARK: - The detail surface

    /// The tile's detail surface, opened for one tile (D4): the shared policy
    /// editor, the tile's own block beside it, and the clock it is on named in
    /// the way back. A save carries the tile's config through untouched.
    @ViewBuilder
    private func detail(for key: TileKey) -> some View {
        if let value = model.detailValue(for: key), let stored = model.storedPolicy(of: key) {
            TileDetail(
                tileName: value.name,
                clockName: model.clocks.first { $0.id == key.clockId }?.name ?? "",
                policy: stored,
                connector: AnyView(connectorBlock(for: key, config: value.config)),
                onPolicy: { model.saveTile(key: key, policy: $0, config: value.config) },
                onBack: { model.closeDetail() }
            )
        } else {
            panel
        }
    }

    /// The tile's own block beside the shared policy editor: what this
    /// connector has that no other does. A connector with nothing of its own
    /// draws nothing there.
    @ViewBuilder
    private func connectorBlock(for key: TileKey, config: TileConfig?) -> some View {
        let connector = model.registry.connector(id: key.connectorId)
        if connector is WeatherConnector {
            WeatherTileBlock(
                place: config?.location ?? .default,
                onSave: { typed in
                    guard let place = LocationField.parse(typed),
                        let stored = model.storedPolicy(of: key)
                    else { return }
                    model.saveTile(key: key, policy: stored, config: .weather(place))
                }
            )
        } else if connector is AnecdoteConnector {
            AnecdoteTileBlock(onHistory: { model.openHistory() })
        } else {
            EmptyView()
        }
    }

    /// The clock a switcher segment names, as the models are called when a
    /// person says them.
    private func modelName(_ model: ClockModel) -> String {
        switch model {
        case .awtrix3: "AWTRIX 3"
        case .ulanziTC002: "TC002"
        }
    }
}
