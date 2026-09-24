import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// What a clock's tile card says is wrong: the line under the name, the sign
// beside it, and the full text the sign's popover shows. Pure values, like
// `TileRowLine` — the card only draws them.

private let timedOut = "Error Domain=NSURLErrorDomain Code=-1001 \"The request timed out.\""
private let noRepo = GitHubDiagnosis(
    message: "Repository not found, or the token can't see it (Repository access)", isQuiet: false
)
private let quiet = GitHubDiagnosis(
    message: "Who starred needs Contents: write — stars are counted instead", isQuiet: true
)

@Suite struct TileCardTroubleTests {
    @Test func nothingWrongIsNoTrouble() {
        #expect(TileCardTrouble.of(failure: nil, diagnosis: nil) == nil)
    }

    /// A failed push: the red sign, the cause in words on the line, and the
    /// raw error kept for the popover.
    @Test func aFailureAloneIsTheRedSignWithTheRawErrorBehindIt() throws {
        let trouble = try #require(TileCardTrouble.of(failure: timedOut, diagnosis: nil))
        #expect(trouble.sign == .failing)
        #expect(trouble.line == "failing — timed out")
        #expect(trouble.detail == "failing — timed out\n\n\(timedOut)")
    }

    /// The GitHub diagnosis is said even when the push failed too: the card
    /// said only `failing — timed out` while the read had found the reason
    /// the tile shows `no repo`.
    @Test func aFailureBesideADiagnosisSaysBoth() throws {
        let trouble = try #require(TileCardTrouble.of(failure: timedOut, diagnosis: noRepo))
        #expect(trouble.sign == .failing)
        #expect(trouble.line == "failing — timed out\n\(noRepo.message)")
        #expect(trouble.detail == "failing — timed out\n\n\(timedOut)\n\n\(noRepo.message)")
    }

    @Test func aDiagnosisAloneIsTheOrangeSign() throws {
        let trouble = try #require(TileCardTrouble.of(failure: nil, diagnosis: noRepo))
        #expect(trouble.sign == .diagnosis)
        #expect(trouble.line == noRepo.message)
        #expect(trouble.detail == noRepo.message)
    }

    /// The quiet one is said on the line and wears no sign.
    @Test func aQuietDiagnosisIsSaidWithoutASign() throws {
        let trouble = try #require(TileCardTrouble.of(failure: nil, diagnosis: quiet))
        #expect(trouble.sign == nil)
        #expect(trouble.line == quiet.message)
    }

    /// The sign is drawn in the panel's pixels: a triangle with the `!`
    /// knocked out in white, tinted red for a failure and orange for a
    /// diagnosis.
    @Test func theSignIsAPixelTriangle() {
        #expect(PanelGlyph.warning == [
            "....T....",
            "...TTT...",
            "...TGT...",
            "..TTGTT..",
            "..TTGTT..",
            ".TTTTTTT.",
            ".TTTGTTT.",
            "TTTTTTTTT",
        ])
        #expect(PanelGlyph.warningPalette(.failing) == ["T": 0xFF453A, "G": 0xFFFFFF])
        #expect(PanelGlyph.warningPalette(.diagnosis) == ["T": 0xFF9F0A, "G": 0xFFFFFF])
    }
}
