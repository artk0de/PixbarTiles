import Foundation
import Testing
@testable import AwtrixKit

// What the clock shows about a weekly Claude allowance, and the one number it
// is allowed to show.
//
// The allowance itself moves — a promotion widens it, a plan change replaces it
// — so nothing here computes a percentage from token counts. The service
// reports `utilization` already in percent against whatever the allowance is
// today, and that figure is the only input.

// MARK: - Which band a reading falls in

// The bands answer one question: will you run out before the week does. That
// makes the thresholds late rather than early. A weekly allowance spent evenly
// passes half by Wednesday midday and three quarters by Friday, so colouring
// those states leaves the bar shouting through an ordinary week — and a warning
// that is on half the time is not read at all.
@Test func anOrdinaryWeekLeavesTheBarInItsRestingColour() {
    #expect(ClaudeUsageBand(utilization: 0) == .steady)
    #expect(ClaudeUsageBand(utilization: 50) == .steady)
    #expect(ClaudeUsageBand(utilization: 79) == .steady)
}

@Test func eachThresholdOpensItsOwnBand() {
    #expect(ClaudeUsageBand(utilization: 80) == .watch)
    #expect(ClaudeUsageBand(utilization: 89) == .watch)
    #expect(ClaudeUsageBand(utilization: 90) == .close)
    #expect(ClaudeUsageBand(utilization: 94) == .close)
    #expect(ClaudeUsageBand(utilization: 95) == .spent)
    #expect(ClaudeUsageBand(utilization: 100) == .spent)
}

// Over a hundred is not impossible — an overage channel keeps serving past the
// bar — and it is the one reading that must not fall back to a calm colour.
@Test func aReadingPastTheEndOfTheBarStaysInTheLastBand() {
    #expect(ClaudeUsageBand(utilization: 140) == .spent)
}

@Test func everyBandDrawsADistinctColour() {
    let colours = Set(ClaudeUsageBand.allCases.map(\.fillColour))

    #expect(colours.count == ClaudeUsageBand.allCases.count)
    // The resting band is the brand colour, which is what the number is drawn
    // in too: at rest the app reads as one object rather than as a warning.
    #expect(ClaudeUsageBand.steady.fillColour == ClaudeUsage.brandColour)
    #expect(ClaudeUsageBand.spent.fillColour != ClaudeUsage.brandColour)
}

// MARK: - Reading the service's answer

/// Captured from the live service on 2026-08-20, trimmed but not reshaped.
///
/// Written down from a real answer rather than imagined, and that distinction
/// cost a rewrite: the first version of this file invented a `rate_limits`
/// array of named entries, and every test passed against a parser built for the
/// same invention. The service returns bars as TOP-LEVEL KEYS, a utilization
/// that is fractional, and a timestamp carrying sub-second precision and an
/// offset — which the plain ISO-8601 reader silently fails to parse.
let usageBody = """
{"five_hour":{"utilization":0.0,"resets_at":"2026-08-20T16:00:00.484657+00:00",
              "limit_dollars":null},
 "seven_day":{"utilization":78.0,"resets_at":"2026-08-21T15:00:00.484683+00:00",
              "limit_dollars":null},
 "seven_day_opus":null,
 "seven_day_sonnet":null,
 "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":0.0},
 "limits":[{"kind":"session","group":"session","percent":0,"severity":"normal",
            "is_active":false},
           {"kind":"weekly_all","group":"weekly","percent":78,"severity":"warning",
            "is_active":true}]}
"""

@Test func theWeeklyBarIsTheOneRead() throws {
    let reading = try #require(ClaudeUsageReading(json: Data(usageBody.utf8)))

    // `seven_day`, and not the five-hour bar sitting beside it at the same
    // level, nor any of the per-model weekly ones — which come back null on
    // this account and would read as zero to anything less careful.
    #expect(reading.utilization == 78)

    let expected = ISO8601DateFormatter()
    expected.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    #expect(reading.resetsAt == expected.date(from: "2026-08-21T15:00:00.484683+00:00"))
}

// The service reports utilization as a fraction, so the rounding is this app's
// decision and is written down: nearest, because a bar drawn at 78 and a number
// reading 79 beside it is the kind of disagreement nobody can explain.
@Test func aFractionalUtilizationIsRoundedToTheNearestWholePercent() throws {
    let low = try #require(ClaudeUsageReading(json: Data(#"{"seven_day":{"utilization":78.4}}"#.utf8)))
    let high = try #require(ClaudeUsageReading(json: Data(#"{"seven_day":{"utilization":78.6}}"#.utf8)))

    #expect(low.utilization == 78)
    #expect(high.utilization == 79)
}

@Test func anAnswerWithoutTheWeeklyBarIsNoReadingAtAll() {
    // Nil rather than zero. Zero is a real reading that means "nothing spent
    // this week", and showing it because the answer was unparseable would put
    // a confident, wrong, calm number on the clock.
    let onlyFiveHour = #"{"five_hour":{"utilization":12.0}}"#
    #expect(ClaudeUsageReading(json: Data(onlyFiveHour.utf8)) == nil)

    // The bar keys ARE present and null on an account with no per-model split,
    // so an explicit null has to read as absence rather than as a zero bar.
    #expect(ClaudeUsageReading(json: Data(#"{"seven_day":null}"#.utf8)) == nil)

    #expect(ClaudeUsageReading(json: Data(#"{"error":"nope"}"#.utf8)) == nil)
    #expect(ClaudeUsageReading(json: Data("not json at all".utf8)) == nil)
}

@Test func aWeeklyBarWithNoResetTimeIsStillAReading() throws {
    let noReset = #"{"seven_day":{"utilization":40.0,"resets_at":null}}"#

    let reading = try #require(ClaudeUsageReading(json: Data(noReset.utf8)))

    #expect(reading.utilization == 40)
    #expect(reading.resetsAt == nil)
}

// MARK: - What reaches the device

@Test func theAppDrawsThePercentageInTheBrandColourOverABandedBar() {
    let output = ClaudeUsageConnector.output(for: ClaudeUsageReading(utilization: 83, resetsAt: nil))

    #expect(output.text == "83%")
    #expect(output.color == ClaudeUsage.brandColour)
    #expect(output.icon == .bundled("ClaudeStar"))
    #expect(output.surface == .app(ClaudeUsageConnector.appName))
    #expect(output.progress?.percent == 83)
    #expect(output.progress?.fill == ClaudeUsageBand.watch.fillColour)
}

// The bar is drawn by the firmware from three fields, and a percentage outside
// nought to a hundred is not one of the things it draws — it clips or ignores.
@Test func theBarIsClampedToWhatTheFirmwareCanDraw() {
    let over = ClaudeUsageConnector.output(for: ClaudeUsageReading(utilization: 140, resetsAt: nil))

    #expect(over.progress?.percent == 100)
    // The TEXT keeps the true figure. Clamping the bar is about what the eight
    // by thirty-two can draw; hiding an overage from the reader is not.
    #expect(over.text == "140%")
}

@Test func onlyTheProgressFieldsThatAreSetReachTheFirmware() {
    let plain = AppPayload(text: "hi")
    let barred = AppPayload(
        text: "83%",
        progress: ProgressBar(percent: 83, fill: "#FFD24A", track: "#303030")
    )

    #expect(plain.jsonObject["progress"] == nil)
    #expect(plain.jsonObject["progressC"] == nil)
    #expect(plain.jsonObject["progressBC"] == nil)

    #expect(barred.jsonObject["progress"] as? Int == 83)
    #expect(barred.jsonObject["progressC"] as? String == "#FFD24A")
    #expect(barred.jsonObject["progressBC"] as? String == "#303030")
}

// MARK: - When it is shown at all

// Two Focus modes and no others, which is what was asked for. The interesting
// case is the third one.
@Test func theAppBelongsToTheWorkingAndPersonalFocusesOnly() {
    #expect(ClaudeUsage.shows(focusIdentifier: "com.apple.focus.work"))
    #expect(ClaudeUsage.shows(focusIdentifier: "com.apple.focus.personal-time"))

    #expect(!ClaudeUsage.shows(focusIdentifier: "com.apple.donotdisturb.mode.default"))
    #expect(!ClaudeUsage.shows(focusIdentifier: "com.apple.sleep.sleep-mode"))
    #expect(!ClaudeUsage.shows(focusIdentifier: "com.apple.focus.fitness"))
    #expect(!ClaudeUsage.shows(focusIdentifier: nil))
}
