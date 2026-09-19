// Tests/PixelClockKitTests/UlanziFaceTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// A connector is two halves, and a second clock model gets a second face over
// the same reading. Nil is the default: no connector is forced to grow a TC002
// face (D11).

/// An AWTRIX-only stub — it carries no `ulanziFace` and so must inherit the
/// nil default.
private struct FacelessConnector: Connector {
    let id = "faceless"
    let displayName = "Faceless"
    let defaultInterval: TimeInterval = 60
    let value = 7

    func read() async throws -> Int { value }
    var awtrixFace: AwtrixFace<Int> { AwtrixFace { _ in AwtrixDelivery(text: "7") } }
}

/// Carries a TC002 face over the same reading its AWTRIX face draws.
private struct StubbedUlanziConnector: Connector {
    let id = "stub"
    let displayName = "Stub"
    let defaultInterval: TimeInterval = 60
    let reading = 42
    let renderedScene = UlanziScene.idle

    func read() async throws -> Int { reading }
    var awtrixFace: AwtrixFace<Int> { AwtrixFace { _ in AwtrixDelivery(text: "42") } }
    // Optional, matching the requirement exactly — a non-optional would not
    // witness it, and the nil default would answer for this connector.
    var ulanziFace: UlanziFace<Int>? {
        UlanziFace { [renderedScene] _ in UlanziDelivery(scene: renderedScene) }
    }
}

/// Its read fails; the failure must reach the caller undrawn.
private struct FailingUlanziConnector: Connector {
    let id = "failing"
    let displayName = "Failing"
    let defaultInterval: TimeInterval = 60

    struct Failure: Error {}

    func read() async throws -> Int { throw Failure() }
    var awtrixFace: AwtrixFace<Int> { AwtrixFace { _ in AwtrixDelivery(text: "?") } }
    var ulanziFace: UlanziFace<Int>? {
        UlanziFace { _ in UlanziDelivery(scene: .idle) }
    }
}

@Suite struct UlanziFaceTests {
    @Test func connectorWithoutFaceProducesNil() async throws {
        let connector = FacelessConnector()
        #expect(connector.ulanziFace == nil)
        let delivered = try await connector.produceUlanzi()
        #expect(delivered == nil)
    }

    @Test func connectorWithFaceRendersItsReading() async throws {
        let connector = StubbedUlanziConnector()
        let delivery = try #require(await connector.produceUlanzi())
        #expect(delivery.scene == connector.renderedScene)
    }

    @Test func readErrorPropagates() async {
        do {
            _ = try await FailingUlanziConnector().produceUlanzi()
            Issue.record("expected throw")
        } catch { /* expected */ }
    }
}
