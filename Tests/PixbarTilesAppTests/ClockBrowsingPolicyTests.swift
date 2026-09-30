import PixbarKit
import Testing
@testable import PixbarTilesApp

/// The browse rule on its own, without a delegate or a window: a browse runs
/// while the Clocks tab is on screen, or while the panel is open onto a clock
/// that is not answering — and at no other time.
@MainActor
@Suite struct ClockBrowsingPolicyTests {
    private let browsing = FakeBonjourBrowser()

    private func policy() -> ClockBrowsingPolicy {
        ClockBrowsingPolicy(discovery: ClockDiscovery(
            browse: DeviceBrowser(browsing: { browsing }, sleep: { _ in }),
            sightings: { AsyncStream { $0.finish() } }
        ))
    }

    @Test func thePanelOpenedOntoASilentClockBrowsesUntilTheClockAnswers() {
        let rule = policy()
        rule.panelOpened()
        #expect(browsing.liveBrowses == 1)
        rule.clockAnswers(true)
        #expect(browsing.liveBrowses == 0)
    }

    @Test func thePanelOpenedOntoAnAnsweringClockDoesNotBrowse() {
        let rule = policy()
        rule.clockAnswers(true)
        rule.panelOpened()
        #expect(browsing.starts == 0)
    }

    @Test func theClocksTabBrowsesWhateverTheClockSays() {
        let rule = policy()
        rule.clockAnswers(true)
        rule.clocksSection(visible: true)
        #expect(browsing.liveBrowses == 1)
        rule.clocksSection(visible: false)
        #expect(browsing.liveBrowses == 0)
    }

    @Test func closingThePanelStopsItsBrowse() {
        let rule = policy()
        rule.panelOpened()
        rule.panelClosed()
        #expect(browsing.liveBrowses == 0)
    }

    @Test func theSameAnswerTwiceStartsNothingNew() {
        let rule = policy()
        rule.panelOpened()
        rule.clockAnswers(false)
        rule.clockAnswers(false)
        #expect(browsing.starts == 1)
    }
}
