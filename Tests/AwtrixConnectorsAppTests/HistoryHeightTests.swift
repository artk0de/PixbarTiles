import AppKit
import AwtrixKit
import Foundation
import SwiftUI
import Testing
@testable import AwtrixConnectorsApp

// The History is the one surface with a list that outgrows it, so it is the one
// with a height worth storing — the panel and the settings are exactly as tall
// as their content and have nothing to gain. What a person does with it, drag
// the bottom edge, needs a pointer; what it hands off to does not: the clamp
// that keeps the surface on the screen, the read that survives a relaunch, and
// that the number reaches the list rather than the window round it.

// MARK: - The stored height

/// A screen with room to spare, so a test about the floor is not accidentally a
/// test about the ceiling.
private let roomyScreen: CGFloat = 1_200

@Test func aHistoryNobodyHasDraggedIsTheHeightTheListWasCappedAt() throws {
    let suite = "history-height-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(
        HistoryHeight.stored(in: defaults, fittingInto: roomyScreen).points
            == HistoryHeight.designed
    )
}

// Pull it taller, find it taller. A separate `UserDefaults` on the same suite is
// what a relaunch does — the same on-disk domain, read by an instance that never
// saw the write.
@Test func aHeightThatWasSavedIsTheHeightTheNextLaunchOpensAt() throws {
    let suite = "history-height-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    HistoryHeight(420, fittingInto: roomyScreen).save(to: defaults)

    let relaunched = try #require(UserDefaults(suiteName: suite))
    #expect(HistoryHeight.stored(in: relaunched, fittingInto: roomyScreen).points == 420)
}

// The floor, and it is the same rule the width has for the same reason: a list
// dragged to nothing leaves no bottom edge to grab it back by, and a menu bar
// surface has no title bar to fall back on.
@Test func aHeightUnderTheFloorIsRaisedToIt() {
    #expect(HistoryHeight(20, fittingInto: roomyScreen).points == HistoryHeight.smallest)
    #expect(HistoryHeight(0, fittingInto: roomyScreen).points == HistoryHeight.smallest)
    #expect(HistoryHeight(-400, fittingInto: roomyScreen).points == HistoryHeight.smallest)
}

// The ceiling is the SCREEN's, not a number of this type's own, and that is the
// difference from the width. Ten days of a half-hourly connector is a few
// hundred entries: a History let grow to its content hangs off the menu bar and
// runs off the bottom of the display, taking the bottom edge that would shrink
// it again with it. Scrolling does not save it — the viewport itself is what has
// gone off the screen.
@Test func aHeightTallerThanTheScreenIsCutDownToTheScreen() {
    #expect(
        HistoryHeight(5_000, fittingInto: 900).points == HistoryHeight.largest(fittingInto: 900)
    )
    #expect(HistoryHeight(5_000, fittingInto: 900).points < 900)
    // A bigger display is a bigger ceiling. One fixed number would have been
    // either wasteful on a 27-inch or off the bottom of a laptop.
    #expect(
        HistoryHeight(5_000, fittingInto: 1_600).points
            > HistoryHeight(5_000, fittingInto: 900).points
    )
}

// The two clamps can collide: on a display short enough, the ceiling drops below
// the floor and `min(max(…))` would hand back a ceiling BELOW the smallest
// usable height — the unrecoverable surface, reached by the guard that exists to
// prevent it. The floor wins, and the surface overhangs a screen that small.
@Test func aScreenTooShortForTheFloorStillGivesTheFloor() {
    #expect(HistoryHeight(400, fittingInto: 100).points == HistoryHeight.smallest)
    #expect(HistoryHeight.largest(fittingInto: 100) == HistoryHeight.smallest)
}

// Not reachable from a drag, and reachable from a damaged plist. A clamp cannot
// answer it: `min(max(.nan, a), b)` is `.nan`, and a list framed at `.nan` does
// not lay out at all — with the bad number still stored, so it opens to nothing
// again next time.
@Test func aHeightThatIsNotANumberFallsBackToTheDesignHeight() {
    #expect(HistoryHeight(.nan, fittingInto: roomyScreen).points == HistoryHeight.designed)
    #expect(HistoryHeight(.infinity, fittingInto: roomyScreen).points == HistoryHeight.designed)
    #expect(HistoryHeight(-.infinity, fittingInto: roomyScreen).points == HistoryHeight.designed)
}

// The documented way out of a History that opens somewhere unusable is
// `defaults write … historyHeight -int 280`. Read through a cast that only
// accepts a double, that entry reads as a key with nothing in it, and the escape
// hatch silently does nothing.
@Test func aHeightTypedByHandAsAWholeNumberIsRead() throws {
    let suite = "history-height-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(360, forKey: HistoryHeight.storageKey)

    #expect(HistoryHeight.stored(in: defaults, fittingInto: roomyScreen).points == 360)
}

// Clamped on the way out as well as on the way in, and these are not the same
// claim: a value reaches the defaults without passing through `save` whenever
// somebody types one — or whenever the screen it was saved on is bigger than the
// screen it is being read on, which is what closing a laptop lid does.
@Test func aHeightAlreadyInTheDefaultsIsClampedWhenItIsRead() throws {
    let suite = "history-height-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(8.0, forKey: HistoryHeight.storageKey)
    #expect(
        HistoryHeight.stored(in: defaults, fittingInto: roomyScreen).points
            == HistoryHeight.smallest
    )

    defaults.set(4_000.0, forKey: HistoryHeight.storageKey)
    #expect(
        HistoryHeight.stored(in: defaults, fittingInto: 900).points
            == HistoryHeight.largest(fittingInto: 900)
    )
}

// MARK: - The height the History is drawn at

/// Enough entries that the list is longer than any height under test, so what is
/// being measured is the frame rather than how much there was to draw.
@MainActor
private func loadedHistory() async throws -> AppModel {
    let entries = try (0..<40).map { index in
        PlayedAnecdote(
            anecdote: try playableAnecdote(id: "a\(index)", text: "Заходит улитка в бар"),
            playedAt: Date()
        )
    }
    let model = testModel(anecdotes: StubAnecdotes(history: entries))
    model.openHistory()
    #expect(await waitUntil { model.historyIsOpen && model.history?.count == entries.count })
    return model
}

@MainActor
private func hostedHistory(
    _ model: AppModel, readingFrom defaults: UserDefaults, onAScreenOf screen: CGFloat = roomyScreen
) -> NSHostingView<HistoryMenu> {
    let host = NSHostingView(
        rootView: HistoryMenu(model: model, defaults: defaults, screenHeight: screen)
    )
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    return host
}

// Isolated to the main actor, because `subviews` is: an `NSView`'s tree is
// AppKit state and reading it from anywhere else is a data race Swift 6 warns
// about. Every caller is already a `@MainActor` test, so this costs nothing.
@MainActor
private func scrollView(in view: NSView) -> NSScrollView? {
    if let found = view as? NSScrollView { return found }
    for sub in view.subviews {
        if let found = scrollView(in: sub) { return found }
    }
    return nil
}

// The wire between the stored number and the screen. Everything above says a
// number goes in and comes back; this is the only thing that says the History is
// drawn at it — and it is asserted as a DIFFERENCE so it cannot be satisfied by
// a surface that happens to be that tall for some other reason, and so it does
// not have to know what the header and the padding come to.
@Test @MainActor func theHistoryListIsAsTallAsTheStoredHeight() async throws {
    let suite = "history-height-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = try await loadedHistory()

    defaults.set(200.0, forKey: HistoryHeight.storageKey)
    let shorter = hostedHistory(model, readingFrom: defaults).fittingSize.height
    defaults.set(400.0, forKey: HistoryHeight.storageKey)
    let taller = hostedHistory(model, readingFrom: defaults).fittingSize.height

    #expect(taller - shorter == 200)
}

// The list SCROLLS inside the height rather than being cut off at it. A frame
// that simply clipped would pass the test above and hide history — the entries
// below the fold would be unreachable, which is worse than not storing a height
// at all.
@Test @MainActor func theListScrollsInsideWhateverHeightItHas() async throws {
    let suite = "history-height-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = try await loadedHistory()

    defaults.set(HistoryHeight.smallest, forKey: HistoryHeight.storageKey)
    let host = hostedHistory(model, readingFrom: defaults)

    // An `NSScrollView` at all is half the claim: a height put on a plain stack
    // and clipped would produce none, and would hide the entries under the fold
    // for good. Its viewport being exactly the stored height is the other half —
    // the number reaches the thing that scrolls, not the thing that cuts.
    //
    // What is NOT asserted is the document view's own height. Outside a window
    // SwiftUI never lays its scroll content out, so it reads as a zero frame
    // here whatever the list holds; the surface being no taller for forty
    // entries than for one is the test below.
    let scroller = try #require(scrollView(in: host))
    _ = try #require(scroller.documentView)
    #expect(scroller.contentSize.height == HistoryHeight.smallest)
}

// Forty entries do not make a taller surface than four. Without the frame the
// History grows to its content, which on ten days of anecdotes is a window
// several screens long.
@Test @MainActor func aLongHistoryIsNoTallerThanAShortOne() async throws {
    let suite = "history-height-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let long = hostedHistory(try await loadedHistory(), readingFrom: defaults).fittingSize.height

    let brief = try await showingOneEntry()
    let short = hostedHistory(brief, readingFrom: defaults).fittingSize.height

    #expect(long == short)
}

@MainActor
private func showingOneEntry() async throws -> AppModel {
    let model = testModel(anecdotes: StubAnecdotes(history: [
        PlayedAnecdote(anecdote: try playableAnecdote(id: "only"), playedAt: Date()),
    ]))
    model.openHistory()
    #expect(await waitUntil { model.historyIsOpen && model.history?.isEmpty == false })
    return model
}

// The claim the ceiling exists for, made where it matters: on the screen rather
// than in the type. A History whose bottom edge is under the bottom of the
// display cannot be dragged back, and the ONLY way out is the command line.
@Test @MainActor func aHistoryTallerThanTheScreenIsDrawnToFitOnIt() async throws {
    let suite = "history-height-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = try await loadedHistory()

    defaults.set(5_000.0, forKey: HistoryHeight.storageKey)

    #expect(hostedHistory(model, readingFrom: defaults, onAScreenOf: 700).fittingSize.height <= 700)
}
