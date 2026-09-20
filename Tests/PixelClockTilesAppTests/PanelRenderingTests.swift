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
    let browser = DeviceBrowser(browsing: { browsing }, sleep: { _ in })
    browser.start()
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
    case .idle: browser.stop()
    case .searching: break
    }
    #expect(browser.state == state, "the double did not reach \(state)")

    let model = testModel(deviceHost: deviceHost)
    let host = NSHostingView(
        rootView: MenuPanel(model: model, monitor: model.monitor, discovery: browser)
    )
    host.frame = NSRect(x: 0, y: 0, width: 320, height: 700)
    host.layoutSubtreeIfNeeded()
    guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: target)
    return target.representation(using: .png, properties: [:])
}

private let oneDevice = DiscoveryState.listed([DiscoveredDevice(instanceName: "awtrix_a07f9c")])

// The feature's only user-visible output. Three states that the pure renderer
// already proves say different things, shown to be different ON THE PANEL —
// which is the claim `DiscoveryStatusLine`'s own tests cannot make.
@Test @MainActor func whatDiscoveryKnowsIsDrawnOnThePanel() {
    let listed = rendered(discovery: oneDevice)
    let denied = rendered(discovery: .denied)
    let searching = rendered(discovery: .searching)

    #expect(listed != nil)
    #expect(listed != denied)
    #expect(listed != searching)
    #expect(denied != searching)
}

// Same drawing twice is the same pixels — otherwise every expectation above
// passes for the wrong reason, on noise rather than on content.
@Test @MainActor func thePanelDrawsTheSameThingTwice() {
    #expect(rendered(discovery: oneDevice) == rendered(discovery: oneDevice))
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

@MainActor
private func panelFields(deviceHost: String) -> [String] {
    let browsing = FakeBonjourBrowser()
    let browser = DeviceBrowser(browsing: { browsing }, sleep: { _ in })
    browser.start()
    let model = testModel(deviceHost: deviceHost)
    let host = NSHostingView(
        rootView: MenuPanel(model: model, monitor: model.monitor, discovery: browser)
    )
    host.frame = NSRect(x: 0, y: 0, width: 320, height: 700)
    host.layoutSubtreeIfNeeded()
    return fields(in: host)
}

// The field moved behind the gear, and its rule moved with it: an editable
// address with this launch's address already in it, not an empty box the user
// has to know what to put in.
//
// Read off the control rather than off the pixels, and that is not fussiness.
// Comparing renders of two differently-addressed surfaces passed with the field
// removed entirely and with its seed emptied: the status line named the same
// address, so it accounted for the whole difference. The test claimed the field
// and was measuring the line above it.
// And what is in it is what WILL be saved, not what is in use. The two are the
// same on a launch nobody has typed into, so a field bound to `deviceHost`
// instead of `typedHost` passes every test above — this is the one that tells
// them apart.
@Test @MainActor func theFieldShowsWhatTheNextLaunchWillUseRatherThanThisOne() {
    let model = testModel(deviceHost: "192.168.1.72")

    model.typedHost = "10.0.0.9"

    #expect(fields(in: hosted(SettingsSheet(model: model))) == ["10.0.0.9", seededLocation])
    #expect(model.deviceHost == "192.168.1.72")
}

@Test @MainActor func theAddressThisLaunchUsesIsInTheFieldInTheSettings() {
    #expect(settingsFields(deviceHost: "192.168.1.72") == ["192.168.1.72", seededLocation])
    #expect(settingsFields(deviceHost: "10.0.0.9") == ["10.0.0.9", seededLocation])
}

// A browse that cannot run has to look different from a network with nothing
// on it, on the panel and not only in the function that words it — this is the
// state the review found folded into "no devices" one layer down.
@Test @MainActor func aNetworkTheAppCannotBrowseLooksDifferentFromAnEmptyOne() {
    let unavailable = rendered(discovery: .unavailable("-65563: NoAuth"))
    let empty = rendered(discovery: .listed([]))

    #expect(unavailable != nil)
    #expect(unavailable != empty)
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
private func renderedGlyph(lit: Bool) -> Data? {
    renderedInTheBar(Image(nsImage: AppGlyph.menuBar(lit: lit)))
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
    #expect(renderedGlyph(lit: true) != nil)
    #expect(online == renderedGlyph(lit: true))
    #expect(offline == renderedGlyph(lit: false))
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
    return fields(in: hosted(SettingsSheet(model: model)))
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
    let browser = DeviceBrowser(browsing: { browsing }, sleep: { _ in })
    browser.start()
    return hosted(MenuPanel(model: model, monitor: model.monitor, discovery: browser))
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
    let browser = DeviceBrowser(browsing: { browsing }, sleep: { _ in })
    browser.start()
    return fields(in: hosted(MenuPanel(model: model, monitor: model.monitor, discovery: browser)))
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

@Test @MainActor func theSettingsHoldTheAddressFieldAndTheIconAction() async {
    #expect(settingsFields(deviceHost: "10.0.0.5") == ["10.0.0.5", seededLocation])

    let quiet = testModel(deviceHost: "10.0.0.5")
    let reported = testModel(deviceHost: "10.0.0.5")
    reported.removeInstalledIcons()
    #expect(await waitUntil { reported.iconStatus != nil })

    let before = bitmap(hosted(SettingsSheet(model: quiet)))?.representation(using: .png, properties: [:])
    let after = bitmap(hosted(SettingsSheet(model: reported)))?.representation(using: .png, properties: [:])
    #expect(before != nil)
    #expect(before != after)
}

// Rule 4, from the other side: the answer to a button pressed in the settings
// belongs in the settings. Thrown back to the panel it lands on a surface the
// user has already left.
@Test @MainActor func theIconRemovalResultIsShownInTheSettingsRatherThanOnThePanel() async {
    let model = testModel(deviceHost: "10.0.0.5")
    model.openSettings()
    let quiet = drawn(model)

    model.removeInstalledIcons()
    #expect(await waitUntil { model.iconStatus != nil })

    #expect(quiet != nil)
    #expect(quiet != drawn(model))
}

// Opening them swaps what the panel draws. This is the flag, not the gear —
// a SwiftUI `Button`'s action cannot be invoked without a window and a run
// loop, so what the gear does when clicked stays on the list only a person can
// check, exactly as "Run now is wired to anything" does.
@Test @MainActor func openingTheSettingsReplacesThePanelWithThem() {
    let model = testModel(deviceHost: "10.0.0.5")

    #expect(panelControls(model).isEmpty)

    model.openSettings()

    #expect(panelControls(model) == ["10.0.0.5", seededLocation])

    model.closeSettings()

    #expect(panelControls(model).isEmpty)
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

// Rule 2, and it needs both halves of one measurement rather than a look at the
// corner. The gear is at the right end of the row the Quit button is already on,
// so the LAST inked row of the panel has ink at both ends: the button on the
// left, the gear on the right. A gear given a row of its own would put ink only
// at the right end of the last row and only at the left end of the row above —
// which is the arrangement this rules out, and a corner sample could not.
//
// What it cannot say is that the mark is a gear or that pressing it does
// anything. Both are on the list only a person can check.
@Test @MainActor func theGearIsAtTheEndOfTheRowTheQuitButtonIsOnRatherThanOnARowOfItsOwn() throws {
    let model = testModel(deviceHost: "10.0.0.5")
    let browsing = FakeBonjourBrowser()
    let browser = DeviceBrowser(browsing: { browsing }, sleep: { _ in })
    browser.start()
    let host = hosted(MenuPanel(model: model, monitor: model.monitor, discovery: browser))
    let rep = try #require(bitmap(host))
    let scale = rep.pixelsWide / Int(host.bounds.width)

    let bottom = try #require(
        (0..<rep.pixelsHigh).reversed().first { inkedColumns(of: rep, rows: $0..<($0 + 1)) != nil }
    )
    // The last row, and only it: anchored to the bottom-most ink and 20 points
    // tall, so the divider above cannot answer for the gear.
    let lastRow = try #require(inkedColumns(of: rep, rows: (bottom - 20 * scale)..<(bottom + 1)))

    #expect(lastRow.lowerBound < rep.pixelsWide / 3)
    #expect(lastRow.upperBound > rep.pixelsWide * 2 / 3)
}

// MARK: - When the next one is due

/// A model that has been started, whose schedule is due in `delay` seconds and
/// whose reachability poll has already answered.
///
/// Both halves matter. An unstarted model has an `.unknown` device state where a
/// started one has `.offline`, and the status line says different words for the
/// two — which is enough on its own to make two panels differ, and is how the
/// first version of the test below passed with the due label deleted.
@MainActor
private func scheduledModel(dueIn delay: TimeInterval) async -> AppModel {
    let schedule = Metronome()
    let model = testModel(host: SpyHost(delay: delay), sleep: schedule.sleep)
    model.start()
    #expect(await waitUntil { model.nextRun["stub"] != nil })
    #expect(await waitUntil { model.monitor.state != .unknown })
    return model
}

// The label beside "Run now", drawn on the panel rather than only worded by
// `NextRunLine`.
//
// Two panels alike in everything — same connector, same transport, both polled,
// both scheduled — except the hour they name. Deleting the label makes them
// identical; anything else that differed between them would make this pass
// while the label was gone, which is exactly what happened when the comparison
// was against an unstarted model.
@Test @MainActor func thePanelSaysWhenTheNextAnecdoteIsDue() async {
    let soon = await scheduledModel(dueIn: 30)
    let later = await scheduledModel(dueIn: 2 * 60 * 60)

    #expect(drawn(soon) != nil)
    #expect(drawn(soon) != drawn(later))
    await soon.teardown()
    await later.teardown()
}

// MARK: - What a failed restock looks like

// The complaint reaches the panel rather than only the model. Two panels alike
// in everything — same connector, same address, neither started, so neither has
// polled and both draw the same device line — except that one of them has a
// restock failure to report. Deleting the line makes them identical.
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

    #expect(drawn(complaining) != nil)
    #expect(drawn(complaining) != drawn(quiet))
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

// The button the user asked for: in the Anecdotes row, not behind the gear and
// not on a row of its own. Two panels alike in everything — same connector,
// same address, neither started — except that one of them has a history to
// browse, so a panel that grew the button anywhere accounts for the difference,
// and one that grew a ROW for it is taller. Both halves are needed: the height
// alone is equal while the button does not exist at all.
@Test @MainActor func theAnecdotesRowCarriesAHistoryButtonWithoutTakingARowOfItsOwn() throws {
    let without = hostedPanel(testModel())
    let carrying = hostedPanel(testModel(anecdotes: StubAnecdotes(id: "stub")))

    let plain = try #require(bitmap(without)?.representation(using: .png, properties: [:]))
    let withHistory = try #require(bitmap(carrying)?.representation(using: .png, properties: [:]))

    #expect(plain != withHistory)
    #expect(without.fittingSize.height == carrying.fittingSize.height)
}

// A connector with no history to browse has no button to browse it with. The
// panel draws every connector the registry holds, and only the anecdotes have a
// history — a button on every row would promise one that does not exist.
@Test @MainActor func aConnectorWithNoHistoryHasNoHistoryButton() {
    let anecdotes = testModel(anecdotes: StubAnecdotes(id: "stub"))
    let somethingElse = testModel(anecdotes: StubAnecdotes(id: "weather"))

    #expect(drawn(somethingElse) != nil)
    #expect(drawn(somethingElse) == drawn(testModel()))
    #expect(drawn(anecdotes) != drawn(somethingElse))
}

// MARK: - Which connectors get a row

// The panel answers "is the clock alive, and run something now". An ambient
// connector answers neither: it keeps a value fresh in the device's own loop,
// so "Run now" repaints what is on screen already, and its switch is a setting
// rather than something to reach for in a hurry.
//
// Three models rather than two, and the third is what makes the first
// comparison mean anything: without it, a panel that had stopped drawing
// connector rows AT ALL would satisfy the equality. The two added connectors
// are alike in everything the row draws — same displayed name, same interval,
// so the same slider position and the same label — and differ only in whether
// they declare themselves ambient.
@Test @MainActor func thePanelDrawsNoRowForAConnectorThatIsAmbient() {
    let alone = testModel(connectors: [StubConnector()])
    let andAnAmbientOne = testModel(connectors: [StubConnector(), ambientConnector])
    let andANonAmbientOne = testModel(
        connectors: [
            StubConnector(),
            StubConnector(id: "second", displayName: "Ambient", defaultInterval: 900),
        ]
    )

    let oneRow = drawn(alone)

    #expect(oneRow != nil)
    #expect(drawn(andAnAmbientOne) == oneRow)
    #expect(drawn(andANonAmbientOne) != oneRow)
}

// And being silent, on its own, costs a connector nothing. The three connectors
// already asked for — Slack, calendar meetings, GitHub stars — are every one of
// them silent, because the standing rule is that nothing but the anecdotes is
// ever spoken, and every one of them is something a person opens the panel to
// fire by hand. This is that case in miniature: a connector that says nothing
// and is not ambient keeps its row.
//
// The audible twin is what makes the inequality mean a ROW rather than any
// difference at all. It is alike in everything a row draws — same displayed
// name, same interval, so the same label and the same slider position — and
// differs only in declaring itself audible, so the two panels are the same
// pixels. Without it, a silent connector drawn as a greyed-out stub would
// satisfy the inequality just as well.
@Test @MainActor func thePanelDrawsARowForAConnectorThatIsSilentButNotAmbient() {
    let alone = testModel(connectors: [StubConnector()])
    let andASilentOne = testModel(connectors: [StubConnector(), silentConnector])
    let andAnAudibleTwin = testModel(
        connectors: [
            StubConnector(),
            StubConnector(id: "twin", displayName: "Silent", defaultInterval: 900),
        ]
    )

    let oneRow = drawn(alone)

    #expect(oneRow != nil)
    #expect(drawn(andASilentOne) != oneRow)
    #expect(drawn(andASilentOne) == drawn(andAnAudibleTwin))
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
        budget: QuitBudget(),
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

// The two surfaces were consistent with each other, which is how this got here.
// Consistent is not the same as right, and both of them go.
@Test @MainActor func theSettingsSurfaceDoesNotSurviveAWindowClose() async {
    let notifications = NotificationCenter()
    let panel = aWindow()
    let model = testModel(sleep: Metronome().sleep, pollSleep: Metronome().sleep)
    let delegate = launched(model, hearing: notifications, panelOn: panel)
    model.openSettings()
    #expect(model.settingsAreOpen)

    loseFocus(panel, through: notifications)

    #expect(await waitUntil { model.settingsAreOpen == false })
    // Held to the end deliberately: the observer's block holds the delegate
    // weakly, so a released one hears the close and does nothing about it.
    withExtendedLifetime(delegate) {}
    await model.teardown()
}

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

/// The settings, open, with the given Focus centre behind them.
///
/// Neither model is started, so neither has polled and both draw the same
/// device line: what is left over between two of these is the quiet-hours
/// section and nothing else.
@MainActor
private func openSettings(focus: FocusGate, quietHours: QuietWindow) -> AppModel {
    let model = testModel(focus: focus, quietHours: quietHours)
    model.openSettings()
    return model
}

// The rule reaches the surface rather than only the model.
//
// Two settings surfaces alike in everything — same address, same window, same
// pickers on both, neither started — except which rule is deciding. The pickers
// are drawn on BOTH, deliberately: hidden on one of them, the two would differ
// by a missing control and this test would pass with the line deleted, which is
// this file's own signature failure.
@Test @MainActor func thePanelSaysWhichRuleIsInForce() {
    let night = QuietWindow(startHour: 23, endHour: 8)
    let system = openSettings(
        focus: focusGate(StubFocusStatus(access: .authorized)), quietHours: night
    )
    let window = openSettings(
        focus: focusGate(StubFocusStatus(access: .denied)), quietHours: night
    )

    // Bound rather than re-drawn per expectation, and that is not tidiness.
    // Laying out this surface costs 65 ms — the two 24-hour pickers are 46 ms
    // of it, measured — and it is SYNCHRONOUS main-actor work, so every render
    // here is time taken out of the 2-second budget of every `waitUntil` in
    // every test running beside it. Sixteen draws across the four settings
    // tests was a second of starvation and a suite that went red at random.
    let bySystem = drawn(system)
    let byWindow = drawn(window)

    #expect(system.focusRule == .anyFocus)
    #expect(window.focusRule == .quietHours(night))
    #expect(bySystem != nil)
    #expect(bySystem != byWindow)
    // The same surface twice is the same pixels, or every inequality in this
    // section is noise rather than content. Asserted once, here, for all four
    // of them.
    #expect(bySystem == drawn(system))
}

// And the window itself is on the surface, not only in the defaults: two
// surfaces whose ONLY difference is the hours in the pickers must not draw the
// same.
@Test @MainActor func theQuietHoursAreVisibleAndEditableInTheSettings() {
    let refused = focusGate(StubFocusStatus(access: .denied))
    let night = openSettings(focus: refused, quietHours: QuietWindow(startHour: 23, endHour: 8))
    let noon = openSettings(focus: refused, quietHours: QuietWindow(startHour: 11, endHour: 14))

    let atNight = drawn(night)

    #expect(atNight != nil)
    #expect(atNight != drawn(noon))
}

// MARK: - Which microphones the schedule waits for

/// The settings, open, over a given set of inputs and a given watch set.
@MainActor
private func openSettings(
    inputs: [AudioInput], watching: [WatchedMicrophone]
) -> AppModel {
    let model = testModel(
        microphone: MicrophoneGate(inputs: StubAudioInputs(inputs)), watching: watching
    )
    model.openSettings()
    return model
}

// The device list reaches the surface rather than only the model. Two settings
// surfaces over the SAME four inputs — so the rows, their count and their
// labels are identical — differing only in which of them are ticked.
//
// Same inputs on both, deliberately: with different device lists the two would
// differ by a row, and the test claiming the ticks would pass with the ticks
// gone.
@Test @MainActor func thePanelMarksWhichMicrophonesAreWatched() {
    let present = [Inputs.builtIn, Inputs.phone, Inputs.interface, Inputs.virtual]
    let watchingBuiltIn = openSettings(
        inputs: present,
        watching: [WatchedMicrophone(uid: Inputs.builtIn.uid, name: Inputs.builtIn.name)]
    )
    let watchingTheInterface = openSettings(
        inputs: present,
        watching: [WatchedMicrophone(uid: Inputs.interface.uid, name: Inputs.interface.name)]
    )

    let builtInTicked = drawn(watchingBuiltIn)

    #expect(watchingBuiltIn.microphoneListing.map(\.input) == present)
    #expect(watchingTheInterface.microphoneListing.map(\.input) == present)
    #expect(builtInTicked != nil)
    #expect(builtInTicked != drawn(watchingTheInterface))
}

// And every input is listed, not only the watched ones: a surface over four
// devices is not the same surface as one over two.
@Test @MainActor func thePanelListsEveryInputRatherThanOnlyTheWatchedOnes() {
    let watching = [WatchedMicrophone(uid: Inputs.builtIn.uid, name: Inputs.builtIn.name)]
    let all = openSettings(
        inputs: [Inputs.builtIn, Inputs.phone, Inputs.interface, Inputs.virtual],
        watching: watching
    )
    let onlyWatched = openSettings(inputs: [Inputs.builtIn], watching: watching)

    let everything = drawn(all)

    #expect(all.microphoneListing.count == 4)
    #expect(everything != nil)
    #expect(everything != drawn(onlyWatched))
}

// MARK: - Where the weather is read from

/// The weather section alone, as pixels.
///
/// The SECTION rather than the whole settings surface, and the reason is
/// measured: laying the surface out costs 57 ms of synchronous main-actor work,
/// mostly the two 24-hour pickers, and this file already spends that budget
/// seventeen times over. Drawing what the test is about costs 5 ms and says the
/// same thing. That the section is ON the settings surface is a separate claim,
/// proved by reading the location box off the control tree above.
@MainActor
private func drawnSettings(_ model: AppModel) -> Data? {
    bitmap(hosted(WeatherSettings(model: model)))?.representation(using: .png, properties: [:])
}

// The field is read off the control by `theSettingsHoldTheAddressFieldAndThe
// IconAction`, which names both boxes. What that cannot say is that the ANSWER
// to what was typed is drawn: a note computed and never rendered leaves
// somebody typing nonsense into a box that accepts it silently.
@Test @MainActor func whatTheLocationFieldSaysAboutWhatWasTypedIsDrawn() {
    let quiet = testModel(deviceHost: "10.0.0.5")
    let answered = testModel(deviceHost: "10.0.0.5")

    answered.typedLocation = "52.52, 13.405"

    // Bound rather than re-rendered per expectation: laying this surface out
    // costs 57 ms of synchronous main-actor work, measured, and every
    // millisecond of it is taken out of the budget of whatever poll is waiting
    // beside it.
    let before = drawnSettings(quiet)
    let after = drawnSettings(answered)

    #expect(quiet.locationNote == nil)
    #expect(answered.locationNote == LocationField.takesEffectAtTheNextPoll)
    #expect(before != nil)
    #expect(before != after)
}

// And a refusal has to look different from a save, or the box accepts nonsense
// with the same reassuring line under it.
@Test @MainActor func aRefusedLocationLooksDifferentFromASavedOne() {
    let saved = testModel(deviceHost: "10.0.0.5")
    let refused = testModel(deviceHost: "10.0.0.5")

    saved.typedLocation = "52.52, 13.405"
    refused.typedLocation = "somewhere warm"

    let accepted = drawnSettings(saved)
    let rejected = drawnSettings(refused)

    #expect(refused.locationNote == LocationField.unreadable)
    #expect(accepted != nil)
    #expect(accepted != rejected)
}

// `OVERLAY` is one device-wide setting rather than something scoped to an app,
// so a user who sets one by hand while the weather connector is on will see it
// replaced. That is a documented consequence when the settings say so, and a
// bug in the firmware when they do not.
//
// The words are checked here; that the standing sentence is DRAWN is on the
// list only a person can check, as "the gear opens the settings" is. SwiftUI
// backs a `Text` with no control and builds no accessibility tree outside a
// window — measured — so the only instrument left is a pixel comparison, and
// a sentence that is always on the surface cannot differ from itself.
@Test @MainActor func theSettingsSayThatTheOverlayIsSharedWithTheWholeDevice() {
    let said = WeatherSettings.overlayIsSharedWithTheDevice

    #expect(said.contains("overlay"))
    #expect(said.contains("device-wide"))
    #expect(said.contains("by hand"))
    #expect(said.contains("replaced"))
    // And that it comes back, which is the half a user cannot see for
    // themselves until they quit.
    #expect(said.contains("put back"))
}

// The connector ships switched ON, so the first launch takes the device-wide
// overlay without anybody asking for it. That is the design; discovering it
// from the clock is not.
@Test @MainActor func theSettingsSayTheWeatherIsOnFromTheFirstLaunch() {
    let said = WeatherSettings.weatherStartsSwitchedOn

    #expect(said.contains("first launch"))
    // And where to go to stop it, or the warning is one a reader cannot act on.
    #expect(said.contains("Switch it off"))
    // Not the panel, which no longer draws a weather row at all. A sentence
    // naming a surface the switch is not on is worse than one that names none:
    // it sends the reader somewhere to look for a control that was moved, and
    // this one said "on the main panel" for as long as the row was there.
    #expect(said.contains("panel") == false)
}

// The switch the panel row used to carry, on the surface it moved to. Two
// weather sections over the SAME connector — same location, same notes, same
// everything the section draws — differing only in whether that connector is
// switched on.
//
// Pixels are the only instrument available: a SwiftUI `Toggle` is not an
// `NSButton` in the view tree and cannot be read off it, exactly as the panel's
// own toggles cannot. So what this says is that the section DRAWS the
// connector's state; that pressing the switch writes it back is on the list
// only a person can check, alongside "the gear opens the settings".
@Test @MainActor func theWeatherIsSwitchedOffInTheSettingsRatherThanOnThePanel() {
    let weather = weatherConnector(over: SkyAndClockTransport())
    let on = testModel(connectors: [StubConnector(), weather])
    let off = testModel(connectors: [StubConnector(), weather])

    off.setEnabled(false, for: weather)

    let switchedOn = drawnSettings(on)

    #expect(on.settings(for: weather).isEnabled)
    #expect(off.settings(for: weather).isEnabled == false)
    #expect(switchedOn != nil)
    #expect(switchedOn != drawnSettings(off))
    // The same surface twice is the same pixels, or the inequality above is
    // noise rather than content.
    #expect(switchedOn == drawnSettings(on))
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
