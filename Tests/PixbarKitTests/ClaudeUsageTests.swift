import Foundation
import Testing
@testable import PixbarKit

// What the clock shows about a weekly Claude allowance, and the one number it
// is allowed to show.
//
// The allowance itself moves — a promotion widens it, a plan change replaces it
// — so nothing here computes a percentage from token counts. The service
// reports `utilization` already in percent against whatever the allowance is
// today, and that figure is the only input.

// MARK: - Which band a reading falls in

// The ramp answers one question: will you run out before the window does. That
// puts its foot late rather than early. A weekly allowance spent evenly passes
// half by Wednesday midday, so colouring that leaves the bar shouting through
// an ordinary week — and a warning that is on half the time is not read at all.
@Test func anOrdinaryWeekLeavesTheBarInItsRestingColour() {
    #expect(CodeUsage.Band(utilization: 0) == .steady)
    #expect(CodeUsage.Band(utilization: 50) == .steady)
    #expect(CodeUsage.Band(utilization: 74) == .steady)
}

// Past three quarters it steps every five points rather than leaping. Three
// bands left eighty-one and eighty-nine the same colour, so the reader had
// only the bar's length to tell them apart.
@Test func eachThresholdOpensItsOwnBand() {
    #expect(CodeUsage.Band(utilization: 75) == .watch)
    #expect(CodeUsage.Band(utilization: 79) == .watch)
    #expect(CodeUsage.Band(utilization: 80) == .warm)
    #expect(CodeUsage.Band(utilization: 84) == .warm)
    #expect(CodeUsage.Band(utilization: 85) == .hot)
    #expect(CodeUsage.Band(utilization: 89) == .hot)
    #expect(CodeUsage.Band(utilization: 90) == .close)
    #expect(CodeUsage.Band(utilization: 94) == .close)
    #expect(CodeUsage.Band(utilization: 95) == .critical)
    #expect(CodeUsage.Band(utilization: 99) == .critical)
    #expect(CodeUsage.Band(utilization: 100) == .spent)
}

// Over a hundred is not impossible — an overage channel keeps serving past the
// bar — and it is the one reading that must not fall back to a calm colour.
@Test func aReadingPastTheEndOfTheBarStaysInTheLastBand() {
    #expect(CodeUsage.Band(utilization: 140) == .spent)
}

@Test func everyBandDrawsADistinctColour() {
    let colours = Set(CodeUsage.Band.allCases.map { $0.fillColour(brand: ClaudeUsage.brandColour) })

    #expect(colours.count == CodeUsage.Band.allCases.count)
    // The resting band is the brand colour, which is what the number is drawn
    // in too: at rest the app reads as one object rather than as a warning.
    #expect(CodeUsage.Band.steady.fillColour(brand: ClaudeUsage.brandColour) == ClaudeUsage.brandColour)
    #expect(CodeUsage.Band.spent.fillColour(brand: ClaudeUsage.brandColour) != ClaudeUsage.brandColour)
}

// Only a full window pulses, and it is the one band the ramp cannot shout any
// louder in colour — `critical` already drives the red channel to 255, so past
// it the face spends motion instead of hue.
@Test func onlyTheSpentBandCarriesASecondColourToPulseTo() {
    #expect(CodeUsage.Band.spent.pulseColour == "#A00000")
    for band in CodeUsage.Band.allCases where band != .spent {
        #expect(band.pulseColour == nil, "\(band)")
    }
}

// MARK: - What reaches the device

@Test func theAppDrawsThePercentageInTheBrandColourOverABandedBar() {
    let output = ClaudeUsageConnector.output(for: ClaudeUsageReading(utilization: 83, resetsAt: nil))

    #expect(output.text == "83%")
    #expect(output.color == ClaudeUsage.brandColour)
    #expect(output.icon == .bundled("ClaudeStar"))
    #expect(output.surface == .app(ClaudeUsageConnector.appName))
    #expect(output.progress?.percent == 83)
    #expect(output.progress?.fill == CodeUsage.Band.warm.fillColour(brand: ClaudeUsage.brandColour))
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

// Which Focus the app survives is asserted against the claude policy row, in
// the target that knows what a Focus is. What this kit knows is only that
// something can shut the gate — see `nothingIsProducedWhileTheFocusIsNotOneOf
// ItsOwn` above.
