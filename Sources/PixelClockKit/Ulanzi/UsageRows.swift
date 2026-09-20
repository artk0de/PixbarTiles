// Sources/PixelClockKit/Ulanzi/UsageRows.swift
import Foundation

/// Three label-and-value rows on the 52×16 panel — the layout every usage
/// tile draws.
///
/// A shared face component, not any one connector's: Claude's page feeds it
/// its three windows (daily, weekly, session), and the coding-plan usage tile
/// that follows feeds it its own. The caller owns the words and the colours;
/// this owns the layout — the label pinned to the left edge in the layout's
/// own dim grey, the value right-aligned in the row's colour, five pixel rows
/// per band starting one row down.
public struct UsageRows: Sendable, Equatable {
    /// One band: a short label, a figure as text, and the colour the figure
    /// is inked in.
    public struct Row: Sendable, Equatable {
        public let label: String
        public let value: String
        public let colour: UlanziColour

        public init(label: String, value: String, colour: UlanziColour) {
            self.label = label
            self.value = value
            self.colour = colour
        }
    }

    /// What labels are drawn in: dim enough that the values carry the page,
    /// light enough to read at brightness two — the same judgement the bar's
    /// track colour makes, one step lighter.
    public static let labelColour = UlanziColour(value: 0x60_60_60)

    /// The whole page as the one full-screen bitmap command every face ships
    /// (D2) — one command of the thirty-two a frame allows, whatever the rows
    /// carry. Rows beyond the third are dropped the way the canvas clips: the
    /// panel has three bands and not one more.
    public static func drawCommands(_ rows: [Row]) -> UlanziDraw {
        var canvas = PixelCanvas()
        for (index, row) in rows.prefix(Self.bands).enumerated() {
            let top = 1 + index * Self.bandHeight
            canvas.drawText(
                row.label,
                at: PixelPoint(x: 0, y: top),
                ink: Pixel(colour: labelColour)
            )
            canvas.drawText(
                row.value,
                at: PixelPoint(x: PixelCanvas.width - PixelFont.width(of: row.value, scale: 1), y: top),
                ink: Pixel(colour: row.colour)
            )
        }
        return canvas.drawCommands()
    }

    private static let bands = 3
    private static let bandHeight = 5
}
