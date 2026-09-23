import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The store's facade: the shelves, the cards, and the one action a card
// carries — aimed at the clock whose gear opened the store.
//
// The availability mapping is the reason this facade exists rather than the
// window reading the catalogue straight: a menu can drop a row, but a grid
// with holes in it reads as a bug. So `.notListed` draws as an "Added" card,
// and the facade is where that renaming lives.

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
private let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.6")
private let loft = ClockRecord(name: "Loft", model: .awtrix3, address: "10.0.0.7")

private func tile(_ connector: String, on clock: ClockRecord) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock.id, connectorId: connector),
        policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600)
    )
}

// MARK: - The cards

@Test @MainActor func theCardsAnswerAboutTheClockTheStoreIsAimedAt() {
    let model = testModel(
        connectors: [StubConnector(id: "claude", displayName: "Claude")],
        clocks: [desk, loft, kitchen],
        tiles: [tile("claude", on: desk)],
        sessions: [desk.id: SpyHost(), kitchen.id: SpyHost()]
    )
    let subject = StoreModel(model: model)

    subject.show(desk.id)
    // The clock already carrying Claude's one tile draws it as Added, not as
    // a hole — the catalogue's notListed, renamed at this boundary. The lamp,
    // unplaced, is Add.
    #expect(subject.cards.map(\.title) == ["Claude", "VPN"])
    #expect(subject.cards.map(\.action) == [.added, .add])

    // The clock next door carries the reason instead: Claude is audible, and
    // it is already speaking through Desk.
    subject.show(loft.id)
    #expect(
        subject.cards.map(\.action)
            == [.refused(reason: "already speaking through Desk"), .add]
    )

    // And the TC002 carries the face rule's own reason for both.
    subject.show(kitchen.id)
    #expect(
        subject.cards.map(\.action)
            == [.refused(reason: "not supported on TC002"), .refused(reason: "not supported on TC002")]
    )
}

// MARK: - The add

@Test @MainActor func anAddPutsTheTileOnItsClockAndOpensItsSettings() async {
    let model = testModel(
        connectors: [StubConnector(id: "claude", displayName: "Claude")],
        clocks: [desk, loft],
        tiles: [],
        sessions: [desk.id: SpyHost(), loft.id: SpyHost()]
    )
    let subject = StoreModel(model: model)
    subject.show(loft.id)

    // The card's add is aimed at ITS clock — the store was opened from a
    // per-clock gear, so pressing must not add to whoever else is listed.
    guard let card = subject.cards.first(where: { $0.title == "Claude" }) else {
        Issue.record("the store did not offer Claude: \(subject.cards)")
        return
    }
    #expect(card.action == .add)
    subject.add(card)

    // The tile is on the clock it was aimed at…
    #expect(
        await waitUntil {
            model.tileRecords.filter { $0.key.clockId == loft.id }.map(\.key.connectorId)
                == ["claude"]
        }
    )
    // …and the two-step commit holds: its settings window is the tile that
    // is open, and the window's own watcher has the key it opens on.
    let key = TileKey(clockId: loft.id, connectorId: "claude")
    #expect(model.detailTileKey == key)
    #expect(subject.lastAdded == key)
}

// MARK: - The shelves

@Test @MainActor func theShelvesFileTheCardsAndShowResetsTheShelf() {
    let model = testModel(
        connectors: [StubConnector(id: "claude", displayName: "Claude")],
        clocks: [desk, loft],
        tiles: [],
        sessions: [desk.id: SpyHost(), loft.id: SpyHost()]
    )
    let subject = StoreModel(model: model)
    subject.show(desk.id)

    // Claude's shelf is Dev, the lamp's is Network — the kit's one
    // presentation table, so a card cannot drift from the row's own mark.
    subject.category = .dev
    #expect(subject.cards.map(\.title) == ["Claude"])
    subject.category = .network
    #expect(subject.cards.map(\.title) == ["VPN"])
    subject.category = nil
    #expect(subject.cards.count == 2)

    // A re-aim forgets the shelf: whatever the store showed for the last
    // clock, a gear's Add tile… means All for this one.
    subject.category = .dev
    subject.show(loft.id)
    #expect(subject.category == nil)
    #expect(subject.cards.count == 2)
}

// MARK: - The refusal

@Test @MainActor func anAddTheModelRefusesSaysWhyAndChangesNothing() async {
    let model = testModel(
        connectors: [StubConnector(id: "claude", displayName: "Claude")],
        clocks: [loft],
        tiles: [],
        sessions: [loft.id: SpyHost()]
    )
    let subject = StoreModel(model: model)
    subject.show(loft.id)

    // The lamp is `.perKey`, so it never reaches the `.notListed` that draws
    // an "Added" card: its card stays "+ Add" for ever. One press per VPN in
    // the catalogue goes through, and the one after that is refused — and
    // the store used to drop that answer on the floor, leaving a card that
    // did nothing and said nothing.
    guard let lamp = subject.cards.first(where: { $0.title == "VPN" }) else {
        Issue.record("the store did not offer the lamp: \(subject.cards)")
        return
    }
    for _ in WatchedVPN.catalogue { subject.add(lamp) }
    #expect(await waitUntil { model.tileRecords.count == WatchedVPN.catalogue.count })
    #expect(subject.lastRefusal == nil)

    subject.add(lamp)
    #expect(subject.lastRefusal == "every VPN already has a tile on Loft")
    #expect(model.tileRecords.count == WatchedVPN.catalogue.count)

    // A reason belongs to the card that earned it: another shelf is another
    // question.
    subject.category = .dev
    #expect(subject.lastRefusal == nil)
}

@Test @MainActor func aSuccessfulAddClearsThePreviousRefusal() async {
    let model = testModel(
        connectors: [StubConnector(id: "claude", displayName: "Claude")],
        clocks: [loft],
        tiles: [],
        sessions: [loft.id: SpyHost()]
    )
    let subject = StoreModel(model: model)
    subject.show(loft.id)

    guard let lamp = subject.cards.first(where: { $0.title == "VPN" }),
        let claude = subject.cards.first(where: { $0.title == "Claude" })
    else {
        Issue.record("the store did not offer both cards: \(subject.cards)")
        return
    }
    for _ in WatchedVPN.catalogue { subject.add(lamp) }
    #expect(await waitUntil { model.tileRecords.count == WatchedVPN.catalogue.count })
    subject.add(lamp)
    #expect(subject.lastRefusal != nil)

    // The refusal answered the press before this one. A card that goes on the
    // clock must not leave the last card's reason standing under it.
    subject.add(claude)
    #expect(subject.lastRefusal == nil)
    #expect(await waitUntil { model.tileRecords.count == WatchedVPN.catalogue.count + 1 })
}
