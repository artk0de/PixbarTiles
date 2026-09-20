import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PixelClockTilesApp

/// A login-item database whose answer a test chooses, and which records what it
/// was asked to do.
///
/// `obeys` is the field that carries the whole point. A service that ACCEPTS a
/// call and stays off is not a contrived case — it is what a refusal without a
/// thrown error looks like, and it is exactly what a checkbox drawn from a
/// stored boolean would paper over. Kept separate from the throwing case
/// because the two failures look different to the user and only one of them has
/// words to show.
///
/// Local to this file rather than in `Doubles.swift`: nothing else poses login
/// items, and `testModel` has no reason to grow a parameter for them.
private final class StubLoginItem: LoginItemRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var reported: LoginItemState
    private let obeys: Bool
    private var registerFailure: (any Error)?
    private var unregisterFailure: (any Error)?
    private var registers = 0
    private var unregisters = 0

    init(
        _ reported: LoginItemState = .notRegistered,
        obeys: Bool = true,
        registerFails: (any Error)? = nil,
        unregisterFails: (any Error)? = nil
    ) {
        self.reported = reported
        self.obeys = obeys
        self.registerFailure = registerFails
        self.unregisterFailure = unregisterFails
    }

    var state: LoginItemState { lock.withLock { reported } }
    /// How many times the model went to the system rather than to a memory of
    /// its own.
    var registrations: Int { lock.withLock { registers } }
    var removals: Int { lock.withLock { unregisters } }

    /// A system that refused once and will not refuse again — the second click
    /// after a first that failed, which is what a user does.
    func nowAccepts() {
        lock.withLock {
            registerFailure = nil
            unregisterFailure = nil
        }
    }

    func register() throws {
        lock.withLock { registers += 1 }
        if let registerFailure { throw registerFailure }
        if obeys { lock.withLock { reported = .enabled } }
    }

    func unregister() throws {
        lock.withLock { unregisters += 1 }
        if let unregisterFailure { throw unregisterFailure }
        if obeys { lock.withLock { reported = .notRegistered } }
    }
}

/// What the system throws when it will not register, in the shape the model
/// meets it: an `NSError` whose words are the only thing worth showing.
private let systemRefused = NSError(
    domain: "SMAppServiceErrorDomain", code: 1,
    userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
)

// MARK: - The box says what the system says

@Test @MainActor func theBoxIsTickedWhenTheSystemSaysThisAppIsRegistered() {
    #expect(LoginItemModel(service: StubLoginItem(.enabled)).opensAtLogin)
}

// Every other answer draws an empty box, and `.requiresApproval` is the one
// that matters here: it is the state a user reaches by refusing in System
// Settings, and a check written as "not notRegistered" would tick the box for
// an app macOS is actively holding back.
@Test @MainActor func theBoxIsClearForEveryAnswerThatIsNotRegistered() {
    #expect(LoginItemModel(service: StubLoginItem(.notRegistered)).opensAtLogin == false)
    #expect(LoginItemModel(service: StubLoginItem(.notFound)).opensAtLogin == false)
    #expect(LoginItemModel(service: StubLoginItem(.requiresApproval)).opensAtLogin == false)
}

// MARK: - Ticking it

@Test @MainActor func tickingTheBoxRegistersWithTheSystemAndReadsTheAnswerBack() {
    let service = StubLoginItem(.notRegistered)
    let subject = LoginItemModel(service: service)

    subject.setOpensAtLogin(true)

    #expect(service.registrations == 1)
    #expect(subject.opensAtLogin)
    #expect(subject.note == nil)
}

@Test @MainActor func untickingTheBoxUnregisters() {
    let service = StubLoginItem(.enabled)
    let subject = LoginItemModel(service: service)

    subject.setOpensAtLogin(false)

    #expect(service.removals == 1)
    #expect(subject.opensAtLogin == false)
    #expect(subject.note == nil)
}

// MARK: - The defect this exists to avoid

// The whole reason the state is not a stored boolean. This service accepts the
// call, throws nothing, and stays off — which is what a registration the system
// quietly declines looks like from in here. A checkbox that remembered "the
// user asked for it" would tick itself and go on lying every time the settings
// are opened.
@Test @MainActor func aBoxThatTicksItselfOnACallTheSystemIgnoredIsTheDefectThisAvoids() {
    let service = StubLoginItem(.notRegistered, obeys: false)
    let subject = LoginItemModel(service: service)

    subject.setOpensAtLogin(true)

    #expect(service.registrations == 1)
    #expect(subject.opensAtLogin == false)
}

// And a registration that THROWS is shown rather than swallowed. Two claims,
// and both are needed: the box stays clear, and the failure has words. Silence
// with a clear box is indistinguishable from a click that never registered.
@Test @MainActor func aRegistrationThatThrowsLeavesTheBoxClearAndSaysWhy() {
    let subject = LoginItemModel(
        service: StubLoginItem(.notRegistered, registerFails: systemRefused)
    )

    subject.setOpensAtLogin(true)

    #expect(subject.opensAtLogin == false)
    #expect(subject.note?.contains("Operation not permitted") == true)
}

// The other direction, which is the one that fails safe in the wrong direction
// if it is written optimistically: an unregister that throws leaves the app
// still registered, and clearing the box there would tell the user they had
// switched something off that still runs at every login.
@Test @MainActor func anUnregisterThatThrowsLeavesTheBoxTickedRatherThanClearingItOptimistically() {
    let subject = LoginItemModel(
        service: StubLoginItem(.enabled, unregisterFails: systemRefused)
    )

    subject.setOpensAtLogin(false)

    #expect(subject.opensAtLogin)
    #expect(subject.note?.contains("Operation not permitted") == true)
}

// A failure's words belong to the attempt that produced them. Left up after a
// later call succeeded, they would be an error message sitting under a box that
// is now correct.
@Test @MainActor func theWordsOfAFailedAttemptGoAwayWhenTheNextOneWorks() {
    let service = StubLoginItem(.notRegistered, registerFails: systemRefused)
    let subject = LoginItemModel(service: service)
    subject.setOpensAtLogin(true)
    #expect(subject.note != nil)

    service.nowAccepts()
    subject.setOpensAtLogin(true)

    #expect(subject.opensAtLogin)
    #expect(subject.note == nil)
}

// MARK: - The state macOS holds in System Settings

// `.requiresApproval` is not an ordinary off. The app is registered and macOS
// is refusing to start it until somebody says so in System Settings, and there
// is nothing this app can do about it from here — so the one useful thing is to
// say where to go. An empty box with no words would send the user clicking it
// again for ever.
@Test @MainActor func anApprovalHeldInSystemSettingsIsSaidRatherThanLookingLikeAPlainOff() {
    let held = LoginItemModel(service: StubLoginItem(.requiresApproval))

    #expect(held.opensAtLogin == false)
    #expect(held.note == LoginItemModel.approvalIsHeldInSystemSettings)
    // And an ordinary off says nothing, or the sentence above is decoration
    // that is always on screen.
    #expect(LoginItemModel(service: StubLoginItem(.notRegistered)).note == nil)
}

// The words have to name where to go, or they are an apology rather than an
// instruction.
@Test func theApprovalSentenceNamesWhereTheSwitchActuallyIs() {
    #expect(LoginItemModel.approvalIsHeldInSystemSettings.contains("System Settings"))
    #expect(LoginItemModel.approvalIsHeldInSystemSettings.contains("Login Items"))
}

// MARK: - The shipped registrar, and the suite it must not register

// Measured, and the reason this guard exists at all: `SMAppService.mainApp`
// outside a bundle does not refuse. It registers `Bundle.main.bundlePath`,
// which under `swift test` is
// `…/XcodeDefault.xctoolchain/usr/libexec/swift/pm` — so an unguarded
// `register()` in this target would put a login item on the machine of whoever
// ran the suite, pointing into the Xcode toolchain. A probe did exactly that
// with a bare binary and had to take it back out of the login-item database.
//
// This test constructs the shipped type and calls it, which is safe only
// because the guard is what it is asserting. It is also the reason `isBundled`
// is not private.
@Test func theShippedRegistrarRefusesToRegisterWhenThereIsNoBundleToRegister() {
    #expect(SystemLoginItem.isBundled == false)

    #expect(throws: LoginItemRefusal.noBundleToRegister) {
        try SystemLoginItem().register()
    }
    #expect(throws: LoginItemRefusal.noBundleToRegister) {
        try SystemLoginItem().unregister()
    }
}

// And the refusal has to arrive as words the settings can show, not as a bare
// error whose `localizedDescription` is a domain and a number.
@Test func theRefusalSaysWhatIsMissingRatherThanAnErrorCode() {
    let said = LoginItemRefusal.noBundleToRegister.localizedDescription

    #expect(said.contains("bundle"))
    #expect(said.contains("Error") == false)
}

// MARK: - The checkbox on the screen

/// The states of every checkbox and button in a laid-out view.
///
/// A SwiftUI `Toggle` on macOS IS an `NSButton` in the view tree — verified by
/// walking the settings surface, where the microphone toggles arrive as
/// `FocusRingNSButton` with a readable `state` — so this reads the control
/// rather than the pixels. That matters here: a bitmap comparison cannot tell a
/// ticked box from an untickable one, and the tick is the whole claim.
@MainActor
private func buttonStates(in view: NSView) -> [Int] {
    var found: [Int] = []
    if let button = view as? NSButton { found.append(button.state.rawValue) }
    for sub in view.subviews { found += buttonStates(in: sub) }
    return found
}

@MainActor
private func laidOut(_ view: some View) -> NSView {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    return host
}

/// A model over a system stopped at one answer.
@MainActor
private func reporting(_ state: LoginItemState) -> LoginItemModel {
    LoginItemModel(service: StubLoginItem(state))
}

// The section draws exactly one control, and its tick follows the system's
// answer rather than anything this app remembers.
@Test @MainActor func theSectionDrawsOneCheckboxTickedToWhatTheSystemReports() {
    let on = buttonStates(in: laidOut(LoginItemSettings(item: reporting(.enabled))))
    let off = buttonStates(in: laidOut(LoginItemSettings(item: reporting(.notRegistered))))

    #expect(on == [NSControl.StateValue.on.rawValue])
    #expect(off == [NSControl.StateValue.off.rawValue])
}

// And the section is ON the settings surface, which every test above would pass
// without. Read off the controls rather than the pixels for the reason the
// helper gives, and compared between two answers rather than against a count:
// a count would have to be updated by whoever adds the next toggle, and would
// then be a test that fails for a reason it is not about.
@Test @MainActor func theCheckboxIsOnTheSettingsSurfaceRatherThanOnlyInItsOwnSection() {
    let registered = buttonStates(
        in: laidOut(SettingsSheet(
            model: testModel(), discovery: inertDiscovery(), loginItem: reporting(.enabled)
        ))
    )
    let not = buttonStates(
        in: laidOut(SettingsSheet(
            model: testModel(), discovery: inertDiscovery(),
            loginItem: reporting(.notRegistered)
        ))
    )

    #expect(registered.isEmpty == false)
    #expect(registered.count == not.count)
    #expect(registered != not)
}

// The failure reaches the screen too. Deleting the note from the section's body
// leaves every model test above green — this is the one that catches it.
@Test @MainActor func aRefusedRegistrationIsDrawnAndNotOnlyHeld() {
    let refused = LoginItemModel(
        service: StubLoginItem(.notRegistered, registerFails: systemRefused)
    )
    refused.setOpensAtLogin(true)
    let quiet = reporting(.notRegistered)

    let said = drawn(LoginItemSettings(item: refused))

    #expect(said != nil)
    #expect(said != drawn(LoginItemSettings(item: quiet)))
}

/// The section alone, as pixels.
///
/// The section rather than the whole settings surface, for the reason
/// `WeatherSettings` was split out: laying that surface out costs 57 ms of
/// synchronous main-actor work, mostly the two 24-hour pickers, and nothing
/// here needs them.
@MainActor
private func drawn(_ view: some View) -> Data? {
    let host = laidOut(view)
    guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: target)
    return target.representation(using: .png, properties: [:])
}
