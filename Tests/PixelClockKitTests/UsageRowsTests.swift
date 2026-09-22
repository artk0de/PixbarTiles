// Tests/PixelClockKitTests/UsageRowsTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The shared three-row usage face: three label-and-value bands on the 52×16
// panel, the layout any usage tile draws. Any connector with several windows
// feeds it rows; this suite pins the layout, not any one feeder's figures.

private let ink = UlanziColour.white

/// One row, drawn alone: label pinned to the left edge, value to the right.
///
/// The `S` occupies columns 0–2 of the band, the `-` columns 49–51 — the
/// golden is the whole panel's lit box, which is the point: the two ends are
/// what anchoring means. Each line is the band's five pixel rows, left `S`
/// and right `-` with the unlit middle between them.
@Test func aRowDrawsItsLabelLeftAndItsValueRight() {
    let draw = UsageRows.drawCommands([
        UsageRows.Row(label: "S", value: "-", colour: ink)
    ])

    // `S` rows: .##/#../.#./..#/##. — re-pinned when the glyph was un-mirrored
    // (it used to draw a thin Z). The `-` lights only the middle row, against
    // the right edge.
    #expect(
        goldenASCII(of: draw)
            == [
                ".##.................................................",
                "#...................................................",
                ".#...............................................###",
                "..#.................................................",
                "##..................................................",
            ]
    )
}

// The three bands: five pixel rows each, the spare row above them left dark,
// and a value's own colour only where the value is inked — the label reads in
// the layout's own dim grey, or the rows would shout.
@Test func threeRowsSitOnThreeBandsWithADimLabel() {
    let draw = UsageRows.drawCommands([
        UsageRows.Row(label: "S", value: "-", colour: .white),
        UsageRows.Row(label: "S", value: "-", colour: .white),
        UsageRows.Row(label: "S", value: "-", colour: .white),
    ])
    let width = PixelCanvas.width

    // The spare top row is dark; every band starts where the arithmetic says.
    // Column 1 rather than 0: the un-mirrored `S` opens with `.##`, so its
    // first lit column on the band's top row is the middle one.
    #expect(pixelValue(of: draw, x: 1, y: 0, width: width) == 0)
    #expect(pixelValue(of: draw, x: 1, y: 1, width: width) == UsageRows.labelColour.value)
    #expect(pixelValue(of: draw, x: 1, y: 6, width: width) == UsageRows.labelColour.value)
    #expect(pixelValue(of: draw, x: 1, y: 11, width: width) == UsageRows.labelColour.value)

    // The label is dim where the value is not.
    #expect(pixelValue(of: draw, x: 1, y: 1, width: width) != UlanziColour.white.value)
    #expect(pixelValue(of: draw, x: 51, y: 3, width: width) == UlanziColour.white.value)
}

// A panel carries three rows and no fourth: rows beyond the third are dropped
// the way the canvas clips, never a crash, never a fifth band.
@Test func rowsBeyondTheThirdAreDropped() {
    let four = UsageRows.drawCommands((1...4).map { _ in
        UsageRows.Row(label: "S", value: "-", colour: ink)
    })
    let three = UsageRows.drawCommands((1...3).map { _ in
        UsageRows.Row(label: "S", value: "-", colour: ink)
    })

    #expect(four == three)
}

// The bitmap ships inside the scene's limits: one command of the thirty-two
// the frame allows, so a usage page always encodes.
@Test func theRowsShipInsideTheFrameLimits() throws {
    let draw = UsageRows.drawCommands([
        UsageRows.Row(label: "DAY", value: "1000%", colour: ink),
        UsageRows.Row(label: "WK", value: "42%", colour: ink),
        UsageRows.Row(label: "SES", value: "-", colour: ink),
    ])
    let scene = UlanziScene(frames: [UlanziFrame(duration: 5, draw: [draw])])

    #expect(try scene.jsonObject().isEmpty == false)
}
