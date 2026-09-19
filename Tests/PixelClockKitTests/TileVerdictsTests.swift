import Foundation
import Testing
@testable import PixelClockKit

private let claude = TileKey(clockId: UUID(), connectorId: "claude")
private let weather = TileKey(clockId: UUID(), connectorId: "weather")

@Test func theFirstLookIsNotAChange() {
    var verdicts = TileVerdicts()

    let change = verdicts.update([claude: false, weather: true])

    #expect(change.arrived.isEmpty)
    #expect(change.left.isEmpty)
}

@Test func aTileItsPolicyStopsAllowingHasLeft() {
    var verdicts = TileVerdicts()
    _ = verdicts.update([claude: true])

    let change = verdicts.update([claude: false])

    #expect(change.left == [claude])
    #expect(change.arrived.isEmpty)
}

@Test func aTileItsPolicyStartsAllowingHasArrived() {
    var verdicts = TileVerdicts()
    _ = verdicts.update([claude: false])

    let change = verdicts.update([claude: true])

    #expect(change.arrived == [claude])
    #expect(change.left.isEmpty)
}

@Test func anAnswerThatStaysTheSameIsNotNews() {
    var verdicts = TileVerdicts()
    _ = verdicts.update([claude: true, weather: false])

    for _ in 0..<3 {
        let change = verdicts.update([claude: true, weather: false])
        #expect(change.arrived.isEmpty && change.left.isEmpty)
    }
}

@Test func aTileAddedLaterIsNotAChangeOnItsFirstLook() {
    var verdicts = TileVerdicts()
    _ = verdicts.update([claude: true])

    let change = verdicts.update([claude: true, weather: false])

    #expect(change.left.isEmpty)
}

@Test func aTileRemovedAndAddedAgainStartsFresh() {
    var verdicts = TileVerdicts()
    _ = verdicts.update([claude: true])
    _ = verdicts.update([:])

    let change = verdicts.update([claude: false])

    #expect(change.left.isEmpty)
}
