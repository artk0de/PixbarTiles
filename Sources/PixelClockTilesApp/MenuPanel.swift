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
    /// The panel's own projection — every clock a section of statistics.
    /// Observed through `@Observable` tracking, so a plain `let`: what the
    /// body reads is what redraws it.
    let panel: PanelModel
    /// The Settings window's facade: the general gear aims it before the
    /// window opens.
    let settings: SettingsModel
    /// The store's facade: a clock's Add tile aims it before the window opens.
    let store: StoreModel
    /// Observed for the same reason a nested `ObservableObject` is always
    /// observed directly: the Clocks section reads its list, and a nested
    /// object publishes nothing to whoever holds it.
    @ObservedObject var discovery: ClockDiscovery
    /// Opens the app's Settings window — the system action, so the window
    /// macOS already knows how to make key and restorable is the one made.
    @Environment(\.openSettings) private var openTheSettings
    /// Opens one of the app's plain windows — the store, or a clock's own
    /// settings.
    @Environment(\.openWindow) private var openWindow
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
        panel: PanelModel,
        settings: SettingsModel,
        store: StoreModel,
        discovery: ClockDiscovery,
        defaults: UserDefaults = .standard
    ) {
        self.model = model
        self.panel = panel
        self.settings = settings
        self.store = store
        self.discovery = discovery
        self.defaults = defaults
    }

    /// The system action plus the activation that makes the opened window
    /// KEY. An accessory app's click goes to the panel, and macOS does not
    /// hand the key to a window whose app was not asking — without the
    /// explicit activate, every window opened from here appeared behind the
    /// user's attention and stayed there.
    private func openAndFocus(_ open: () -> Void) {
        open()
        NSApp.activate()
    }

    /// The History is the panel's one swap: it is read here, where a
    /// clickaway returns to the panel.
    var body: some View {
        if model.historyIsOpen {
            HistoryMenu(model: model, defaults: defaults)
        } else {
            panelView
        }
    }

    /// Every clock on the tree, as the requirement says the panel: its own
    /// statistics — the dot, the connection, the battery — and nothing else.
    /// Above them, one general gear; below, quit.
    @ViewBuilder
    private var panelView: some View {
        Group {
            if panel.hasNoClocks {
                // A launch that stored no clock: the state the user answers, not
                // a clock created in the dark (D6).
                NoClocksPanel(onAdd: {
                    settings.tab = .clocks
                    openAndFocus { openTheSettings() }
                })
                .padding(14)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("PixelClockTiles").font(.headline)
                    ForEach(panel.sections, id: \.clock.id) { section in
                        ClockSectionView(
                            section: section,
                            onClockSettings: {
                                settings.showClockWindow(section.clock.id)
                                openAndFocus { openWindow(id: "clock-settings") }
                            }
                        )
                    }
                    Divider()
                    lastRow
                }
                .padding(14)
            }
        }
        .panelWidth(from: defaults)
        // Liquid Glass is the panel's material. The scene lays the panel onto
        // the window; the effect is what draws the navigation layer's own
        // material, and the panel is exactly that — the chrome floating over
        // whatever is behind it.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        // On the group rather than on `body`, and that is the point: the
        // History is drawn by the same view, and a panel that asked for a
        // reading every time somebody came back from the History would spend
        // a request on a surface that shows none of it. The model coalesces
        // repeats, so a SwiftUI rebuild handing out a second appearance costs
        // nothing.
        .onAppear { model.refreshOnPanelOpen() }
    }

    /// The app's name, alone in the header: every gear on the panel is a
    /// clock's.

    /// Quit at one corner, Settings at the other — the general surface named
    /// in words rather than a third gear. Quit is instant, so it needs no
    /// state of its own: the panel is gone before the button could redraw.
    private var lastRow: some View {
        HStack {
            Button("Quit") { NSApplication.shared.terminate(nil) }
            Spacer()
            Button("Settings") {
                openAndFocus { openTheSettings() }
            }
        }
    }
}

/// One clock's section: the dot its session has earned, its name said the way
/// a person says it, its own gear, and the statistics the panel exists for —
/// the connection in words, the battery beside it when the clock has one.
private struct ClockSectionView: View {
    let section: PanelModel.ClockSection
    /// Where the gear goes: straight into the clock's settings window — a
    /// menu interposed in front of a window the click already named is a
    /// question asked twice.
    let onClockSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Self.colour(for: section.dot))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(Self.dotName(for: section.dot))
                Text("\(section.clock.name) (\(section.clock.model.spokenName))")
                    .font(.headline)
                Spacer()
                Button(action: onClockSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(section.clock.name) settings")
            }
            // The statistics line: the connection, and the battery when the
            // clock reports one. A TC002 reads as the connection alone, which
            // is the truth about a clock with no cell.
            Text(
                [section.statusLine, section.batteryLine]
                    .compactMap { $0 }
                    .joined(separator: " · ")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private static func colour(for dot: PanelModel.ClockDot) -> Color {
        switch dot {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }

    /// What the dot says to VoiceOver, in the words the status line used.
    private static func dotName(for dot: PanelModel.ClockDot) -> String {
        switch dot {
        case .green: "Connected"
        case .yellow: "Checking…"
        case .red: "Disconnected"
        }
    }
}

/// The model a clock record names, as a person says it — the panel's header,
/// the Clocks tab's rows and the store's cards all say it this way.
extension ClockModel {
    var spokenName: String {
        switch self {
        case .awtrix3: "AWTRIX 3"
        case .ulanziTC002: "TC002"
        }
    }
}
