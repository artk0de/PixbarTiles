import Foundation
import Testing
@testable import PixelClockKit

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func record(_ text: String) throws -> TilePolicyRecord {
    try JSONDecoder().decode(TilePolicyRecord.self, from: Data(text.utf8))
}

// What Phase 1 wrote. Its Focus rule and hours are whatever every tile of its
// connector had until now, which is the defaults row.
@Test func aRecordFromBeforeTheFocusAndTheHoursReadsThemFromTheDefaults() throws {
    let stored = try record(#"{"isPaused":true,"refreshSeconds":1800}"#)

    let policy = TilePolicy(stored, defaults: TileDefaults.anecdotes)

    #expect(policy == TilePolicy(
        isPaused: true,
        refreshSeconds: 1_800,
        focus: TileDefaults.anecdotes.focus,
        window: TileDefaults.anecdotes.window
    ))
}

@Test func whatARecordSaysWinsOverTheDefaults() throws {
    let stored = try record("""
    {"focus":{"silencedIn":[],"whenUnknown":"run"},"isPaused":false,"refreshSeconds":300,\
    "window":{"kind":"always"}}
    """)

    let policy = TilePolicy(stored, defaults: TileDefaults.anecdotes)

    #expect(policy.focus == FocusRule(silencedIn: [], whenUnknown: .run))
    #expect(policy.window == .always)
}

@Test func onlyTheMissingKeyIsTakenFromTheDefaults() throws {
    let stored = try record(#"{"isPaused":false,"refreshSeconds":300,"window":{"kind":"always"}}"#)

    let policy = TilePolicy(stored, defaults: TileDefaults.anecdotes)

    #expect(policy.focus == TileDefaults.anecdotes.focus)
    #expect(policy.window == .always)
}

// Written out whole, so a defaults row changed later never moves a tile the
// user already has.
@Test func aPolicyIsStoredWithEveryKeyWrittenOut() throws {
    #expect(try json(TilePolicyRecord(TileDefaults.anecdotes)) == """
    {"focus":{"silencedIn":["doNotDisturb","sleep"],"whenUnknown":"hold"},\
    "isPaused":false,"refreshSeconds":1800,\
    "window":{"endHour":8,"kind":"quiet","startHour":23}}
    """)
}

@Test func aRecordWithoutTheNewKeysIsStillWrittenInPhaseOnesShape() throws {
    #expect(try json(TilePolicyRecord(isPaused: false, refreshSeconds: 600))
        == #"{"isPaused":false,"refreshSeconds":600}"#)
}

@Test func aPolicySurvivesTheRoundTripThroughItsRecord() throws {
    let policy = TilePolicy(
        isPaused: true,
        refreshSeconds: 45,
        focus: FocusRule(silencedIn: [.work], whenUnknown: .hold),
        window: .active(HourWindow(startHour: 10, endHour: 19))
    )
    let stored = try record(try json(TilePolicyRecord(policy)))

    // The weather row is the wrong defaults on purpose: nothing may come from it.
    #expect(TilePolicy(stored, defaults: TileDefaults.weather) == policy)
    // Kept as stored and snapped only when read.
    #expect(stored.refreshSeconds == 45)
}
