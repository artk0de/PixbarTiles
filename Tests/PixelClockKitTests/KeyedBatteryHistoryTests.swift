import Foundation
import Testing
@testable import PixelClockKit

private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suite = "keyed-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

private func series(_ uid: String, uptime: Int) -> BatteryHistory {
    BatteryHistory(uid: uid, uptime: uptime, samples: [])
}

@Test func eachClocksBatterySeriesIsKeptUnderItsOwnName() throws {
    try withDefaults { defaults in
        UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: "desk").save(series("desk", uptime: 1))
        UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: "kitchen").save(series("kitchen", uptime: 2))

        #expect(UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: "desk").storedHistory() == series("desk", uptime: 1))
        #expect(UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: "kitchen").storedHistory() == series("kitchen", uptime: 2))
    }
}

// A clock that has never answered has no name yet, and so nothing to resume.
@Test func aClockThatHasNeverAnsweredStartsCold() throws {
    try withDefaults { defaults in
        UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: "desk").save(series("desk", uptime: 1))

        #expect(UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: nil).storedHistory() == nil)
    }
}

// Its first answer names it. The series from that poll goes where the next
// launch — which knows the name from the clock record — will look.
@Test func aSeriesIsSavedUnderTheClockItCameOff() throws {
    try withDefaults { defaults in
        UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: nil).save(series("desk", uptime: 1))

        #expect(UserDefaultsBatteryHistoryStore(defaults: defaults, hardwareIdentity: "desk").storedHistory() == series("desk", uptime: 1))
    }
}
