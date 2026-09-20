// Tests/PixelClockKitTests/UlanziTileBoardTests.swift
import Foundation
import Testing
@testable import PixelClockKit

private func drawnScene(colour: Pixel) -> UlanziScene {
    var canvas = PixelCanvas()
    canvas.fill(colour)
    return UlanziScene(frames: [UlanziFrame(duration: 5, draw: [canvas.drawCommands()])])
}

@Suite struct UlanziTileBoardTests {
    @Test func freshBoardAnswersIdleForKnownTileAndNilForUnknown() {
        var board = UlanziTileBoard()
        board.register(tileId: "weather")

        #expect(board.frame(forTile: "weather") == UlanziScene.idle)
        #expect(board.frame(forTile: "never-seen") == nil)
    }

    @Test func upsertThenDeliverAnswersTheLastScene() {
        var board = UlanziTileBoard()
        let scene = drawnScene(colour: .white)

        board.upsert(UlanziDelivery(scene: scene), forTile: "claude")

        #expect(board.frame(forTile: "claude") == scene)
    }

    @Test func idleFrameShowsWhilePausedAndDeliveryOverwritesIt() {
        var board = UlanziTileBoard()
        let scene = drawnScene(colour: .white)
        board.upsert(UlanziDelivery(scene: scene), forTile: "claude")

        board.markIdle("claude")
        #expect(board.frame(forTile: "claude") == UlanziScene.idle)

        let next = drawnScene(colour: .black)
        board.upsert(UlanziDelivery(scene: next), forTile: "claude")
        #expect(board.frame(forTile: "claude") == next)
    }

    @Test func removedTilesDiffsAgainstLiveIds() {
        var board = UlanziTileBoard()
        for id in ["a", "b", "c"] { board.register(tileId: id) }

        #expect(board.removedTiles(given: ["a", "c"]) == ["b"])
    }

    @Test func lastDeliverySurvivesIdleMarking() {
        var board = UlanziTileBoard()
        let scene = drawnScene(colour: .white)
        board.upsert(UlanziDelivery(scene: scene), forTile: "weather")

        board.markIdle("weather")

        // The recovery re-push source: the last real scene, not the idle frame.
        #expect(board.lastScene(forTile: "weather") == scene)
        #expect(board.lastScene(forTile: "never-seen") == nil)
    }

    @Test func removedTileIsForgottenSoRecoveryCannotRecreateItsPage() {
        var board = UlanziTileBoard()
        board.register(tileId: "a")
        board.register(tileId: "b")

        board.remove(tileId: "a")

        #expect(board.tileIds == ["b"])
        #expect(board.frame(forTile: "a") == nil)
        #expect(board.lastScene(forTile: "a") == nil)
    }
}
