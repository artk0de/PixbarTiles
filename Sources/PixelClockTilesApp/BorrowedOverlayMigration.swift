// Sources/PixelClockTilesApp/BorrowedOverlayMigration.swift
import Foundation
import PixelClockKit

/// Moves an outstanding overlay loan onto the clock it was taken from.
///
/// The first clock, because that is the one every loan so far was taken from.
/// Only while it is still an AWTRIX clock: a loan is an AWTRIX overlay, and a
/// TC002 now answering at the same address has none to give back to. Copied as
/// stored, three strings, so nothing is re-encoded on the way.
struct BorrowedOverlayMigration {
    static let markerKey = "migration.borrowedOverlay"
    static let legacyKey = "borrowedOverlay"

    let defaults: UserDefaults

    func run() {
        guard defaults.bool(forKey: Self.markerKey) == false else { return }
        guard let clock = ClockStore(defaults: defaults).all().first else { return }
        if clock.model == .awtrix3, let loan = defaults.dictionary(forKey: Self.legacyKey) {
            defaults.set(loan, forKey: UserDefaultsBorrowedOverlayStore.key(forClock: clock.id))
        }
        defaults.set(true, forKey: Self.markerKey)
    }
}
