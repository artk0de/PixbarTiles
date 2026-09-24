import Foundation
import PixbarKit
import SwiftUI
import Testing
@testable import PixbarTilesApp

// The lamp tile, from the store's card to the block that configures it.
//
// A VPN tile's key carries its VPN in `instance` — the shape the migration
// wrote and the shape the restore key reads. Everything here holds that
// invariant up: an add picks a VPN nobody is watching, and a change of VPN
// moves the tile to the key its new VPN names.

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")

@MainActor private func lampTiles(of model: AppModel) -> [TileRecord] {
    model.tileRecords.filter { $0.key.connectorId == VPNConnector.id }
}

// MARK: - The add

// The store presses "+ Add" with no instance, because a store card knows a
// connector and not a VPN. The model fills it in: the first preset nobody is
// watching, on the first lamp nobody has claimed.
@Test @MainActor func aLampAddedWithNoInstanceTakesTheFirstFreeVPNAndLamp() {
    let subject = testModel(clocks: [desk], tiles: [])

    #expect(subject.addTile(VPNConnector.id, to: desk.id) == .saved)

    let added = lampTiles(of: subject)
    #expect(added.count == 1)
    #expect(added.first?.key.instance == WatchedVPN.pritunl.id)
    #expect(added.first?.config?.lamp?.vpn == WatchedVPN.pritunl.id)
    #expect(added.first?.config?.lamp?.slot == .topRight)
}

// The second press is the whole reason the lamp's card stays "+ Add": VPN
// tiles are `.perKey`, so the card never becomes "Added". It used to be a
// silent no-op — the instance was empty both times, so the second add landed
// on the first one's key and was refused as a duplicate.
@Test @MainActor func aSecondLampTakesTheOtherVPNAndTheNextLamp() {
    let subject = testModel(clocks: [desk], tiles: [])
    _ = subject.addTile(VPNConnector.id, to: desk.id)

    #expect(subject.addTile(VPNConnector.id, to: desk.id) == .saved)

    let added = lampTiles(of: subject).sorted { $0.key.instance < $1.key.instance }
    #expect(added.map(\.key.instance) == [WatchedVPN.amnezia.id, WatchedVPN.pritunl.id])
    // Different lamps, so the two never argue over a corner: the conflict
    // check is for a user who moves them onto one deliberately.
    #expect(Set(added.compactMap { $0.config?.lamp?.slot }).count == 2)
}

// The catalogue is two presets deep, and a tile per preset is the ceiling.
// The refusal names it rather than adding a third tile nobody can tell apart.
@Test @MainActor func aLampWithNoVPNLeftToWatchIsRefused() {
    let subject = testModel(clocks: [desk], tiles: [])
    for _ in WatchedVPN.catalogue { _ = subject.addTile(VPNConnector.id, to: desk.id) }

    #expect(
        subject.addTile(VPNConnector.id, to: desk.id)
            == .refused("every VPN already has a tile on Desk")
    )
    #expect(lampTiles(of: subject).count == WatchedVPN.catalogue.count)
}

// An explicit instance still wins: the migration writes its two tiles that
// way, and so does a test.
@Test @MainActor func anExplicitVPNIsKeptAsItIsGiven() {
    let subject = testModel(clocks: [desk], tiles: [])

    #expect(subject.addTile(VPNConnector.id, to: desk.id, instance: WatchedVPN.amnezia.id) == .saved)

    #expect(lampTiles(of: subject).first?.key.instance == WatchedVPN.amnezia.id)
}

// MARK: - What the block's pickers hand back

// The block speaks in labels — "Amnezia", "Middle right", a `Color` — and the
// config stores ids, cases and `#RRGGBB`. Three lookups turn one into the
// other, and each of them is a place a label can stop matching the thing it
// names. A picker that hands back a title nothing recognises is a control
// that silently does nothing, which is the whole class of defect this file
// exists for.
@Test func everyLampTitleNamesExactlyOneSlot() {
    for slot in IndicatorSlot.allCases {
        #expect(IndicatorSlot.allCases.filter { $0.lampTitle == slot.lampTitle } == [slot])
    }
    #expect(Set(IndicatorSlot.allCases.map(\.lampTitle)).count == IndicatorSlot.allCases.count)
}

@Test func everyPresetNameNamesExactlyOneVPN() {
    for vpn in WatchedVPN.catalogue {
        let matching = WatchedVPN.catalogue.filter { $0.displayName == vpn.displayName }
        #expect(matching.map(\.id) == [vpn.id])
    }
}

// The `ColorPicker` hands back a `Color`, and a lamp is told a hex string.
// Every palette entry must survive the trip out and back, or picking a
// palette swatch would write a colour subtly different from the one shown.
@Test @MainActor func everyPaletteColourSurvivesTheTripToHexAndBack() {
    for entry in VPNTilePalette.palette {
        #expect(entry.colour.hexString == entry.hex, "\(entry.name) came back as \(entry.colour.hexString)")
    }
    #expect(Color(hex: VPNTilePalette.alarm).hexString == VPNTilePalette.alarm)
}

// MARK: - Changing which VPN a lamp watches

// The block's Preset picker. The VPN is the tile's identity, so choosing
// another one is a move to another key — and the policy the user set on the
// tile comes with it, because nothing about the schedule changed.
@Test @MainActor func changingALampsVPNMovesItsKeyAndKeepsEverythingElse() {
    let subject = testModel(clocks: [desk], tiles: [])
    _ = subject.addTile(VPNConnector.id, to: desk.id)
    let before = TileKey(clockId: desk.id, connectorId: VPNConnector.id, instance: WatchedVPN.pritunl.id)
    var policy = subject.storedPolicy(of: before)!
    policy.refreshSeconds = 42
    _ = subject.saveTile(key: before, policy: policy, config: subject.storedTile(before)?.config)
    // The picker is pressed inside the tile's own settings window, which is
    // aimed at the key that is about to stop existing.
    subject.openDetail(for: before)

    #expect(subject.changeLampVPN(before, to: WatchedVPN.amnezia.id) == .saved)

    let after = TileKey(clockId: desk.id, connectorId: VPNConnector.id, instance: WatchedVPN.amnezia.id)
    #expect(subject.storedPolicy(of: before) == nil)
    #expect(subject.storedPolicy(of: after)?.refreshSeconds == 42)
    // The config follows the key, so the lamp says the VPN its key names.
    #expect(subject.storedTile(after)?.config?.lamp?.vpn == WatchedVPN.amnezia.id)
    #expect(subject.storedTile(after)?.config?.lamp?.slot == .topRight)
    // And the window follows the tile rather than pointing at a key that is
    // gone — the settings would otherwise empty out mid-edit.
    #expect(subject.detailTileKey == after)
}

// Two tiles watching one VPN cannot be told apart on the clock or in the
// settings, so the second one is refused by name.
@Test @MainActor func changingToAVPNAnotherTileAlreadyWatchesIsRefused() {
    let subject = testModel(clocks: [desk], tiles: [])
    _ = subject.addTile(VPNConnector.id, to: desk.id)
    _ = subject.addTile(VPNConnector.id, to: desk.id)
    let pritunl = TileKey(clockId: desk.id, connectorId: VPNConnector.id, instance: WatchedVPN.pritunl.id)

    #expect(
        subject.changeLampVPN(pritunl, to: WatchedVPN.amnezia.id)
            == .refused("Amnezia already has a tile on Desk")
    )
    #expect(lampTiles(of: subject).count == 2)
    #expect(subject.storedPolicy(of: pritunl) != nil)
}

// The same VPN is not a move at all, and must not delete-and-recreate the
// tile it is already on: a picker re-reporting its own value is normal.
@Test @MainActor func choosingTheVPNTheLampAlreadyWatchesChangesNothing() {
    let subject = testModel(clocks: [desk], tiles: [])
    _ = subject.addTile(VPNConnector.id, to: desk.id)
    let pritunl = TileKey(clockId: desk.id, connectorId: VPNConnector.id, instance: WatchedVPN.pritunl.id)

    #expect(subject.changeLampVPN(pritunl, to: WatchedVPN.pritunl.id) == .saved)
    #expect(lampTiles(of: subject).count == 1)
    #expect(subject.storedPolicy(of: pritunl) != nil)
}
