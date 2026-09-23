import Combine
import Foundation
import Observation
import PixelClockKit

/// The Settings window's facade: which tab is showing, which clock it is
/// opened on, and whether the Clocks tab is on screen — the one fact the
/// browse rule reads off a window the model has no other way to see.
///
/// The window is transient the way every window is, but its state is not:
/// the tab the user left it on is the tab it opens on, and "Clock settings…"
/// on a clock's gear lands on the Clocks tab with that clock named.
@MainActor
@Observable
final class SettingsModel {
    enum Tab: String, CaseIterable, Identifiable {
        case clocks
        case defaults
        case general

        var id: String { rawValue }

        /// The tab as the tabs name it.
        var title: String {
            switch self {
            case .clocks: "Clocks"
            case .defaults: "Defaults"
            case .general: "General"
            }
        }
    }

    private let model: AppModel

    /// The tab showing, held by the window across visits. Settable rather
    /// than private(set): the tab picker binds to it.
    var tab: Tab = .clocks
    /// Whether the Clocks tab is on screen right now. Driven by the tab's
    /// appearances and mirrored onto the model, where the browse rule reads
    /// it; kept here because the facade is what the tab talks to.
    private(set) var clocksSectionVisible = false

    /// The per-clock settings window's own tab: its two surfaces, said the
    /// way its tabs name them.
    enum ClockTab: String, CaseIterable, Identifiable {
        case tiles
        case general

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tiles: "Tiles"
            case .general: "General"
            }
        }
    }

    /// The per-clock tab showing, held across visits like the app tabs are.
    var clockTab: ClockTab = .tiles
    /// The clock the per-clock settings window is aimed at: the gear that
    /// opened it. Re-aimed, not re-opened — one window, whatever clock asks.
    private var _clockSettingsClockId: UUID?
    internal var clockSettingsClockId: UUID? {
        get { _clockSettingsClockId }
        set { _clockSettingsClockId = newValue }
    }

    init(model: AppModel) {
        self.model = model
    }

    // MARK: - The Clocks tab

    var clocks: [ClockRecord] { model.clocks }

    func statusLine(of clock: ClockRecord) -> String { model.statusLine(of: clock) }

    /// The clocks as the Clocks tab lists them, in stored order.
    ///
    /// Built here rather than in the view: the dot is the same computation the
    /// panel's sections run, and a projection nothing can reach is a projection
    /// nothing can check.
    var clockEntries: [ClockListEntry] {
        model.clocks.map { clock in
            ClockListEntry(
                id: clock.id,
                name: clock.name,
                device: clock.model,
                address: clock.address,
                status: model.statusLine(of: clock),
                dot: PanelModel.dot(
                    reachability: model.reachability(of: clock.id),
                    push: model.pushState(of: clock.id)
                )
            )
        }
    }

    func renameClock(_ id: UUID, to name: String) { model.renameClock(id, to: name) }
    func removeClock(_ id: UUID) { model.removeClock(id) }

    /// Drag reorder: the source clock moves to the destination row's place,
    /// and the store's order — the panel's section order — follows.
    func moveClock(_ source: UUID, to destination: UUID) {
        model.moveClock(source, to: destination)
    }

    func addClock(from discovered: DiscoveredClock) -> AppModel.ClockSaveOutcome {
        model.addClock(from: discovered)
    }

    func addClock(address: String) async -> AppModel.ClockSaveOutcome {
        await model.addClock(address: address)
    }

    // MARK: - The tab

    /// Aims the per-clock settings window at its clock — the gear's ask. The
    /// window's content reads the id back, so a second gear's click
    /// re-targets the window that is already open.
    func showClockWindow(_ clockId: UUID) {
        clockSettingsClockId = clockId
    }

    /// The clock the per-clock window is for, as a record — or nil while the
    /// window has no aim (a launch nobody aimed it, its first state).
    var aimedClock: ClockRecord? {
        clockSettingsClockId.flatMap { id in model.clocks.first { $0.id == id } }
    }

    /// The Clocks tab went on screen, or came off it. Mirrored onto the
    /// model, whose pulse the delegate already listens to.
    func clocksSectionVisibilityChanged(_ visible: Bool) {
        clocksSectionVisible = visible
        model.clocksSectionVisibilityChanged(visible)
    }
}
