// Tests/PixbarKitTests/TileDefaultsTests.swift
import Foundation
import Testing
@testable import PixbarKit

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

// A minute, not the five it started at: a subscription's remaining limit is
// watched rather than glanced at, and a bar that moves five minutes after the
// spending did is a bar nobody trusts.
//
// ONE policy for both coding-subscription tiles. z.ai's used to be the bare
// interval with no Focus rule at all, so a z.ai figure stayed lit under Do Not
// Disturb where a Claude one went dark. That was neglect, not a decision.
@Test func bothCodingTilesRunEveryMinuteOutsideDoNotDisturbAndSleep() {
    #expect(TileDefaults.codeUsage == TilePolicy(
        isPaused: false,
        refreshSeconds: 60,
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
    for policy in [TileDefaults.weather, TileDefaults.codeUsage, TileDefaults.anecdotes, TileDefaults.vpn] {
        #expect(policy.refresh == TimeInterval(policy.refreshSeconds))
    }
}
