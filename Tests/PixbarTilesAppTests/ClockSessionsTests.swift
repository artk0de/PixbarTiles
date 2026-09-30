import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// One session per clock, and one registry per clock beside it: built on
/// first need, kept while the clock is, dropped together when it goes.
@MainActor
@Suite struct ClockSessionsTests {
    private let kitchen = ClockRecord(name: "Kitchen", model: .awtrix3, address: "10.0.0.5")
    private let desk = ClockRecord(name: "Desk", model: .ulanziTC002, address: "10.0.0.6")

    @Test func aClockGetsOneSessionHoweverOftenItIsOpened() {
        var built = 0
        let sessions = ClockSessions(make: { _ in built += 1; return SpyHost() }, makeRegistry: nil)
        sessions.open(kitchen)
        sessions.open(kitchen)
        #expect(built == 1)
        #expect(sessions[kitchen.id] != nil)
        #expect(sessions.clockIds == [kitchen.id])
    }

    @Test func droppingAClockHandsBackItsSessionAndForgetsItsRegistry() {
        var registries = 0
        let sessions = ClockSessions(make: { _ in SpyHost() },
                                     makeRegistry: { _ in registries += 1; return ConnectorRegistry() })
        sessions.open(kitchen)
        _ = sessions.registry(for: kitchen)
        _ = sessions.registry(for: kitchen)
        #expect(registries == 1)
        #expect(sessions.drop(kitchen.id) != nil)
        #expect(sessions[kitchen.id] == nil)
        _ = sessions.registry(for: kitchen)
        #expect(registries == 2)
    }

    @Test func withoutAFactoryThereIsNoPerClockRegistry() {
        let sessions = ClockSessions(make: { _ in SpyHost() }, makeRegistry: nil)
        #expect(sessions.registry(for: kitchen) == nil)
    }

    @Test func onlyATC002SessionAnswersAsOne() {
        let sessions = ClockSessions(make: { _ in SpyHost() }, makeRegistry: nil)
        sessions.open(kitchen)
        #expect(sessions.ulanzi(for: kitchen.id) == nil)
        #expect(sessions.ulanzi(for: desk.id) == nil)
    }
}
