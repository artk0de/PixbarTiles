// Sources/PixelClockTilesApp/MacFocusResolution.swift
import Foundation
import PixelClockKit

extension MacFocus {
    /// The Focus the Mac is in, as far as this app may believe macOS.
    ///
    /// | What macOS says                                   | MacFocus        |
    /// | ------------------------------------------------- | --------------- |
    /// | the centre is not authorized                      | `.noFocus`      |
    /// | authorized, a mode read from the database         | that mode, or `.unknown` |
    /// | authorized, the database says nothing is on       | `.noFocus`      |
    /// | authorized, no mode readable, `isFocused == false`| `.noFocus`      |
    /// | authorized, no mode readable, `isFocused == true` | `.unknown`      |
    ///
    /// An unauthorized centre is `.noFocus` rather than `.unknown` because its
    /// `isFocused` is false whatever is on, and a mode read without the grant
    /// is not evidence either — so every tile falls back to its hours alone,
    /// which is what `QuietRule.quietHours` did for the whole app.
    ///
    /// A mode read from the database wins over the boolean, which is the
    /// database's own summary read a moment apart.
    static func resolved(
        access: FocusAccess, activeMode: ActiveFocusMode, isFocused: Bool
    ) -> MacFocus {
        guard access == .authorized else { return .noFocus }
        switch activeMode {
        case let .mode(identifier):
            return MacFocus(modeIdentifier: identifier)
        case .noFocus:
            return .noFocus
        case .cannotTell:
            return isFocused ? .unknown : .noFocus
        }
    }

    /// The same rule, asked of the centre as it answers right now.
    init(reading status: any FocusStatusReading) {
        self = .resolved(
            access: status.access, activeMode: status.activeMode, isFocused: status.isFocused
        )
    }
}
