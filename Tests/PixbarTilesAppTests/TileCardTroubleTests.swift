import PixbarKit
import Testing
@testable import PixbarTilesApp

// What a clock's tile card says is wrong: the line under the name, the sign
// beside it, and the full text the sign's popover shows. Pure values, like
// `TileRowLine` — the card only draws them.
//
// Two severities: red for a trouble that stops the tile working (a failed
// push, a refused token, no repo, no data), yellow for a partial refusal —
// the tile works, a part is withheld.

private let timedOut = "Error Domain=NSURLErrorDomain Code=-1001 \"The request timed out.\""
private let noRepo = GitHubDiagnosis(
    message: "Repository not found, or the token can't see it (Repository access)", severity: .blocking
)
private let starAuthors = GitHubDiagnosis(
    message: "Star authors are hidden until the token gets Contents: write", severity: .partial
)

@Suite struct TileCardTroubleTests {
    @Test func nothingWrongIsNoTrouble() {
        #expect(TileCardTrouble.of(failure: nil, diagnosis: nil) == nil)
    }

    /// A failed push: the red sign, the cause in words on the line, and the
    /// popover says what happened in a sentence. The transport's NSError
    /// dictionary — domain, code, userInfo, task ids — is not a sentence, and
    /// the popover used to be nothing but that (reported 2026-09-26).
    @Test func aFailureAloneIsTheRedSignWithWhatHappenedInWords() throws {
        let trouble = try #require(TileCardTrouble.of(failure: timedOut, diagnosis: nil))
        #expect(trouble.sign == .blocking)
        #expect(trouble.line == "failing — timed out")
        #expect(trouble.detail == "failing — timed out\n\nNothing answered in time.")
    }

    /// An error with no known dialect keeps what the system said about it —
    /// the description, not the dictionary around it.
    @Test func anUnknownErrorShowsItsDescriptionRatherThanItsDictionary() throws {
        let raw = "Error Domain=NSURLErrorDomain Code=-1202 \"The certificate for this server is invalid.\" "
            + "UserInfo={NSErrorFailingURLKey=https://example.com/, _kCFStreamErrorCodeKey=-9813}"
        let trouble = try #require(TileCardTrouble.of(failure: raw, diagnosis: nil))
        #expect(trouble.line == "failing — The certificate for this server is invalid.")
        #expect(trouble.detail.contains("The certificate for this server is invalid."))
        #expect(!trouble.detail.contains("UserInfo"))
        #expect(!trouble.detail.contains("Error Domain"))
    }

    /// The GitHub diagnosis is said even when the push failed too.
    @Test func aFailureBesideADiagnosisSaysBoth() throws {
        let trouble = try #require(TileCardTrouble.of(failure: timedOut, diagnosis: noRepo))
        #expect(trouble.sign == .blocking)
        #expect(trouble.line == "failing — timed out\n\(noRepo.message)")
        #expect(trouble.detail == "failing — timed out\n\nNothing answered in time.\n\n\(noRepo.message)")
    }

    /// Bad token, no repo, no data: the tile does not work — red.
    @Test func aBlockingDiagnosisIsTheRedSign() throws {
        let trouble = try #require(TileCardTrouble.of(failure: nil, diagnosis: noRepo))
        #expect(trouble.sign == .blocking)
        #expect(trouble.line == noRepo.message)
        #expect(trouble.detail == noRepo.message)
    }

    /// The stargazers refusal is no longer silent: yellow, saying what is
    /// hidden and what unlocks it.
    @Test func aPartialRefusalIsTheYellowSign() throws {
        let trouble = try #require(TileCardTrouble.of(failure: nil, diagnosis: starAuthors))
        #expect(trouble.sign == .partial)
        #expect(trouble.line == starAuthors.message)
        #expect(trouble.detail == starAuthors.message)
    }

    /// Both at once: red wins, and the popover lists both.
    @Test func aFailedPushBesideAPartialRefusalIsRedAndListsBoth() throws {
        let trouble = try #require(TileCardTrouble.of(failure: timedOut, diagnosis: starAuthors))
        #expect(trouble.sign == .blocking)
        #expect(trouble.detail == "failing — timed out\n\nNothing answered in time.\n\n\(starAuthors.message)")
    }

    /// The sign is drawn in the panel's pixels: a triangle with the `!`
    /// knocked out — white on red, dark on the panel's warning yellow.
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
        #expect(PanelGlyph.warningPalette(.blocking) == ["T": 0xFF453A, "G": 0xFFFFFF])
        #expect(PanelGlyph.warningYellow == 0xFFD60A)
        #expect(PanelGlyph.warningPalette(.partial) == ["T": 0xFFD60A, "G": 0x1C1C1E])
    }
}
