// Tests/PixelClockKitTests/ClaudeDisplayMetricTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// Which figure the Claude tile shows, as the tile detail names it: the daily
// limit, the weekly window, or the current session. A plain type — the faces
// read it, the picker writes it, and neither knows the other exists.

/// One reading carrying all three figures.
private let reading = ClaudeUsageReading(
    utilization: 41,
    resetsAt: nil,
    fiveHour: ClaudeUsageWindow(utilization: 23, resetsAt: Date(timeIntervalSince1970: 1_738_425_600)),
    contextWindow: 8,
    observedAt: nil
)

@Test func theDailyLimitIsTheRollingFiveHourWindow() {
    #expect(ClaudeDisplayMetric.daily.percentage(in: reading) == 23)
}

@Test func theWeeklyWindowIsTheReadingOwnFigure() {
    #expect(ClaudeDisplayMetric.weekly.percentage(in: reading) == 41)
}

@Test func theCurrentSessionIsTheContextWindow() {
    #expect(ClaudeDisplayMetric.session.percentage(in: reading) == 8)
}

// A window the document did not carry is no figure: nil, which the connector
// turns into no delivery — never a zero invented for a missing answer.
@Test func aMetricWithNoFigureAnswersNil() {
    let bare = ClaudeUsageReading(utilization: 41, resetsAt: nil)

    #expect(ClaudeDisplayMetric.daily.percentage(in: bare) == nil)
    #expect(ClaudeDisplayMetric.weekly.percentage(in: bare) == 41)
    #expect(ClaudeDisplayMetric.session.percentage(in: bare) == nil)
}

// The metric lives in the tile's config, so the stored word round-trips.
@Test func theMetricRoundTripsThroughTheTileConfig() throws {
    for metric in ClaudeDisplayMetric.allCases {
        let encoded = try JSONEncoder().encode(TileConfig.claude(metric))
        #expect(try JSONDecoder().decode(TileConfig.self, from: encoded) == .claude(metric))
    }
}

// An old tile whose config names another connector, or carries none, reads as
// the weekly figure — what the tile drew before the selector existed.
@Test func aConfigWithoutClaudeAnswersTheWeeklyDefault() {
    #expect(TileConfig.claude(.daily).claude == .daily)
    #expect(TileConfig.weather(Coordinates(latitude: 55.7, longitude: 37.6)).claude == nil)
    #expect(TileConfig.vpn(VPNTileConfig(vpn: "pritunl", slot: .topRight, upColour: "#90EE90", whenDown: .off)).claude == nil)
}

@Test func thePickerNamesEachMetric() {
    #expect(ClaudeDisplayMetric.daily.displayName == "Daily limit")
    #expect(ClaudeDisplayMetric.weekly.displayName == "Weekly window")
    #expect(ClaudeDisplayMetric.session.displayName == "Current session")
}
