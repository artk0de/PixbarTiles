import Foundation
import Testing
@testable import PixelClockKit

private let desk = UUID()
private let kitchen = UUID()

private func tile(
    _ name: String,
    on clock: UUID = desk,
    lamp slot: IndicatorSlot = .middleRight,
    workingIn focuses: Set<MacFocus>,
    _ window: TileWindow = .always,
    paused: Bool = false
) -> LampTile {
    LampTile(
        key: TileKey(clockId: clock, connectorId: "vpn", instance: name.lowercased()),
        name: name,
        slot: slot,
        policy: TilePolicy(
            isPaused: paused,
            refreshSeconds: 60,
            focus: FocusRule(
                silencedIn: Set(MacFocus.allCases).subtracting(focuses).subtracting([.unknown]),
                whenUnknown: .hold
            ),
            window: window
        )
    )
}

private let officeHours = TileWindow.active(HourWindow(startHour: 10, endHour: 19))

@Test func theDesignsOwnExampleIsRefusedInItsOwnWords() throws {
    let pritunl = tile("Pritunl", workingIn: [.work])
    let wireGuard = tile("WireGuard", workingIn: [.work], officeHours)

    let conflict = try #require(LampConflict.check(wireGuard, against: [pritunl]))

    #expect(conflict.message == "Pritunl and WireGuard both claim the middle lamp: Work, 10:00–19:00")
}

@Test func tilesTakingTurnsOnOneLampAreAccepted() {
    let work = tile("Pritunl", workingIn: [.work])
    let personal = tile("Amnezia", workingIn: [.personal])

    #expect(LampConflict.check(personal, against: [work]) == nil)
}

@Test func tilesOnDifferentLampsNeverConflict() {
    let top = tile("Pritunl", lamp: .topRight, workingIn: [.work])
    let bottom = tile("Amnezia", lamp: .bottomRight, workingIn: [.work])

    #expect(LampConflict.check(bottom, against: [top]) == nil)
}

@Test func tilesOnDifferentClocksNeverConflict() {
    let desks = tile("Pritunl", workingIn: [.work])
    let kitchens = tile("Amnezia", on: kitchen, workingIn: [.work])

    #expect(LampConflict.check(kitchens, against: [desks]) == nil)
}

// Saving an edit to a tile hands the check a list that still holds the tile's
// previous self. That is not a second tile.
@Test func aTileDoesNotConflictWithItsOwnEarlierSelf() {
    let before = tile("Pritunl", workingIn: [.work])
    let after = tile("Pritunl", workingIn: [.work, .personal])

    #expect(LampConflict.check(after, against: [before]) == nil)
}

// Unpausing is a save, asked the same question.
@Test func aPausedTileClaimsNothingUntilItIsUnpaused() {
    let pritunl = tile("Pritunl", workingIn: [.work])

    #expect(LampConflict.check(tile("Amnezia", workingIn: [.work], paused: true), against: [pritunl]) == nil)
    #expect(LampConflict.check(tile("Amnezia", workingIn: [.work]), against: [pritunl]) != nil)
}
