// Tests/PixelClockKitTests/TilePolicyCodingTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The two keys Part B adds to the stored policy are a contract with every
// launch that comes after this one, so they are pinned byte for byte rather
// than only round-tripped: a round trip passes just as happily after a renamed
// case has changed every stored value.

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func decoded<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(text.utf8))
}

@Test func aFocusRuleIsWrittenInTheDocumentedShape() throws {
    let anecdotes = FocusRule(silencedIn: [.sleep, .doNotDisturb], whenUnknown: .hold)

    #expect(try json(anecdotes) == #"{"silencedIn":["doNotDisturb","sleep"],"whenUnknown":"hold"}"#)
}

@Test func eachKindOfWindowIsWrittenByName() throws {
    #expect(try json(TileWindow.always) == #"{"kind":"always"}"#)
    #expect(
        try json(TileWindow.quiet(HourWindow(startHour: 23, endHour: 8)))
            == #"{"endHour":8,"kind":"quiet","startHour":23}"#
    )
    #expect(
        try json(TileWindow.active(HourWindow(startHour: 10, endHour: 19)))
            == #"{"endHour":19,"kind":"active","startHour":10}"#
    )
}

// Six elements, so a set written in its own order — which changes from launch
// to launch — matches the declared one by chance once in 720 runs, not once in
// two.
@Test func theQuietStatesAreWrittenInTheOrderTheyAreDeclared() throws {
    let everything = FocusRule(silencedIn: Set(MacFocus.allCases), whenUnknown: .run)

    #expect(try json(everything) == """
    {"silencedIn":["noFocus","work","personal","doNotDisturb","sleep","unknown"],\
    "whenUnknown":"run"}
    """)
}

@Test func everyRuleAndWindowSurvivesARoundTrip() throws {
    let rules = [
        FocusRule(),
        FocusRule(silencedIn: [.noFocus, .personal], whenUnknown: .hold),
    ]
    for rule in rules {
        #expect(try decoded(FocusRule.self, try json(rule)) == rule)
    }
    let windows: [TileWindow] = [
        .always,
        .quiet(HourWindow(startHour: 23, endHour: 8)),
        .active(HourWindow(startHour: 10, endHour: 19)),
    ]
    for window in windows {
        #expect(try decoded(TileWindow.self, try json(window)) == window)
    }
}

@Test func aStoredHourPastTheClockIsReadRoundIt() throws {
    let window = try decoded(TileWindow.self, #"{"kind":"quiet","startHour":24,"endHour":8}"#)

    #expect(window == .quiet(HourWindow(startHour: 0, endHour: 8)))
}

@Test func aWindowOfAKindThisAppDoesNotKnowIsRefused() {
    #expect(throws: DecodingError.self) {
        _ = try decoded(TileWindow.self, #"{"kind":"sometimes"}"#)
    }
}

@Test func aWindowMissingItsHoursIsRefused() {
    #expect(throws: DecodingError.self) {
        _ = try decoded(TileWindow.self, #"{"kind":"quiet","startHour":23}"#)
    }
}

@Test func aStateThisAppDoesNotKnowIsRefused() {
    #expect(throws: DecodingError.self) {
        _ = try decoded(FocusRule.self, #"{"silencedIn":["gaming"],"whenUnknown":"run"}"#)
    }
}
