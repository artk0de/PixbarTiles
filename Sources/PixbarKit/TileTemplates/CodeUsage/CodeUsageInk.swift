import Foundation

/// What every coding-subscription face is drawn in, and how a reset is spelled.
///
/// Here rather than on a face, because the two faces are two ARRANGEMENTS of one
/// reading and not two readings. A colour that meant one thing on the two-row
/// page and another around the rim would be the reader having to learn the
/// panel twice; the ramp already says the same thing on the matrix as on the
/// panel, and this is what keeps that true as faces are added.
public extension CodeUsage {
    /// Labels — a row's name, a window's name. Grey, so the figure beside it is
    /// what a glance lands on.
    static let labelColour = UlanziColour(value: 0x60_60_60)

    /// The unlit part of a gauge, and the ink of a figure nobody knows. The same
    /// grey as the AWTRIX bar's track, and for the same reason: dark enough to
    /// read as empty at brightness two, light enough that the gauge's full
    /// extent is still visible — an unlit track makes a half-full bar look like
    /// a short one.
    static let trackColour = UlanziColour(value: 0x30_30_30)

    /// The SPENT part of a gauge while the window is steady.
    ///
    /// Bright white, so what a glance lands on is how much is gone against the
    /// grey of what is left. White stands where a vendor's brand colour used to:
    /// the figure beside the gauge already says which account this is, so the
    /// gauge is free to spend its colour on how much is left.
    static let steadyProgressColour = "#FFFFFF"

    /// What the spent part is drawn in at `percent`, and `dim` on the low half
    /// of the spent pulse.
    ///
    /// White while the window is steady, and `Band`'s ramp past three quarters —
    /// the same yellow through red the AWTRIX page uses, so a colour means the
    /// same thing wherever it shows. White alone left a gauge at a third and one
    /// about to run out the same colour, differing only in LENGTH, which is the
    /// one reading a 52-pixel panel is worst at.
    static func fillColour(at percent: Int, dim: Bool = false) -> UlanziColour {
        let band = Band(utilization: percent)
        if dim, let pulse = band.pulseColour { return UlanziColour(hex: pulse) }
        return UlanziColour(hex: band.fillColour(brand: steadyProgressColour))
    }

    /// A figure's ink: the vendor's MARK while the window is steady, the gauge's
    /// own colour once it is not, and the track's grey for a window nobody knows.
    ///
    /// While nothing is near a limit the figure is identity — WHICH account this
    /// is — and the gauge alone carries how much is left. Past three quarters
    /// that split stops paying: the figure and the gauge are one statement, and
    /// a warm figure over a warm gauge is what the eye lands on first. (z.ai's
    /// mark is near-white where its brand is blue, which is why this reads the
    /// mark and never the brand.)
    static func figureColour(_ vendor: Vendor, at percent: Int?, dim: Bool = false)
        -> UlanziColour
    {
        guard let percent else { return trackColour }
        guard Band(utilization: percent) != .steady else { return vendor.logoColour }
        return fillColour(at: percent, dim: dim)
    }

    /// A window's reading as the panel writes it. Past a hundred is drawn as a
    /// hundred — the gauge has nowhere to put the rest — and a window with no
    /// reading says so rather than showing a zero it does not know.
    static func percentText(_ percent: Int?) -> String {
        guard let percent else { return "--" }
        return "\(min(percent, 100))%"
    }
}
