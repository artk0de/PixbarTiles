// Tests/PixelClockKitTests/TileDefaultsTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The design's defaults table, row by row. Each row is spelled out in full
// rather than compared field by field, so a default gaining a field it should
// not have fails here too.

@Test func aNewWeatherTileRunsEveryTenMinutesThroughEverything() {
    #expect(TileDefaults.weather == TilePolicy(
        isPaused: false,
        refreshSeconds: 600,
        focus: FocusRule(silencedIn: [], whenUnknown: .run),
        window: .always
    ))
}

@Test func aNewClaudeTileRunsEveryFiveMinutesOutsideDoNotDisturbAndSleep() {
    #expect(TileDefaults.claude == TilePolicy(
        isPaused: false,
        refreshSeconds: 300,
        focus: FocusRule(silencedIn: [.doNotDisturb, .sleep], whenUnknown: .run),
        window: .always
    ))
}

@Test func aNewAnecdoteTileKeepsTheNightAndHoldsWhenItCannotTell() {
    #expect(TileDefaults.anecdotes == TilePolicy(
        isPaused: false,
        refreshSeconds: 1_800,
        focus: FocusRule(silencedIn: [.doNotDisturb, .sleep], whenUnknown: .hold),
        window: .quiet(HourWindow(startHour: 23, endHour: 8))
    ))
}

@Test func aNewVPNTileRechecksEveryMinuteThroughEverything() {
    #expect(TileDefaults.vpn == TilePolicy(
        isPaused: false,
        refreshSeconds: 60,
        focus: FocusRule(silencedIn: [], whenUnknown: .run),
        window: .always
    ))
}

// Every default is already on the scale, so no new tile starts at a refresh
// the slider cannot show.
@Test func everyDefaultRefreshIsAStepOfTheScale() {
    for policy in [TileDefaults.weather, TileDefaults.claude, TileDefaults.anecdotes, TileDefaults.vpn] {
        #expect(policy.refresh == TimeInterval(policy.refreshSeconds))
    }
}
