import SwiftUI
import Testing
@testable import PixelClockTilesApp

// The two editors every surface renames and removes through. Their rules are
// values, tested as values — the rest of them is layout.

@Suite struct InlineRenameFieldTests {
    // The rule the Save button and Return both read. One rule, because two
    // copies of it is how Return comes to accept what the button refuses.
    @Test func blankIsNotAName() {
        #expect(InlineRenameField.canSave("", current: "Desk") == false)
        #expect(InlineRenameField.canSave("   ", current: "Desk") == false)
        #expect(InlineRenameField.canSave("\n\t ", current: "Desk") == false)
    }

    // The name it already has is not a change. The field opens on the current
    // name, so this is what an opened-and-closed rename is — and saving it
    // would write a record and publish a change for nothing.
    @Test func theNameItAlreadyHasIsNotARename() {
        #expect(InlineRenameField.canSave("Desk", current: "Desk") == false)
        // Including with the whitespace a cursor leaves behind.
        #expect(InlineRenameField.canSave("  Desk  ", current: "Desk") == false)
    }

    @Test func anActualNewNameSaves() {
        #expect(InlineRenameField.canSave("Loft", current: "Desk"))
        #expect(InlineRenameField.newName(from: "  Loft  ") == "Loft")
    }

    // The name that goes out is the trimmed one, not what was typed: a clock
    // called "Loft " and one called "Loft" are the same clock to everyone
    // except the string comparison.
    @Test func whatIsSavedIsTrimmed() {
        #expect(InlineRenameField.newName(from: "\tKitchen \n") == "Kitchen")
        #expect(InlineRenameField.newName(from: "Two words") == "Two words")
    }
}
