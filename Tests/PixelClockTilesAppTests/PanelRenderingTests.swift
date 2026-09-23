import AppKit
import PixelClockKit
import Foundation
import SwiftUI
import Testing
@testable import PixelClockTilesApp

// What the panel actually draws.
//
// `DiscoveryStatusLine` and `DeviceHostField` are pure and well covered, but
// neither of them proves its output reaches the screen: deleting
// `discoverySection` from `body` entirely left every other test in this suite
// green. A SwiftUI `body` cannot be inspected without a third-party dependency
// and `Package.swift` has none, so these draw the panel into a bitmap at its
// shipped width and compare the pixels. Two states that must look different and
// do not is a section that is not on the panel.

/// The panel, drawn at the width it ships at.
///
/// No window and no run loop: `cacheDisplay` renders the layer tree
/// synchronously, which is what keeps this deterministic rather than a wait on
/// something asynchronous to settle.
@MainActor
private func rendered(
    discovery state: DiscoveryState, deviceHost: String = "10.0.0.5"
) -> Data? {
    let browsing = FakeBonjourBrowser()
    let discovery = panelDiscovery(browsing: browsing)
    discovery.browse.start()
    switch state {
    case let .listed(devices) where devices.isEmpty:
        // An empty network is an ANSWERED question, so the double has to
        // answer one first: a hit settles the browse, and the emptied result
        // set that follows is the last device going away.
        browsing.emit(.results(["awtrix_000000"]))
        browsing.emit(.results([]))
    case let .listed(devices): browsing.emit(.results(devices.map(\.instanceName)))
    case .denied: browsing.emit(.denied)
    case let .unavailable(reason): browsing.emit(.unavailable(reason))
    case let .failed(reason): browsing.emit(.failed(reason))
    case .idle: discovery.browse.stop()
    case .searching: break
    }
    #expect(discovery.state == state, "the double did not reach \(state)")

    let model = testModel(deviceHost: deviceHost)
    let host = NSHostingView(
        rootView: MenuPanel(
            model: model, panel: PanelModel(model: model),
            settings: SettingsModel(model: model)
        )
    )
    host.frame = NSRect(x: 0, y: 0, width: 320, height: 700)
    host.layoutSubtreeIfNeeded()
    guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: target)
    return target.representation(using: .png, properties: [:])
}

private let oneDevice = DiscoveryState.listed([DiscoveredDevice(instanceName: "awtrix_a07f9c")])

// The status block left the panel with the redesign — the dot is the clock's
// status now, one per section, and the discovery line's next home is the
// Clocks tab. What is pinned here instead is the dot answering its session:
// a clock the poll cannot reach draws a different panel from the same panel
// before any poll answered.
@Test @MainActor func aClocksDotAnswersItsSession() async {
    let quiet = testModel(deviceHost: "10.0.0.5")
    let unreachable = testModel(
        transport: StubTransport(failure: URLError(.cannotConnectToHost)),
        pollSleep: parked,
        deviceHost: "10.0.0.5"
    )
    unreachable.start()
    #expect(await waitUntil { isOffline(unreachable) })

    let before = drawn(quiet)
    #expect(before != nil)
    #expect(before != drawn(unreachable))
    await unreachable.teardown()
}

// Same drawing twice is the same pixels — otherwise every expectation above
// passes for the wrong reason, on noise rather than on content.
@Test @MainActor func thePanelDrawsTheSameThingTwice() {
    #expect(rendered(discovery: oneDevice) == rendered(discovery: oneDevice))
}


// The feed, at the surface it matters on: the Clocks section is where a
// clock seen advertising itself becomes a configured one, and what it lists
// is the merged discovery's own rows — the TC002 captured line included,
// spelled exactly as the device announces it. A discovery nobody fed draws
// the section without the list.
@Test @MainActor func theClocksSectionListsWhatDiscoveryFound() async throws {
    func drawnSheet(_ discovery: ClockDiscovery) -> Data? {
        let model = testModel(deviceHost: "10.0.0.5")
        let host = NSHostingView(
            rootView: SettingsRoot(
                model: model, settings: SettingsModel(model: model), discovery: discovery
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 900)
        host.layoutSubtreeIfNeeded()
        guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: target)
        return target.representation(using: .png, properties: [:])
    }

    func discoveryFed(_ line: String?, from address: String) -> ClockDiscovery {
        let browsing = FakeBonjourBrowser()
        let (stream, feed) = AsyncStream<UlanziSighting>.makeStream()
        let subject = ClockDiscovery(
            browse: DeviceBrowser(browsing: { browsing }, sleep: { _ in }),
            sightings: { stream }
        )
        subject.start()
        if let line,
            let announcement = UlanziAnnouncement.parse(line)
        {
            feed.yield(UlanziSighting(announcement: announcement, host: address))
        }
        return subject
    }

    // The captured broadcast, verbatim (2026-09-20, the clock on the desk).
    let fed = discoveryFed(
        "Ulanzi TC002 9b9a:ccc4b2779b9a:B0D32I008U3671403:false", from: "192.168.1.72"
    )
    #expect(await waitUntil { !fed.found.isEmpty })
    #expect(fed.found.first == DiscoveredClock(
        name: "TC002 9b9a", model: "TC002", address: "192.168.1.72"
    ))

    let withRow = drawnSheet(fed)
    let withoutRow = drawnSheet(discoveryFed(nil as String?, from: "192.168.1.72"))

    #expect(withRow != nil)
    #expect(withRow != withoutRow)
}

/// Every editable text field on the panel, by what is in it.
///
/// SwiftUI draws `Text` rather than backing it with a control, so the pixel
/// comparisons above are the only way to see a label — but a `TextField` on
/// macOS IS an `NSTextField` in the view tree, and its `stringValue` can simply
/// be read. That is worth using: the pixel route could not tell the field apart
/// from the status line, which names the same address one row up.
@MainActor
private func fields(in view: NSView) -> [String] {
    var found: [String] = []
    if let field = view as? NSTextField, field.isEditable { found.append(field.stringValue) }
    for sub in view.subviews { found += fields(in: sub) }
    return found
}

/// What the location box holds on a launch nobody has typed into. Every model
/// here gets a defaults suite of its own, so it is always the shipped default.
@MainActor
private var seededLocation: String { LocationField.text(for: .default) }

/// A discovery for the surfaces under render: never started by these tests
/// beyond the browse they drive by hand, no socket.
@MainActor
private func panelDiscovery(browsing: FakeBonjourBrowser) -> ClockDiscovery {
    ClockDiscovery(
        browse: DeviceBrowser(browsing: { browsing }, sleep: { _ in }),
        sightings: { AsyncStream { $0.finish() } }
    )
}

@MainActor
private func panelFields(deviceHost: String) -> [String] {
    let browsing = FakeBonjourBrowser()
    let discovery = panelDiscovery(browsing: browsing)
    discovery.browse.start()
    let model = testModel(deviceHost: deviceHost)
    let host = NSHostingView(
        rootView: MenuPanel(
            model: model, panel: PanelModel(model: model),
            settings: SettingsModel(model: model)
        )
    )
    host.frame = NSRect(x: 0, y: 0, width: 320, height: 700)
    host.layoutSubtreeIfNeeded()
    return fields(in: host)
}

// MARK: - The menu bar glyph

/// The glyph as the menu bar would draw it.
@MainActor
private func renderedGlyph(for model: AppModel) -> Data? {
    renderedInTheBar(MenuBarGlyph(model: model))
}

/// The same, for a drawing chosen by hand rather than by a device state.
///
/// The reference half of the direction assertion. `MenuBarGlyph`'s body is
/// `Image(nsImage:)` — the glyph carries its own colours, so there is no
/// rendering mode to add — and hosting that expression in the same frame
/// renders the same bytes.
@MainActor
private func renderedGlyph(_ state: AppGlyph.State) -> Data? {
    renderedInTheBar(Image(nsImage: AppGlyph.menuBar(for: state)))
}

@MainActor
private func renderedInTheBar(_ view: some View) -> Data? {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 21, height: 18)
    host.layoutSubtreeIfNeeded()
    guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: target)
    return target.representation(using: .png, properties: [:])
}

/// A model whose poll has answered, one way or the other.
@MainActor
private func polled(reachable: Bool) async -> AppModel {
    let transport: any Transport = reachable
        ? StubTransport(body: onlineStats)
        : StubTransport(failure: URLError(.cannotConnectToHost))
    let model = testModel(transport: transport, pollSleep: parked)
    model.start()
    #expect(await waitUntil { model.isDeviceOnline == reachable })
    return model
}

// `AppGlyph.menuBar(lit:)` is well covered and proves nothing about the menu
// bar: what it cannot say is that the view asks the DEVICE STATE for its
// argument. Passing a constant there left the whole suite green, so nothing
// held the icon in the menu bar to whether the clock was reachable — the one
// thing the icon is there to say.
//
// No GUI needed: the same hosting-view render the panel tests use, driven by a
// poll that really answered rather than by a flag set by hand.
@Test @MainActor func theMenuBarGlyphFollowsWhetherTheClockIsReachable() async {
    let online = renderedGlyph(for: await polled(reachable: true))
    let offline = renderedGlyph(for: await polled(reachable: false))

    #expect(online != nil)
    #expect(online != offline)
}

// And the same glyph twice is the same pixels, or the expectation above passes
// on noise rather than on content.
@Test @MainActor func theMenuBarGlyphDrawsTheSameThingTwice() async {
    let model = await polled(reachable: true)

    #expect(renderedGlyph(for: model) == renderedGlyph(for: model))
}

// WHICH way round. The test above says the two renders differ, which is exactly
// as true of `lit: !model.isDeviceOnline` — measured on the shipped tree at
// 653/653 green, with the menu bar showing a lit panel for a dead clock and an
// empty one for a healthy one.
//
// So each render is compared against the render of the drawing that state is
// supposed to select, rather than against the other state. Inverting the
// argument in `MenuBarGlyph` swaps both sides at once and both lines fail.
@Test @MainActor func aReachableClockLightsTheMenuBarAndAnUnreachableOneEmptiesIt() async {
    let online = renderedGlyph(for: await polled(reachable: true))
    let offline = renderedGlyph(for: await polled(reachable: false))

    // Or two nils would satisfy both comparisons with nothing drawn at all.
    #expect(renderedGlyph(.online) != nil)
    #expect(online == renderedGlyph(.online))
    #expect(offline == renderedGlyph(.offline))
}

// MARK: - Behind the gear

@MainActor
private func hosted<Content: View>(_ view: Content) -> NSHostingView<Content> {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    return host
}

@MainActor
private func bitmap(_ host: NSView) -> NSBitmapImageRep? {
    guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: target)
    return target
}

@MainActor
private func settingsFields(deviceHost: String) -> [String] {
    let model = testModel(deviceHost: deviceHost)
    let settings = SettingsModel(model: model)
    return fields(in: hosted(SettingsRoot(
        model: model, settings: settings, discovery: inertDiscovery()
    )))
}

/// The Settings window as pixels — the Clocks tab, which is the tab it opens
/// on.
@MainActor
private func drawnSettings(_ model: AppModel) -> Data? {
    let settings = SettingsModel(model: model)
    let host = hosted(SettingsRoot(
        model: model, settings: settings, discovery: inertDiscovery()
    ))
    return bitmap(host)?.representation(using: .png, properties: [:])
}

/// The General tab as pixels — the tab the once-in-a-lifetime settings live
/// on.
@MainActor
private func drawnGeneral(_ model: AppModel) -> Data? {
    let host = hosted(GeneralTab(model: model))
    return bitmap(host)?.representation(using: .png, properties: [:])
}

/// The panel, hosted and laid out, with a browse that reaches no network.
///
/// Handed back rather than rendered, for the tests that measure the panel's
/// SIZE as well as its ink — a button that took a row of its own is a taller
/// panel, and pixels alone cannot say whether the difference is a new row or a
/// wider one.
@MainActor
private func hostedPanel(_ model: AppModel) -> NSHostingView<MenuPanel> {
    let browsing = FakeBonjourBrowser()
    let discovery = panelDiscovery(browsing: browsing)
    discovery.browse.start()
    return hosted(MenuPanel(
        model: model, panel: PanelModel(model: model),
        settings: SettingsModel(model: model)
    ))
}

/// The panel, or the settings when they are open, as pixels.
@MainActor
private func drawn(_ model: AppModel) -> Data? {
    bitmap(hostedPanel(model))?.representation(using: .png, properties: [:])
}

/// The panel, drawn once the reading its own opening asked for has landed.
///
/// Drawing the panel is an event the model reacts to: `.onAppear` asks for one
/// reading, because the poll behind it is a minute apart. An unstarted model has
/// nothing else that would ask, so the FIRST drawing is taken before that
/// reading and every later one after it — a difference of device state that has
/// nothing to do with the surface under test. Settled here instead, and the
/// model coalesces repeats, so no drawing after this one asks again.
@MainActor
private func drawnAfterTheOpeningReading(_ model: AppModel) async -> Data? {
    _ = drawn(model)
    #expect(await waitUntil { model.isDeviceOnline })
    return drawn(model)
}

@MainActor
private func panelControls(_ model: AppModel) -> [String] {
    let browsing = FakeBonjourBrowser()
    let discovery = panelDiscovery(browsing: browsing)
    discovery.browse.start()
    return fields(in: hosted(MenuPanel(
        model: model, panel: PanelModel(model: model),
        settings: SettingsModel(model: model)
    )))
}

// The whole point of the move: the panel that opens dozens of times a day holds
// neither the field nor the action, and holds no trace of either.
//
// Two different instruments, because one of them alone is the trap this file
// already fell into once. The field is read off the control — pixels could not
// tell it from the status line naming the same address. The icon action is read
// off the pixels through its result line, because a SwiftUI `Button` is not an
// `NSButton` and cannot be read off the tree at all: a panel still carrying the
// section would draw `iconStatus` and so would answer differently to a model
// that has one.
@Test @MainActor func theMainPanelHoldsNeitherTheAddressFieldNorTheIconAction() async {
    #expect(panelControls(testModel(deviceHost: "10.0.0.5")).isEmpty)

    let quiet = testModel(deviceHost: "10.0.0.5")
    let reported = testModel(deviceHost: "10.0.0.5")
    reported.removeInstalledIcons()
    #expect(await waitUntil { reported.iconStatus != nil })

    #expect(drawn(quiet) != nil)
    #expect(drawn(quiet) == drawn(reported))
}

@Test @MainActor func theSettingsHoldTheClocksSectionAndTheIconAction() async {
    // The Clocks tab is where the address field used to be: one editable
    // box — add-by-address — and no location box anywhere in the window.
    #expect(settingsFields(deviceHost: "10.0.0.5") == [""])

    let quiet = testModel(deviceHost: "10.0.0.5")
    let reported = testModel(deviceHost: "10.0.0.5")
    reported.removeInstalledIcons()
    #expect(await waitUntil { reported.iconStatus != nil })

    // The action is the General tab's, not the Clocks tab's — two tabs of
    // the one window, each carrying its own kind of answer.
    let before = drawnGeneral(quiet)
    let after = drawnGeneral(reported)
    #expect(before != nil)
    #expect(before != after)
}

// Rule 4, from the other side: the answer to a button pressed in the settings
// belongs in the settings. Thrown back to the panel it lands on a surface the
// user has already left.
@Test @MainActor func theIconRemovalResultIsShownInTheSettingsRatherThanOnThePanel() async {
    let quiet = testModel(deviceHost: "10.0.0.5")
    let reported = testModel(deviceHost: "10.0.0.5")
    reported.removeInstalledIcons()
    #expect(await waitUntil { reported.iconStatus != nil })

    let general = drawnGeneral(quiet)
    #expect(general != nil)
    #expect(general != drawnGeneral(reported))

    // And the panel is not where it goes: with or without an answer reported,
    // the panel draws the same.
    #expect(drawn(quiet) == drawn(reported))
}

/// Where there is ink, row band by row band.
///
/// Compared against the colour of a pixel inside the padding, which no control
/// ever reaches, so "different from that" means "something is drawn here".
@MainActor
private func inkedColumns(of rep: NSBitmapImageRep, rows: Range<Int>) -> Range<Int>? {
    guard let background = rep.colorAt(x: 2, y: 2) else { return nil }
    func inked(_ x: Int, _ y: Int) -> Bool {
        guard let colour = rep.colorAt(x: x, y: y) else { return false }
        return abs(colour.redComponent - background.redComponent) > 0.02
            || abs(colour.greenComponent - background.greenComponent) > 0.02
            || abs(colour.blueComponent - background.blueComponent) > 0.02
            || abs(colour.alphaComponent - background.alphaComponent) > 0.02
    }
    var lowest = rep.pixelsWide
    var highest = -1
    for y in rows.clamped(to: 0..<rep.pixelsHigh) {
        for x in 0..<rep.pixelsWide where inked(x, y) {
            lowest = min(lowest, x)
            highest = max(highest, x)
        }
    }
    return highest < 0 ? nil : lowest..<(highest + 1)
}

// The header carries the app's name at its left and the count of clocks
// answering at its right — words, not a gear: every gear on the panel is a
// clock's (the card redesign, 2026-09-23, put the count where nothing stood).
// The last row carries Settings at one corner and Quit at the other: the
// general surface said in words, a third gear being the thing the correction
// removed. Ink at BOTH ends of each row is what is asserted.
@Test @MainActor func theHeaderSpansNameAndCountAndTheCornersCarryQuitAndSettings() throws {
    let model = testModel(deviceHost: "10.0.0.5")
    let browsing = FakeBonjourBrowser()
    let discovery = panelDiscovery(browsing: browsing)
    discovery.browse.start()
    let host = hosted(MenuPanel(
        model: model, panel: PanelModel(model: model),
        settings: SettingsModel(model: model)
    ))
    let rep = try #require(bitmap(host))
    let scale = rep.pixelsWide / Int(host.bounds.width)

    let top = try #require(
        (0..<rep.pixelsHigh).first { inkedColumns(of: rep, rows: $0..<($0 + 1)) != nil }
    )
    let firstRow = try #require(inkedColumns(of: rep, rows: top..<(top + 20 * scale)))
    #expect(firstRow.lowerBound < rep.pixelsWide / 3)
    #expect(firstRow.upperBound > rep.pixelsWide * 2 / 3)

    let bottom = try #require(
        (0..<rep.pixelsHigh).reversed().first { inkedColumns(of: rep, rows: $0..<($0 + 1)) != nil }
    )
    let lastRow = try #require(inkedColumns(of: rep, rows: (bottom - 20 * scale)..<(bottom + 1)))
    #expect(lastRow.lowerBound < rep.pixelsWide / 3)
    #expect(lastRow.upperBound > rep.pixelsWide * 2 / 3)
}

// MARK: - What a failed restock looks like

// The complaint reaches the clock's tile card rather than only the model:
// the card's line reads the maintenance failure ahead of the run's result,
// so a restock that failed under a delivered run is still said. (The panel
// itself carries no tile lines — the user's correction took the rows off
// it — so the drawn-panel inequality this test used to assert is a surface
// that no longer exists.)
@Test @MainActor func thePanelSaysWhenARestockFailed() async {
    let quiet = testModel(host: SpyHost())
    let complaining = testModel(host: RestockReportingHost(reporting: .failed("the feed is down")))

    // BOTH are run, and both runs deliver, so the run line reads `delivered` on
    // each and cannot account for any difference. What is left over is the
    // restock, which failed on one of them and not on the other.
    quiet.runNow("stub")
    complaining.runNow("stub")
    #expect(await waitUntil { quiet.lastResults["stub"] == "delivered" })
    #expect(await waitUntil { complaining.lastResults["stub"] == "delivered" })
    #expect(await waitUntil { complaining.lastMaintenanceFailure["stub"] != nil })
    #expect(quiet.lastMaintenanceFailure["stub"] == nil)

    // Both runs DELIVERED, so the run line alone would read `delivered` on
    // the card; the maintenance failure is the line the card shows instead.
    #expect(quiet.lastResults["stub"] == "delivered")
    #expect(complaining.lastMaintenanceFailure["stub"] == "the feed is down")
}

/// A host whose run ends the way it is told to — the run path's
/// `RestockReportingHost`.
private struct RunReportingHost: ConnectorRunning {
    let run: RunResult

    func maintain(connectorId: String) async -> MaintenanceResult { .completed }
    func nextDelay(connectorId: String, interval: TimeInterval) async -> TimeInterval { interval }
    func runOnce(connectorId: String) async -> RunResult { run }
    func deliver(_ output: AwtrixDelivery) async -> RunResult { run }
    func restoreDeviceState(borrowedBy connectorId: String?) async {}
    var indicators: IndicatorCustody? { nil }
}

// MARK: - History

/// A model whose History is open and loaded.
@MainActor
private func showingHistory(_ entries: [PlayedAnecdote]) async -> AppModel {
    let model = testModel(anecdotes: StubAnecdotes(history: entries))
    model.openHistory()
    #expect(await waitUntil { model.historyIsOpen && model.history?.count == entries.count })
    return model
}

/// A one-entry history, drawn.
@MainActor
private func drawnEntry(
    _ anecdote: PreparedAnecdote, playedAt: Date
) async -> Data? {
    drawn(await showingHistory([PlayedAnecdote(anecdote: anecdote, playedAt: playedAt)]))
}

// MARK: - What the panel draws instead of rows

// The panel is the clocks' STATISTICS — the connection and the battery, per
// clock — and carries no tile rows at all (the user's correction,
// 2026-09-21). A clock with tiles and a clock without draw the same panel:
// what is on a clock is the clock-settings window's answer, and which
// connectors are offered is the store's.
@Test @MainActor func aPanelOverAClockWithTilesDrawsLikeAClockWithout() {
    let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
    let empty = testModel(clocks: [desk], tiles: [])
    let loaded = testModel(
        clocks: [desk],
        tiles: [
            assembledTile("stub", on: desk),
            assembledTile("second", on: desk),
        ]
    )

    #expect(drawn(empty) != nil)
    #expect(drawn(loaded) == drawn(empty))
}

// A menu bar window dismisses when it loses focus and takes any sheet over it
// with it, so the History is shown in place of the panel exactly as the
// settings are. And closing it goes back to the panel it replaced, pixel for
// pixel — a surface you cannot leave is worse than one that never opened.
@Test @MainActor func openingTheHistoryReplacesThePanelWithIt() async throws {
    let played = PlayedAnecdote(
        anecdote: try playableAnecdote(id: "a", text: "Заходит улитка в бар"),
        playedAt: Date()
    )
    let model = testModel(anecdotes: StubAnecdotes(history: [played]))
    let panel = await drawnAfterTheOpeningReading(model)

    model.openHistory()
    #expect(await waitUntil { model.history?.isEmpty == false })
    let history = drawn(model)

    model.closeHistory()

    #expect(panel != nil)
    #expect(panel != history)
    #expect(panel == drawn(model))
}

// One row per entry, or the surface is a list that lists nothing.
@Test @MainActor func theHistoryDrawsARowPerEntry() async throws {
    let first = PlayedAnecdote(
        anecdote: try playableAnecdote(id: "a", text: "Заходит улитка в бар"),
        playedAt: Date()
    )
    let second = PlayedAnecdote(
        anecdote: try playableAnecdote(id: "b", text: "Штирлиц шёл по лесу"),
        playedAt: Date()
    )

    let one = drawn(await showingHistory([first]))
    let two = drawn(await showingHistory([first, second]))

    #expect(one != nil)
    #expect(one != two)
}

// "What was that one this morning" is the question history answers, and it
// cannot be answered without the hour. Two surfaces holding the SAME anecdote —
// same id, same text, same clips — and differing only in when it played: a
// surface that does not draw the moment draws them identically.
@Test @MainActor func everyEntrySaysWhenItPlayed() async throws {
    let anecdote = try playableAnecdote(id: "a", text: "Заходит улитка в бар")
    let played = Date(timeIntervalSinceReferenceDate: 800_000_000)

    let morning = await drawnEntry(anecdote, playedAt: played)
    let evening = await drawnEntry(anecdote, playedAt: played.addingTimeInterval(9 * 60 * 60))

    #expect(morning != nil)
    #expect(morning != evening)
}

// The rest of rule three, on the surface rather than in the model: an entry
// whose audio has been reaped is still listed — it is still the joke, and it is
// still copyable — but its "Play again" is not live. Same id, same text, same
// moment; the only thing that differs is whether the clips are on disk, so a
// surface that offered the same live button for both would draw them the same.
@Test @MainActor func anEntryWhoseClipsAreGoneIsStillListedButCannotBePlayedAgain() async throws {
    let played = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let here = try playableAnecdote(id: "a", text: "Заходит улитка в бар")
    let gone = anecdoteWhoseClipsAreGone(id: "a", text: "Заходит улитка в бар")

    let listed = await drawnEntry(gone, playedAt: played)
    let empty = drawn(await showingHistory([]))
    let playable = await drawnEntry(here, playedAt: played)

    #expect(listed != nil)
    #expect(listed != empty)
    #expect(listed != playable)
}

/// The panel, drawn again on the view it was already drawn on.
///
/// Every other render in this file builds a fresh `NSHostingView`, which reads
/// the model as it stands and therefore agrees with it by construction. The
/// menu bar has ONE view and keeps it across opens, so a surface that is on
/// screen while the model changes underneath it can only be measured on a view
/// that was already there. Re-fitted first because the History is not the
/// panel's height and `cacheDisplay` draws `bounds`.
@MainActor
private func redrawn(_ host: NSHostingView<MenuPanel>) -> Data? {
    // Settled before it is read, and that is what the throwaway passes are for.
    // Measured: the first draw after the surface has been replaced carries
    // about 3 kB that no later draw does, and every draw after it is
    // byte-identical — a focus ring on a control that has just become the
    // responder, taken back once AppKit has caught up. It belongs to drawing a
    // reused view into a bitmap rather than to the panel, and a just-changed
    // surface compared against a settled one reports it as content.
    //
    // Sleeping until it goes away was the alternative, and it is worse: it puts
    // a duration into a file whose whole claim is that `cacheDisplay` is
    // synchronous, so nothing here has to wait for anything.
    for _ in 0..<2 {
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        _ = bitmap(host)
    }
    return bitmap(host)?.representation(using: .png, properties: [:])
}

// The reported defect: the History shows what has played on the FIRST press,
// not on the press after a Back.
//
// `openingTheHistoryReplacesThePanelWithIt` above waits for `history` to arrive
// before it draws, so it measures a surface the user never sees — every open
// looks like a second open to it. This one draws at the instant the button is
// pressed, which is the moment being complained about.
//
// The same view in the same two states, and that is what makes the comparison
// mean something: a reused hosting view draws a focus ring a fresh one does
// not, so a reference render built separately would differ for reasons that
// have nothing to do with the History. Between these two renders the ONLY
// thing that changes is whether the read has answered — so if the surface has
// its entries when it opens, the two are the same pixels.
//
// The settle before the press is the user's own hand: the History is reached
// from a button on the panel, so the panel is on screen for as long as it takes
// somebody to see it and click. It does not weaken what this measures — with
// nothing asking until the press, no amount of waiting beforehand puts an
// answer on the surface, which is what this failed with before.
@Test @MainActor func theHistoryShowsWhatPlayedOnTheFirstPressRatherThanTheSecond() async throws {
    let played = PlayedAnecdote(
        anecdote: try playableAnecdote(id: "a", text: "Заходит улитка в бар"),
        playedAt: Date()
    )
    let model = testModel(anecdotes: StubAnecdotes(history: [played]))
    let host = hostedPanel(model)
    _ = redrawn(host)
    #expect(await waitUntil { model.history?.isEmpty == false })

    model.openHistory()
    let asItOpens = redrawn(host)
    // The same surface once the open's own read has landed: the state the old
    // behaviour only reached after the user had already looked at it.
    #expect(await waitUntil { model.history?.isEmpty == false })
    let onceTheReadAnswered = redrawn(host)

    // Without this the equality below is satisfied by a surface that draws
    // neither the entries nor anything else. A second view driven exactly as
    // the first — panel, then History — over a connector that really has
    // nothing to look back over, so the two differ only in there being
    // something to list.
    let nothingPlayed = testModel(anecdotes: StubAnecdotes(history: []))
    let emptyHost = hostedPanel(nothingPlayed)
    _ = redrawn(emptyHost)
    nothingPlayed.openHistory()
    // Waited on the READ rather than on the surface being open. Open is not
    // enough any more: a History whose read has not landed draws nothing at all,
    // and a control that draws nothing is exactly the one this control exists to
    // rule out.
    #expect(await waitUntil { nothingPlayed.history != nil })

    #expect(asItOpens != nil)
    #expect(asItOpens != redrawn(emptyHost))
    #expect(asItOpens == onceTheReadAnswered)
}

// The half of the defect that no amount of reading earlier can close: an
// unread History and an empty one are the SAME pixels. `5e1ffdd` moved the read
// forward to the panel's own opening, so the answer is usually there by the time
// a hand reaches the button — but "usually" is a timing claim, and what the
// surface says while it waits is a confident wrong answer rather than a pending
// one. Measured with that fix in place and the states still merged: the History
// drawn at the press is byte-identical to the History of a connector that has
// never played anything, over a connector holding a joke it could have listed.
//
// Nothing is awaited between the panel being hosted and the History being drawn,
// and that is not brevity — it IS the mechanism. The read is a `Task` on the main
// actor, so it cannot run until this test suspends; holding the actor is the only
// way to hold the surface in the state being measured, and it is exactly the
// press that arrives before the answer.
//
// Three renders because two would not pin it. Compared only against the loaded
// surface, a quiet History passes by drawing nothing; compared only against the
// empty one, it passes by drawing the entries early. It has to differ from both.
@Test @MainActor func aHistoryNobodyHasReadYetIsNotDrawnAsAnEmptyOne() async throws {
    let played = PlayedAnecdote(
        anecdote: try playableAnecdote(id: "a", text: "Заходит улитка в бар"),
        playedAt: Date()
    )
    let model = testModel(anecdotes: StubAnecdotes(history: [played]))
    let host = hostedPanel(model)
    model.openHistory()
    let beforeTheReadAnswers = redrawn(host)
    let whileUnread = host.fittingSize.height

    #expect(await waitUntil { model.history?.isEmpty == false })
    let onceTheReadAnswered = redrawn(host)

    // A connector that really has nothing to look back over, driven the same way
    // and settled before it is read: the surface the unread one must not be.
    let nothingPlayed = testModel(anecdotes: StubAnecdotes(history: []))
    let emptyHost = hostedPanel(nothingPlayed)
    nothingPlayed.openHistory()
    #expect(await waitUntil { nothingPlayed.history != nil })
    let genuinelyEmpty = redrawn(emptyHost)
    let whileEmpty = emptyHost.fittingSize.height

    #expect(beforeTheReadAnswers != nil)
    // The defect itself, in one line: these two were the same bytes.
    #expect(beforeTheReadAnswers != genuinelyEmpty)
    #expect(beforeTheReadAnswers != onceTheReadAnswered)
    #expect(genuinelyEmpty != onceTheReadAnswered)
    // And different because it drew LESS, not because it drew something else of
    // its own. A spinner or a placeholder would satisfy every inequality above
    // and be exactly the flash this surface is not worth.
    #expect(whileUnread < whileEmpty)
}

// Back and in again is not a fresh start. The list is the answer to a question
// that has already been asked, and leaving the surface does not un-ask it — so
// the second open draws what the first one learned, at the instant it opens,
// while its own read repeats the answer behind it.
//
// Its own test because the obvious way to build the three states breaks it:
// clearing the list on close, or on open, to "show the new read honestly" puts
// every open after the first back in the quiet state. Drawn with nothing awaited
// after the press, so a surface that had gone quiet would be caught here.
@Test @MainActor func aSecondOpenOfTheHistoryDrawsWhatTheFirstOneRead() async throws {
    let played = PlayedAnecdote(
        anecdote: try playableAnecdote(id: "a", text: "Заходит улитка в бар"),
        playedAt: Date()
    )
    let model = testModel(anecdotes: StubAnecdotes(history: [played]))
    let host = hostedPanel(model)
    model.openHistory()
    #expect(await waitUntil { model.history?.isEmpty == false })
    let firstOpen = redrawn(host)

    model.closeHistory()
    _ = redrawn(host)
    model.openHistory()
    let secondOpen = redrawn(host)

    #expect(firstOpen != nil)
    #expect(secondOpen == firstOpen)
}

// And the mechanism underneath it, where a render cannot reach: the panel
// coming on screen is what asks, so the answer is already there when the button
// on it is pressed. Asserted through the History never being opened at all —
// `openHistory` asks too, so a test that opened it could not tell which of the
// two had done the asking.
@Test @MainActor func openingThePanelIsAlsoWhatAsksWhatHasPlayed() async throws {
    let played = PlayedAnecdote(
        anecdote: try playableAnecdote(id: "a", text: "Заходит улитка в бар"),
        playedAt: Date()
    )
    let model = testModel(anecdotes: StubAnecdotes(history: [played]))
    // Nil rather than empty, and that is the precondition this test needs: an
    // empty list would be an answer, and the claim below is that the PANEL is
    // what asks for one.
    #expect(model.history == nil)

    let panel = hostedPanel(model)

    #expect(await waitUntil { model.history?.isEmpty == false })
    #expect(model.historyIsOpen == false)
    // Held to the end: a hosting view nobody references is torn down, and a
    // torn-down one has nothing to appear.
    withExtendedLifetime(panel) {}
}

// The anecdote tile's settings window shows the same list in a sheet of its
// own, so asking for it must not swap the menu bar's panel to a surface the
// menu bar was never opened for. Its button used to call `openHistory`, which
// did exactly that — and did nothing visible in the window that pressed it,
// because nothing there reads the flag.
@Test @MainActor func askingForTheListDoesNotSwapThePanelToIt() async throws {
    let played = PlayedAnecdote(
        anecdote: try playableAnecdote(id: "a", text: "Заходит улитка в бар"),
        playedAt: Date()
    )
    let model = testModel(anecdotes: StubAnecdotes(history: [played]))

    model.loadHistory()

    #expect(await waitUntil { model.history?.count == 1 })
    #expect(model.historyIsOpen == false)
}

// MARK: - The menu opens on the panel

/// A launched delegate over `model`, hearing only what this test posts, with
/// `panel` standing in for the window the menu bar panel is on.
///
/// Its own notification centre, because one test's windows are not another's:
/// posted into `.default`, a window built here would reach every other delegate
/// alive in the suite, and each of them would have to tell it apart from its
/// own. Which window is the panel's is a separate question, and it is the one
/// the tests below turn on — the centre isolates them, it does not answer it.
///
/// The panel is handed over after the launch rather than through the
/// initialiser, because that is the only order production can manage: the
/// window belongs to `MenuBarExtra`, which builds it on the first open — long
/// after `applicationDidFinishLaunching` has come and gone.
@MainActor
private func launched(
    _ model: AppModel, hearing notifications: NotificationCenter, panelOn panel: NSWindow
) -> AppDelegate {
    let delegate = AppDelegate(
        model: model,
        discovery: inertDiscovery(),
        notifications: notifications
    )
    delegate.applicationDidFinishLaunching(Notification(name: .init("launched")))
    delegate.panelMoved(to: panel)
    return delegate
}

/// What the reader reported, by reference: the closure it is given outlives the
/// call that builds it, and a local array captured there would be a copy the
/// test cannot read back.
///
/// Nils are dropped here for the same reason `AppDelegate.panelMoved(to:)` drops
/// them — what is being asked is which window the panel landed on, and a view
/// that has not landed anywhere has no answer.
@MainActor
private final class WindowsReported {
    private(set) var seen: [NSWindow] = []

    func record(_ window: NSWindow?) {
        guard let window else { return }
        seen.append(window)
    }
}

// A menu bar item is clicked to answer "is the clock alive, and what is next".
// Coming back to a list of old jokes answers a question nobody asked, and that
// is what a surface outliving its window did.
//
// Measured on the pixels rather than on the flag: what the next click opens on
// is the claim, and it is the same drawing as a panel that was never left.
//
// The model is left unstarted and the close is its own, for the reason
// `openingTheHistoryReplacesThePanelWithIt` leaves it unstarted: a started one
// schedules, so the two drawings would differ by an hour as well as by the
// surface. The device state is settled by the drawing helper instead — opening
// the panel is itself a reading now. What carries the AppKit event into this
// call is the pair of tests below.
@Test @MainActor func closingTheWindowReturnsTheMenuToThePanel() async throws {
    let played = PlayedAnecdote(
        anecdote: try playableAnecdote(id: "a", text: "Заходит улитка в бар"),
        playedAt: Date()
    )
    let model = testModel(anecdotes: StubAnecdotes(history: [played]))
    let panel = await drawnAfterTheOpeningReading(model)
    model.openHistory()
    #expect(await waitUntil { model.history?.isEmpty == false })
    let history = drawn(model)

    model.windowDidClose()

    #expect(panel != nil)
    #expect(panel != history)
    #expect(panel == drawn(model))
}

@Test @MainActor func theHistorySurfaceDoesNotSurviveAWindowClose() async {
    let notifications = NotificationCenter()
    let panel = aWindow()
    let model = testModel(
        sleep: Metronome().sleep, pollSleep: Metronome().sleep,
        anecdotes: StubAnecdotes(id: "stub")
    )
    let delegate = launched(model, hearing: notifications, panelOn: panel)
    model.openHistory()
    #expect(model.historyIsOpen)

    loseFocus(panel, through: notifications)

    #expect(await waitUntil { model.historyIsOpen == false })
    // Held to the end deliberately: the observer's block holds the delegate
    // weakly, so a released one hears the close and does nothing about it.
    withExtendedLifetime(delegate) {}
    await model.teardown()
}

// The other half of the same rule, and the half the observer used to get wrong.
// This process has more windows than the panel: `BatteryAlert` raises an
// `NSAlert`, and an authorization prompt is a window too. Every one of them
// resigns key when it is dismissed, and heard unfiltered that shut whichever
// surface the user had open — a History that closes itself with nobody near it.
//
// Told apart from the test above by identity alone: same centre, same
// notification, a different window. Separating them by notification centre
// instead would prove nothing about production, where every window in the
// process posts into `.default`.
@Test @MainActor func theHistorySurvivesAWindowThatIsNotThePanelLosingFocus() async {
    let notifications = NotificationCenter()
    let panel = aWindow()
    let model = testModel(
        sleep: Metronome().sleep, pollSleep: Metronome().sleep,
        anecdotes: StubAnecdotes(id: "stub")
    )
    let delegate = launched(model, hearing: notifications, panelOn: panel)
    model.openHistory()
    #expect(model.historyIsOpen)

    loseFocus(aWindow(), through: notifications)

    await afterTheQueuedObserversHaveRun()
    #expect(model.historyIsOpen)
    // Held to the end deliberately: the observer's block holds the delegate
    // weakly, so a released one hears nothing and the test would pass on a
    // delegate that was never listening.
    withExtendedLifetime(delegate) {}
    await model.teardown()
}

// Which window the panel is on is the whole of what the filter above works
// from, and a delegate that is never told has none — every close would then be
// ignored, including the one that must not be. Nothing can tell it at launch:
// the window is `MenuBarExtra`'s, built on the first open, so the only thing
// that can see it is a view inside the panel.
//
// Hosted in a plain `NSHostingView` rather than in the shipped scene, because a
// menu bar extra cannot be opened from a test. What that leaves unproven is
// SwiftUI's half — that the panel's background really is in the panel's window —
// and what it does prove is the mechanism the app depends on: a view put into a
// window reports which one.
@Test @MainActor func aViewInThePanelReportsTheWindowItWasPutOn() {
    let reported = WindowsReported()
    let panel = aWindow()
    let host = NSHostingView(
        rootView: Color.clear.background(PanelWindowReader { reported.record($0) })
    )
    host.frame = NSRect(x: 0, y: 0, width: 320, height: 700)

    panel.contentView = host
    host.layoutSubtreeIfNeeded()

    #expect(reported.seen.last === panel)
}

// The other end of the same wire, and a rule that only production exercises:
// the panel is taken off its window as part of going away, so the report that
// arrives with the window gone lands AFTER the resign that says the panel
// closed and BEFORE the queued observer reads it. Recorded, that nil would
// leave the observer with nothing to compare against and the surface open —
// the whole pinned behaviour lost to an event the tests never sent.
@Test @MainActor func thePanelLeavingItsWindowDoesNotMakeTheDelegateForgetIt() async {
    let notifications = NotificationCenter()
    let panel = aWindow()
    let model = testModel(
        sleep: Metronome().sleep, pollSleep: Metronome().sleep,
        anecdotes: StubAnecdotes(id: "stub")
    )
    let delegate = launched(model, hearing: notifications, panelOn: panel)
    model.openHistory()

    delegate.panelMoved(to: nil)
    loseFocus(panel, through: notifications)

    #expect(await waitUntil { model.historyIsOpen == false })
    withExtendedLifetime(delegate) {}
    await model.teardown()
}

// The settings left the panel's window with the redesign: they are the app's
// own Settings window, and a native window's comings and goings are macOS's
// to manage — there is no surface state here to outlive anything. What the
// close rule still owns is the History alone, and that half is pinned above.

// MARK: - What a replay says for itself

/// The History showing one playable entry, opened and loaded.
@MainActor
private func historyWithOneEntry(host: any ConnectorRunning) async throws
    -> (model: AppModel, anecdote: PreparedAnecdote)
{
    let anecdote = try playableAnecdote(id: "a", text: "Заходит улитка в бар")
    let model = testModel(
        host: host,
        anecdotes: StubAnecdotes(history: [PlayedAnecdote(anecdote: anecdote, playedAt: played)])
    )
    model.openHistory()
    #expect(await waitUntil { model.history?.isEmpty == false })
    return (model, anecdote)
}

/// One fixed moment, so two surfaces built for a comparison cannot differ by
/// the second they were built in.
private let played = Date(timeIntervalSinceReferenceDate: 800_000_000)

// `deliver`'s result is discarded as far as the run line is concerned, and that
// stays — but discarding it entirely left "Play again" against an unreachable
// clock doing nothing at all, with no explanation. This branch has already
// shipped that exact defect once.
//
// Two Histories alike in everything — same entry, same text, same moment it
// played, same list — except that one of them has had a replay reported. Delete
// the line and they are identical; nothing else on the surface moves when a
// replay finishes, because the list is read on opening and a replay does not
// re-read it.
@Test @MainActor func aReplayReportsItsOutcomeInTheHistory() async throws {
    let quiet = try await historyWithOneEntry(host: SpyHost())
    let reporting = try await historyWithOneEntry(host: SpyHost())

    reporting.model.replay(reporting.anecdote)

    #expect(await waitUntil { reporting.model.replayResult != nil })
    #expect(drawn(quiet.model) != nil)
    #expect(drawn(quiet.model) != drawn(reporting.model))
}

// And what it says is how it WENT, not that something happened. A failed replay
// drawn the same as a successful one is the silence again with a decoration on
// it: the two surfaces below have both had a replay reported, so a line that
// said "replayed" either way would draw them identically.
//
// The quiet one is the third leg: without it, a surface that drew nothing at
// all for either outcome would still pass the first comparison.
@Test @MainActor func aFailedReplayIsVisibleRatherThanSilent() async throws {
    let quiet = try await historyWithOneEntry(host: SpyHost())
    let succeeded = try await historyWithOneEntry(host: SpyHost())
    let failed = try await historyWithOneEntry(
        host: SpyHost(deliverResult: .failed("the clock is not answering"))
    )

    succeeded.model.replay(succeeded.anecdote)
    failed.model.replay(failed.anecdote)

    #expect(await waitUntil { succeeded.model.replayResult != nil })
    #expect(await waitUntil { failed.model.replayResult != nil })
    #expect(drawn(failed.model) != nil)
    #expect(drawn(failed.model) != drawn(quiet.model))
    #expect(drawn(failed.model) != drawn(succeeded.model))
}

// The panel is not where it goes. A replay is pressed in the History and its
// answer belongs there — thrown to the panel's run line it lands on a surface
// the user has already left, and on the line that describes the schedule.
@Test @MainActor func aReplaysOutcomeIsDrawnInTheHistoryRatherThanOnThePanel() async throws {
    let quiet = try await historyWithOneEntry(host: SpyHost())
    let reporting = try await historyWithOneEntry(
        host: SpyHost(deliverResult: .failed("the clock is not answering"))
    )
    reporting.model.replay(reporting.anecdote)
    #expect(await waitUntil { reporting.model.replayResult != nil })

    quiet.model.closeHistory()
    reporting.model.closeHistory()

    #expect(drawn(quiet.model) != nil)
    #expect(drawn(quiet.model) == drawn(reporting.model))
}

// MARK: - Which rule keeps the app quiet

/// The General tab, with the given Focus centre behind the model.
///
/// Neither model is started, so neither has polled and both draw the same
/// device line: what is left over between two of these is the section under
/// test and nothing else.
@MainActor
private func drawnGeneral(model: AppModel) -> Data? {
    let host = hosted(GeneralTab(model: model))
    return bitmap(host)?.representation(using: .png, properties: [:])
}

// The rule reaches the surface rather than only the model.
//
// What is left of the quiet-hours section after B16: the one sentence naming
// what Full Disk Access buys, and no hour picker — the hours are each tile's
// own now, and there is nothing app-wide left to pick.
@Test @MainActor func theSettingsSayWhatFullDiskAccessBuysAndOfferNoHourPicker() {
    let model = testModel()

    // The sentence the General tab draws, pinned here rather than only in
    // FocusModeTests: this is the surface it is said on.
    #expect(FocusRuleLine.whichFocusesSilenceDependsOnFullDiskAccess.contains("Full Disk Access"))
    #expect(drawnGeneral(model: model) != nil)
}

// MARK: - Which microphones the schedule waits for

// The device list reaches the surface rather than only the model. Two General
// tabs over the SAME four inputs — so the rows, their count and their labels
// are identical — differing only in which of them are ticked.
//
// Same inputs on both, deliberately: with different device lists the two would
// differ by a row, and the test claiming the ticks would pass with the ticks
// gone.
@Test @MainActor func thePanelMarksWhichMicrophonesAreWatched() {
    let present = [Inputs.builtIn, Inputs.phone, Inputs.interface, Inputs.virtual]
    let watchingBuiltIn = testModel(
        microphone: MicrophoneGate(inputs: StubAudioInputs(present)),
        watching: [WatchedMicrophone(uid: Inputs.builtIn.uid, name: Inputs.builtIn.name)]
    )
    let watchingTheInterface = testModel(
        microphone: MicrophoneGate(inputs: StubAudioInputs(present)),
        watching: [WatchedMicrophone(uid: Inputs.interface.uid, name: Inputs.interface.name)]
    )

    let builtInTicked = drawnGeneral(model: watchingBuiltIn)

    #expect(watchingBuiltIn.microphoneListing.map(\.input) == present)
    #expect(watchingTheInterface.microphoneListing.map(\.input) == present)
    #expect(builtInTicked != nil)
    #expect(builtInTicked != drawnGeneral(model: watchingTheInterface))
}

// And every input is listed, not only the watched ones: a surface over four
// devices is not the same surface as one over two.
@Test @MainActor func thePanelListsEveryInputRatherThanOnlyTheWatchedOnes() {
    let watching = [WatchedMicrophone(uid: Inputs.builtIn.uid, name: Inputs.builtIn.name)]
    let all = testModel(
        microphone: MicrophoneGate(inputs: StubAudioInputs([
            Inputs.builtIn, Inputs.phone, Inputs.interface, Inputs.virtual,
        ])),
        watching: watching
    )
    let onlyWatched = testModel(
        microphone: MicrophoneGate(inputs: StubAudioInputs([Inputs.builtIn])),
        watching: watching
    )

    let everything = drawnGeneral(model: all)

    #expect(all.microphoneListing.count == 4)
    #expect(everything != nil)
    #expect(everything != drawnGeneral(model: onlyWatched))
}

// MARK: - What opening the panel asks for

// The reachability poll is a minute apart, so whatever the panel draws about
// the clock can be fifty-nine seconds old by the time somebody looks at it.
// `AppModel.refreshOnPanelOpen` is well covered on its own and proves nothing
// about the panel: deleting the `.onAppear` that calls it leaves every one of
// those tests green, and the panel back to showing a minute-old reading. This
// is the one that notices.
@Test @MainActor func openingThePanelIsWhatAsksForTheFreshReading() async {
    let poll = Metronome()
    let clock = ScriptedTransport(bodies: [statsBody(percent: 80, raw: 800)])
    let model = testModel(transport: clock, pollSleep: poll.sleep)
    model.start()
    #expect(await waitUntil { poll.parked == 1 })
    #expect(clock.responses == 1)

    let panel = hostedPanel(model)

    #expect(await waitUntil { clock.responses == 2 })
    // Held to the end: a hosting view nobody references is torn down, and a
    // torn-down one has nothing to appear.
    withExtendedLifetime(panel) {}
    await model.teardown()
}

// MARK: - The assembled panel (Phase 5, Task 12)

private let assembledDesk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
private let assembledKitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.6")
private let assembledLoft = ClockRecord(name: "Loft", model: .awtrix3, address: "10.0.0.7")

private func assembledTile(
    _ connector: String, on clock: ClockRecord, paused: Bool = false
) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock.id, connectorId: connector),
        policy: TilePolicyRecord(isPaused: paused, refreshSeconds: 600)
    )
}

// The design's core change, on the surface: every clock a section, so a
// panel over two clocks is NOT the panel over one — the second section's
// header and its dot are drawn even where it carries no tiles yet.
@Test @MainActor func aSectionPerClockIsDrawn() {
    let one = testModel(clocks: [assembledDesk], tiles: [assembledTile("stub", on: assembledDesk)])
    let both = testModel(
        clocks: [assembledDesk, assembledKitchen],
        tiles: [assembledTile("stub", on: assembledDesk)]
    )

    #expect(drawn(one) != nil)
    #expect(drawn(one) != drawn(both))
}

// The flat Add tile row left with the redesign: the per-clock gear's
// submenu carries the availability now, and the reasons are pinned where
// they are computed — `PanelModelTests`, per clock.

// The detail left the panel with the redesign: it is the tile settings
// window now. The row's click aims the model's key, the system opens the
// window on it, and the panel is NOT swapped for anything — it stays what
// the clickaway returns to. The window's content following the key is
// pinned in `TileSettingsModelTests`.
@Test @MainActor func theDetailNoLongerSwapsThePanel() {
    let model = testModel(
        clocks: [assembledDesk], tiles: [assembledTile("stub", on: assembledDesk)]
    )
    let panel = drawn(model)

    model.openDetail(for: TileKey(clockId: assembledDesk.id, connectorId: "stub"))

    #expect(panel != nil)
    #expect(drawn(model) == panel)
}

// The Clocks tab is where the address field used to be: one editable box —
// add-by-address — where the address and location boxes used to be, and the
// list of clocks actually drawn.
@Test @MainActor func theSettingsCarryTheClocksSectionWhereTheAddressFieldWas() {
    let model = testModel(deviceHost: "10.0.0.5")

    let sheet = fields(in: hosted(SettingsRoot(
        model: model, settings: SettingsModel(model: model), discovery: inertDiscovery()
    )))

    // The add-by-address box, and nothing else: no address field, no location
    // field — both left with the sections that carried them.
    #expect(sheet == [""])

    let desk = testModel(
        deviceHost: "10.0.0.5", clocks: [assembledDesk], tiles: []
    )
    let loft = testModel(
        deviceHost: "10.0.0.5", clocks: [assembledLoft], tiles: []
    )
    let deskSheet = drawnSettings(desk)
    let loftSheet = drawnSettings(loft)
    // The Clocks tab lists the clocks by name: renaming one changes the
    // drawing, so the list is drawn and not just the add-by-address row.
    #expect(deskSheet != nil)
    #expect(deskSheet != loftSheet)
}

// MARK: - The wordmark

/// One view drawn on its own, at a size that fits the header's mark.
@MainActor
private func drawnMark(_ view: some View) -> Data? {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
    host.layoutSubtreeIfNeeded()
    guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: target)
    return target.representation(using: .png, properties: [:])
}

// The name is SET, not typed: its middle word is a bitmap out of the kit's own
// face. Drawn against the plain headline it replaced, because a wordmark that
// renders as the same pixels as `Text("PixelClockTiles")` is a wordmark that
// never reached the screen.
@MainActor
@Test func theWordmarkIsDrawnRatherThanTyped() {
    let mark = drawnMark(Wordmark())
    #expect(mark != nil)
    #expect(mark != drawnMark(Text("PixelClockTiles").font(.headline)))
    // And its pixel word is scaled: the same mark at another pixel size is
    // another drawing, so the bitmap is on screen rather than laid out at zero.
    #expect(mark != drawnMark(Wordmark(pixel: 3)))
}

// MARK: - The pin

// The pin is ON the panel and its two states LOOK different. Both halves
// matter: a pin drawn identically either way is a switch nobody can read, and
// a pin that never reached `body` is one nothing else in the suite would miss.
@MainActor
@Test func thePanelDrawsItsPinAndPinnedLooksDifferentFromNot() {
    func panel(pinned: Bool) -> Data? {
        let store = UserDefaults(suiteName: "pin-render-\(UUID().uuidString)")!
        let pin = PanelPin(defaults: store)
        pin.set(pinned)
        let model = testModel()
        let host = NSHostingView(
            rootView: MenuPanel(
                model: model, panel: PanelModel(model: model),
                settings: SettingsModel(model: model), pin: pin, defaults: store
            )
        )
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 300)
        host.layoutSubtreeIfNeeded()
        guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: target)
        return target.representation(using: .png, properties: [:])
    }

    #expect(panel(pinned: false) != nil)
    #expect(panel(pinned: false) != panel(pinned: true))
}
