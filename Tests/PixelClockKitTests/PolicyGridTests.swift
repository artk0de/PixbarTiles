// Tests/PixelClockKitTests/PolicyGridTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// Each default drawn as a picture of all 144 cells: one row per state in the
// order `MacFocus` declares them, one column per hour from 00 to 23, `#` where
// the tile runs and `.` where it is held. Every cell is pinned, and a failing
// row reads as the hours it got wrong.

private func picture(_ grid: PolicyGrid) -> [String] {
    MacFocus.allCases.map { focus in
        String((0..<24).map { grid.runs(in: focus, atHour: $0) ? "#" : "." })
    }
}

private let allDay = String(repeating: "#", count: 24)
private let never = String(repeating: ".", count: 24)

@Test func theWeatherRunsInEveryCell() {
    #expect(picture(TileDefaults.weather.grid) == Array(repeating: allDay, count: 6))
}

@Test func theVPNRunsInEveryCell() {
    #expect(picture(TileDefaults.vpn.grid) == Array(repeating: allDay, count: 6))
}

@Test func claudeIsHeldAllDayUnderDoNotDisturbAndSleepAndNowhereElse() {
    #expect(picture(TileDefaults.codeUsage.grid) == [
        allDay, // No Focus
        allDay, // Work
        allDay, // Personal
        never,  // Do Not Disturb
        never,  // Sleep
        allDay, // Other Focus — run
    ])
}

@Test func anecdotesKeepTheNightAndEveryFocusTheyCannotSpeakIn() {
    //                     000000000011111111112222
    //                     012345678901234567890123
    let daytime = "........###############."
    #expect(picture(TileDefaults.anecdotes.grid) == [
        daytime, // No Focus
        daytime, // Work
        daytime, // Personal
        never,   // Do Not Disturb
        never,   // Sleep
        never,   // Other Focus — hold
    ])
}

@Test func workingHoursInWorkOnlyLightTheOfficeDayOfOneRow() {
    let office = TilePolicy(
        refreshSeconds: 60,
        focus: FocusRule(
            silencedIn: [.noFocus, .personal, .doNotDisturb, .sleep], whenUnknown: .hold
        ),
        window: .active(HourWindow(startHour: 10, endHour: 19))
    )

    #expect(picture(office.grid) == [
        never,
        "..........#########.....", // Work, 10:00–19:00
        never, never, never, never,
    ])
}

@Test func aPausedTileRunsInNoCellAtAll() {
    var paused = TileDefaults.weather
    paused.isPaused = true

    #expect(paused.grid.isEmpty)
    #expect(picture(paused.grid) == Array(repeating: never, count: 6))
}

@Test func aGridHasOneCellPerStatePerHour() {
    #expect(TileDefaults.weather.grid.running.count == 144)
}
