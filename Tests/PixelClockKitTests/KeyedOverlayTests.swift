import Foundation
import Testing
@testable import PixelClockKit

@Test func eachClocksOverlayLoanIsKeptApart() throws {
    let suite = "overlay-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let desk = UUID(), kitchen = UUID()
    let loan = BorrowedOverlay(before: "clear", applied: "rain", borrower: "weather")
    UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: desk).record(loan)

    #expect(UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: desk).borrowedOverlay() == loan)
    #expect(UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: kitchen).borrowedOverlay() == nil)

    UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: kitchen).forget()
    #expect(UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: desk).borrowedOverlay() == loan)
}
