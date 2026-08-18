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

// The other half of the brief's step 5: an editable address, on the panel, with
// this launch's address already in it — not an empty box the user has to know
// what to put in.
//
// Read off the control rather than off the pixels, and that is not fussiness.
// Comparing renders of two differently-addressed panels passed with the field
// removed entirely and with its seed emptied: the status line one row up names
// the same address, so it accounted for the whole difference. The test claimed
// the field and was measuring the line above it.
@Test @MainActor func theAddressThisLaunchUsesIsInTheFieldOnThePanel() {
    #expect(panelFields(deviceHost: "192.168.1.72") == ["192.168.1.72"])
    #expect(panelFields(deviceHost: "10.0.0.9") == ["10.0.0.9"])
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
