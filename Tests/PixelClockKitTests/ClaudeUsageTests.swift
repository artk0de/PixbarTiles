import Foundation
import Testing
@testable import PixelClockKit

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

// MARK: - The gate in front of a poll

private struct FixedReport: ClaudeUsageReporting {
    let reading: ClaudeUsageReading?
    func read() async throws -> ClaudeUsageReading? { reading }
}

// Out of hours the connector produces NOTHING, and nothing is what takes the
// app off the clock: no delivery means no refresh, and the lifetime the last
// delivery carried runs out. That is why the lifetime is short — it is doing
// double duty as the way this app leaves the matrix, not only as insurance
// against a crashed Mac.
@Test func nothingIsProducedWhileTheFocusIsNotOneOfItsOwn() async {
    let connector = ClaudeUsageConnector(
        reporter: FixedReport(reading: ClaudeUsageReading(utilization: 78, resetsAt: nil)),
        showsNow: { false }
    )

    await #expect(throws: ClaudeUsageConnector.Failure.outOfFocus) {
        _ = try await connector.produce()
    }
}

@Test func theGateIsAskedBeforeTheServiceIs() async throws {
    // A reporter that would answer, behind a closed gate: the point is that the
    // gate is checked FIRST, so a shut-out poll costs no request at all.
    final class Counting: ClaudeUsageReporting, @unchecked Sendable {
        var asked = 0
        func read() async throws -> ClaudeUsageReading? {
            asked += 1
            return ClaudeUsageReading(utilization: 10, resetsAt: nil)
        }
    }
    let reporter = Counting()

    _ = try? await ClaudeUsageConnector(reporter: reporter, showsNow: { false }).produce()
    #expect(reporter.asked == 0)

    _ = try? await ClaudeUsageConnector(reporter: reporter, showsNow: { true }).produce()
    #expect(reporter.asked == 1)
}

// The app has to leave the clock soon after the Focus does, and the only thing
// that removes it is the lifetime expiring. So the two numbers are chosen
// together: three polls fit inside one lifetime, which survives a couple of
// missed polls while still clearing the matrix within a quarter of an hour.
@Test func thePollAndTheLifetimeAreChosenAgainstEachOther() {
    let connector = ClaudeUsageConnector(reporter: FixedReport(reading: nil))
    let lifetime = ClaudeUsageConnector
        .output(for: ClaudeUsageReading(utilization: 1, resetsAt: nil)).lifetime

    let fits = Double(try! #require(lifetime)) / connector.defaultInterval
    #expect(fits >= 3)
    #expect(try! #require(lifetime) <= 900)
}

// Which Focus the app survives is asserted in `ClaudeFocusAudienceTests`, in
// the target that knows what a Focus is. What this kit knows is only that
// something can shut the gate — see `nothingIsProducedWhileTheFocusIsNotOneOf
// ItsOwn` above.
