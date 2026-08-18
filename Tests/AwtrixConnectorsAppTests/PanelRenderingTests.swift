import AppKit
import AwtrixKit
import Foundation
import SwiftUI
import Testing
@testable import AwtrixConnectorsApp

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

    #expect(fields(in: hosted(SettingsSheet(model: model))) == ["10.0.0.9"])
    #expect(model.deviceHost == "192.168.1.72")
}

@Test @MainActor func theAddressThisLaunchUsesIsInTheFieldInTheSettings() {
    #expect(settingsFields(deviceHost: "192.168.1.72") == ["192.168.1.72"])
    #expect(settingsFields(deviceHost: "10.0.0.9") == ["10.0.0.9"])
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
    let host = NSHostingView(rootView: MenuBarGlyph(model: model))
    host.frame = NSRect(x: 0, y: 0, width: 30, height: 18)
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

/// The panel, or the settings when they are open, as pixels.
@MainActor
private func drawn(_ model: AppModel) -> Data? {
    let browsing = FakeBonjourBrowser()
    let browser = DeviceBrowser(browsing: { browsing }, sleep: { _ in })
    browser.start()
    let host = hosted(MenuPanel(model: model, monitor: model.monitor, discovery: browser))
    return bitmap(host)?.representation(using: .png, properties: [:])
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
    #expect(settingsFields(deviceHost: "10.0.0.5") == ["10.0.0.5"])

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

    #expect(panelControls(model) == ["10.0.0.5"])

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
