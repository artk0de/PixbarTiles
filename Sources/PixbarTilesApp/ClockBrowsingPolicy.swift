import Combine
import PixbarKit

/// Whether the app looks for clocks advertising themselves on the network —
/// the one rule that starts and stops the Bonjour browse.
///
/// Owned by the delegate, beside the discovery it drives: the browse touches
/// neither the schedule, nor the device, nor what the user chose, so it stays
/// out of `AppModel` (see `AppDelegate.discovery`).
@MainActor
final class ClockBrowsingPolicy {
    private let discovery: ClockDiscovery
    /// The subscription that hears whether the clock is answering.
    private var reachability: AnyCancellable?
    /// The subscription that hears the Clocks tab come and go.
    private var clocksSectionWatch: AnyCancellable?
    /// Whether the panel is on screen.
    ///
    /// Kept here rather than asked of AppKit, because the question is "has this
    /// rule been told the panel opened and not yet told it closed" — which is
    /// what the browse is allowed to depend on. `NSWindow.isKeyWindow` would
    /// answer about a window that may not exist yet.
    private var panelIsOpen = false
    /// The two halves of the browsing rule, as the last event left them.
    ///
    /// Mirrors rather than reads: `@Published` delivers in `willSet`, so a
    /// subscriber that read back off the model would see the previous answer.
    /// Each subscription hands its own value down and stores it here; a read
    /// at `panelOpened` time is current, because that call is not inside a
    /// publisher's delivery.
    private var clockIsAnswering = false
    /// Whether the Settings window's Clocks tab is on screen — the fact the
    /// model publishes, mirrored here the same way the answer is.
    private var clocksSectionVisible = false
    /// Whether a browse has been asked for.
    ///
    /// What this rule INTENDED, not what the browser is doing — the browser
    /// owns that, and it already makes a late report from a cancelled browse
    /// harmless. Kept so that the same answer arriving twice, which is what a
    /// poll every minute produces, costs nothing at all.
    private var isBrowsing = false

    init(discovery: ClockDiscovery) {
        self.discovery = discovery
    }

    /// Hears every reachability answer, because one of them is a reason to stop
    /// looking — and hears the Clocks tab, because it is a reason to start.
    ///
    /// The values are passed down rather than read back off the model:
    /// `@Published` publishes in `willSet`, so at this point the model's own
    /// stored answers are still the previous ones and the ones that matter are
    /// the arguments.
    ///
    /// `assumeIsolated` because the mutation that publishes these happens on
    /// the main actor, so delivery does too, and the compiler cannot see that
    /// through Combine.
    func watch(_ model: AppModel) {
        reachability = model.clockHealthMonitor.$isDeviceOnline.sink { [weak self] answering in
            MainActor.assumeIsolated { self?.clockAnswers(answering) }
        }
        clocksSectionWatch = model.clockDirectory.$clocksSectionVisible.sink { [weak self] visible in
            MainActor.assumeIsolated { self?.clocksSection(visible: visible) }
        }
    }

    func clockAnswers(_ answering: Bool) {
        clockIsAnswering = answering
        reconsider()
    }

    func clocksSection(visible: Bool) {
        clocksSectionVisible = visible
        reconsider()
    }

    /// The panel is on screen: browse if there is anything to look for.
    func panelOpened() {
        panelIsOpen = true
        reconsider()
    }

    /// The panel has gone: whatever the browse was for, nobody can read it now.
    func panelClosed() {
        panelIsOpen = false
        reconsider()
    }

    /// Starts or stops the browse, from the two things that decide it.
    ///
    /// One place rather than a decision at each edge. The edges arrive in any
    /// order — a panel opened onto a clock that is already down, a clock that
    /// comes back while the panel is open, the Add clock sheet opening onto a
    /// clock that answers — and any more call sites each making up their own
    /// mind is more chances for them to disagree about whether a browse is
    /// running.
    ///
    /// **What starts a browse:** the panel opening while the clock is not
    /// answering, or the Clocks tab coming on screen — the tab is where a
    /// clock seen advertising itself becomes a configured one, and a tab
    /// open on an installation whose clock answers perfectly well still
    /// needs the list fed. **What stops one:** the panel closing, the clock
    /// answering, or the tab going away. There is no state in which a browse
    /// outlives every reason for it, which is what keeps an `NWBrowser` off
    /// the network for the whole of a working installation's life. Nothing
    /// else is a bound worth having: an unreachable-for-N-polls timer was the
    /// alternative and it is a browse that runs for as long as the outage
    /// does, which for a clock left unplugged over a holiday is the defect
    /// again with an extra counter.
    ///
    /// Two conditions and no third. "Is an address configured" is deliberately
    /// not asked: `AppModel.live()` falls back to `defaultDeviceHost` when the
    /// defaults key is unset, so an unconfigured app is pointed at a guess —
    /// and a guess nothing answers at is already a clock that is not answering.
    /// A separate check would be a second way to say the same thing, with its
    /// own way of being wrong.
    private func reconsider() {
        // A Clocks tab on screen is a reason of its own — the window holds
        // the list, whatever the panel is doing. The panel arm is the outage
        // arm: open, and the clock not answering, is when the user is
        // looking at a panel that wants the list.
        let wanted = clocksSectionVisible || (panelIsOpen && clockIsAnswering == false)
        guard wanted != isBrowsing else { return }
        isBrowsing = wanted
        if wanted { discovery.start() } else { discovery.stop() }
    }
}
