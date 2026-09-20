import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

private let loan = ["before": "clear", "applied": "rain", "borrower": "weather"]

@Test func anOutstandingLoanMovesOntoTheClockItWasTakenFrom() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(in: defaults)
        defaults.set(loan, forKey: BorrowedOverlayMigration.legacyKey)

        BorrowedOverlayMigration(defaults: defaults).run()

        let moved = UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: clock.id)
        #expect(moved.borrowedOverlay() == BorrowedOverlay(before: "clear", applied: "rain", borrower: "weather"))
    }
}

// The desk clock at that address is a TC002 now. It has no overlay, and a loan
// from the clock that used to answer there is nothing it could give back.
@Test func aTC002AtTheOldAddressInheritsNoLoan() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(.ulanziTC002, in: defaults)
        defaults.set(loan, forKey: BorrowedOverlayMigration.legacyKey)

        BorrowedOverlayMigration(defaults: defaults).run()

        #expect(UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: clock.id).borrowedOverlay() == nil)
        #expect(defaults.bool(forKey: BorrowedOverlayMigration.markerKey))
    }
}

@Test func withNoClockYetTheOverlayStepHasNotRun() throws {
    try withFreshDefaults { defaults in
        defaults.set(loan, forKey: BorrowedOverlayMigration.legacyKey)

        BorrowedOverlayMigration(defaults: defaults).run()

        #expect(defaults.bool(forKey: BorrowedOverlayMigration.markerKey) == false)
    }
}

@Test func theBorrowedOverlayMigrationLeavesTheOldKeyAsItWas() throws {
    try withFreshDefaults { defaults in
        try storeAClock(in: defaults)
        defaults.set(loan, forKey: BorrowedOverlayMigration.legacyKey)

        BorrowedOverlayMigration(defaults: defaults).run()

        #expect(defaults.dictionary(forKey: BorrowedOverlayMigration.legacyKey) as? [String: String] == loan)
    }
}

@Test func theBorrowedOverlayMigrationWritesItsMarkerLast() throws {
    try withFreshDefaults { defaults in
        try storeAClock(in: defaults)
        defaults.set(loan, forKey: BorrowedOverlayMigration.legacyKey)

        BorrowedOverlayMigration(defaults: defaults).run()

        #expect(defaults.writes.last == BorrowedOverlayMigration.markerKey)
    }
}

// The loan was given back on the clock since the first run. The old copy must
// not come back and restore a sky over the user's own overlay.
@Test func aSecondBorrowedOverlayMigrationChangesNothing() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(in: defaults)
        defaults.set(loan, forKey: BorrowedOverlayMigration.legacyKey)
        BorrowedOverlayMigration(defaults: defaults).run()
        UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: clock.id).forget()

        BorrowedOverlayMigration(defaults: defaults).run()

        #expect(UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: clock.id).borrowedOverlay() == nil)
    }
}
