import Combine
import Foundation
import Observation
import PixelClockKit

/// The panel's view of the model: every clock a section of STATISTICS — the
/// status dot its session has earned, the connection in words, the battery
/// beside it — and nothing else.
///
/// The panel is a glance, and the requirement it answers is "what are my
/// clocks doing": a clock's connection and its charge, per clock, in stored
/// order. The tiles a clock carries are configuration, and configuration
/// lives in the clock's own settings window — the panel carried tile rows
/// for one iteration and the user's correction took them out (2026-09-21):
/// statistics, not removable rows.
///
/// `@Observable` rather than an `ObservableObject`, because the views that
/// draw the panel observe THIS; the model underneath stays what it is, and
/// the two never hold the same state in parallel.
@MainActor
@Observable
final class PanelModel {
    /// The dot's three answers: delivered, in flight or nothing yet, down.
    enum ClockDot: Equatable, Sendable {
        case green
        case yellow
        case red
    }

    /// One clock's place on the panel: its record, the dot its session has
    /// earned, and the two statistics the panel exists to show.
    struct ClockSection {
        let clock: ClockRecord
        let dot: ClockDot
        /// The connection, in the dot's own words.
        let statusLine: String
        /// The battery, when the clock has one to report — a TC002 and a
        /// clock that is not answering both say nothing here.
        let batteryLine: String?
        /// The reading behind that line, for the card that draws the charge
        /// as cells rather than saying it.
        let battery: BatteryReading?

        /// Whether what the card shows is current. A clock that cannot be
        /// reached shows what it last reported, and the card greys it and says
        /// "last known" rather than passing it off as now.
        var isLive: Bool { dot != .red }
    }

    /// The header's count: how many of the clocks are answering right now.
    var onlineSummary: String {
        let online = sections.filter { $0.dot == .green }.count
        return "\(online) of \(sections.count) online"
    }

    private let model: AppModel
    private(set) var sections: [ClockSection] = []
    /// The subscription that hears every change the model publishes.
    private var pulse: AnyCancellable?
    /// The rebuild that is waiting for the change to land.
    private var scheduled: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        rebuildNow()
        pulse = model.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildAfterTheChangeLands() }
        }
    }

    // No deinit cancelling `scheduled` on purpose: deinit is nonisolated, and
    // the task holds `self` weakly, so a facade that went away costs it one
    // nil check — nothing to cancel that is not already harmless.

    /// Read off the projection rather than the model, so a body that asks it
    /// is watching a property that changes when the answer does: `sections`
    /// is what this type owns, and the one clock leaving the tree moves it.
    var hasNoClocks: Bool { sections.isEmpty }

    // MARK: - The dot

    /// The dot's whole table, decided once rather than at each caller.
    ///
    /// The dot is the CONNECTION and nothing else — the user's correction
    /// (2026-09-21): a clock that is there but whose last push failed is a
    /// connected clock, and the failure is the failed TILE's to wear (the
    /// red warning sign on its card, the words on hover). Red means the
    /// clock cannot be reached; yellow means the connection is not yet
    /// known or a push is in flight; green means the clock is there.
    nonisolated static func dot(
        reachability: AppModel.ClockReachability, push: AppModel.PushState
    ) -> ClockDot {
        switch reachability {
        case .unreachable: return .red
        case .unknown, .reachable: break
        }
        switch push {
        // A delivered push proves the clock answers, whatever the poll last
        // said — the delivery is the fresher evidence.
        case .delivered: return .green
        case .running: return .yellow
        case .none, .failed:
            return reachability == .reachable ? .green : .yellow
        }
    }

    // MARK: - The projection

    /// Rebuilds the sections from what the model now answers.
    private func rebuildNow() {
        sections = model.clocks.map { section(for: $0) }
    }

    /// The change has been announced but has not landed: `objectWillChange`
    /// delivers in `willSet`, so a rebuild run straight in the sink would
    /// read the state the change is about to replace. One hop onto the main
    /// actor later, the state is the new one.
    private func rebuildAfterTheChangeLands() {
        scheduled?.cancel()
        scheduled = Task { [weak self] in self?.rebuildNow() }
    }

    private func section(for clock: ClockRecord) -> ClockSection {
        ClockSection(
            clock: clock,
            dot: Self.dot(
                reachability: model.reachability(of: clock.id),
                push: model.pushState(of: clock.id)
            ),
            statusLine: model.statusLine(of: clock),
            batteryLine: model.batteryLine(of: clock),
            battery: model.battery(of: clock)
        )
    }
}
