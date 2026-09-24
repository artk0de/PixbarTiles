import Foundation
import Testing
@testable import PixbarKit

/// The reader ships inside the kit's resource bundle, which `Scripts/bundle.sh`
/// already copies into the app. If SwiftPM's `.process` rule ever mangles or
/// drops a binary with no extension, this is what says so — the alternative is
/// an app whose battery silently never reads.
@Test func pbtBattShipsInTheKitBundleAsAnElf() throws {
    let url = try #require(
        KitResources.bundle.url(forResource: "pbt-batt", withExtension: nil),
        "pbt-batt is not in the kit resource bundle"
    )
    let bytes = try Data(contentsOf: url)
    #expect(bytes.prefix(4) == Data([0x7F, 0x45, 0x4C, 0x46]))     // \x7fELF
    // ELFCLASS32, little-endian, and EM_ARM in e_machine — an arm64 host build
    // slipping in here would run nowhere.
    #expect(bytes[4] == 1)
    #expect(bytes[5] == 1)
    #expect(bytes[18] == 40)
    #expect(bytes.count > 100)
}
