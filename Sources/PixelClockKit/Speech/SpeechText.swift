import Foundation

/// Normalisation every line passes through before synthesis.
///
/// Each rule below fixes a defect that was heard, reproduced and confirmed
/// against real XTTS output — none of them is cosmetic. The clock keeps the
/// original text; only the synthesizer sees the normalised version.
///
/// Stress marking is deliberately absent, and adding it is not an improvement:
/// `+` and the combining acute are not in the XTTS BPE vocabulary, both encode
/// to `[UNK]` and corrupt the characters next to them, and a capital is
/// lowercased before tokenization. All four conventions were tested by ear and
/// all four fail. Wrong stress on a homograph is accepted as a cosmetic flaw.
public enum SpeechText {
    /// Characters XTTS vocalises instead of reading as punctuation. `точка»`
    /// came out as "точкала" — the closing quote became a syllable of the word.
    private static let quotes: Set<Character> = [
        "«", "»", "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}",
        "\"", "'", "\u{2018}", "\u{2019}", "`", "\u{00B4}",
    ]

    // Computed rather than stored: `Regex` is not `Sendable`, so holding one in
    // a static would be a shared-mutable-state error under strict concurrency.
    // Building it per call is immaterial next to synthesis.

    /// A dash between spaces, which pauses long enough to sound like a fault:
    /// "вкусно …… и точка". Only the em and en dashes — a hyphen inside a word
    /// ("работа-работа") is part of it, and one between digits is arithmetic.
    private static var spacedDash: Regex<Substring> { #/\s+[—–]\s+/# }
    private static var whitespaceRun: Regex<Substring> { #/\s+/# }
    private static var spaceBeforePunctuation: Regex<Substring> { #/\s+(?=[,.!?;:…])/# }

    public static func prepare(_ line: String) -> String {
        // A quote becomes a space rather than vanishing: deleting the character
        // outright would fuse the two words it separates.
        var text = String(line.map { quotes.contains($0) ? " " : $0 })
        text = text.replacing(spacedDash, with: " ")
        text = text.replacing(whitespaceRun, with: " ")
        text = text.replacing(spaceBeforePunctuation, with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // A trailing full stop provokes the decoder into appending an audible
        // fragment after the sentence — a spurious "по", separated from the real
        // speech by 0.2 s of true digital silence at −94 dB. Raising the
        // repetition penalty did not fix that; deleting the full stop did.
        while text.hasSuffix(".") {
            text.removeLast()
        }

        // A trailing `?` or `!` is KEPT: it carries the intonation, measured as
        // an 18.5 Hz relative pitch rise on the same sentence without it. The
        // space after it is not optional — without it the final consonant is
        // swallowed and "Анекдот!" loses its Т. Checked after the full stops
        // are gone, so "Правда?.." keeps its intonation too.
        if let last = text.last, last == "?" || last == "!" {
            return text + " "
        }
        return text
    }
}
