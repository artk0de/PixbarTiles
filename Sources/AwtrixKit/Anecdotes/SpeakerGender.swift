import Foundation

/// What a speaker gave away about themselves. No entry at all is the third
/// answer, and the common one: most lines simply do not say.
enum SpeakerGender: Sendable, Equatable {
    case female
    case male
}

/// Reads which actors reveal their own sex from the way they speak about
/// themselves.
///
/// The only sex marker Russian gives away for free is the past tense: a
/// feminine singular verb ends in `-ла`, or `-лась` when reflexive, against
/// `-л` and `-лся` for a masculine one. The ending alone is not a signal —
/// школа, сила and стрела end the same way. What makes it usable is that we do
/// not care whether the LINE contains a feminine verb, only whether the SPEAKER
/// uses one about HERSELF, so the pronoun `я` has to sit within a couple of
/// tokens of the verb. A noun two clauses away never reaches that window.
///
/// Ported from the prototype's `speaker_genders`, and pinned by the same
/// thirteen cases it was validated against.
enum SpeakerGenders {
    /// How many tokens may separate the pronoun from the verb and still count
    /// as the speaker talking about herself.
    static let selfWindow = 2

    /// `-ла` words that are never a verb. Only the ones that could plausibly
    /// land beside `я` are worth listing; the window does the rest of the work.
    static let notAVerb: Set<String> = [
        "сила", "школа", "скала", "игла", "метла", "пчела", "стрела", "зола",
        "смола", "юла", "мгла", "хвала", "весла", "дела", "тела", "числа",
        "масла", "крыла", "тепла", "жерла", "кобыла", "вобла", "ветла",
    ]

    /// Actors who give their own sex away, by the first line that does it.
    ///
    /// First signal wins, so an actor does not change sex halfway through an
    /// anecdote because a later line quotes somebody else. A line carrying BOTH
    /// signals decides nothing: that shape is reported speech — one person
    /// quoting another of the opposite sex — and neither reading is safe.
    /// Skipping it lets a cleaner line decide, which costs a miss; guessing
    /// costs a man speaking in a woman's voice, and that is the louder failure.
    ///
    /// The narrator is never given a sex: narration is not a character.
    static func detect(in turns: [Turn]) -> [Speaker: SpeakerGender] {
        var verdict: [Speaker: SpeakerGender] = [:]
        for turn in turns {
            guard case .actor = turn.speaker, verdict[turn.speaker] == nil else { continue }
            let words = tokens(in: turn.text)
            let female = speaksOfSelf(words, using: isFemalePast)
            let male = speaksOfSelf(words, using: isMalePast)
            guard female != male else { continue }
            verdict[turn.speaker] = female ? .female : .male
        }
        return verdict
    }

    /// Lowercased runs of Cyrillic or Latin letters, the way the prototype's
    /// `[а-яёa-z]+` reads them.
    ///
    /// Over unicode SCALARS rather than Characters, because that regex matches
    /// code points: a decomposed letter splits a token there, and a
    /// Character-wise scan would keep it whole and disagree.
    static func tokens(in line: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in line.lowercased().unicodeScalars {
            if isWordScalar(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                tokens.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { tokens.append(String(current)) }
        return tokens
    }

    /// `а`–`я`, `ё`, `a`–`z`. Written as scalar values rather than as character
    /// ranges because `ё` sits outside the `а`–`я` block and has to be named.
    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0430...0x044F, 0x0451, 0x61...0x7A: return true
        default: return false
        }
    }

    /// Four scalars minimum, because the shortest feminine past tense worth
    /// reading is that long and a two-letter `-ла` fragment is noise.
    private static func isFemalePast(_ token: String) -> Bool {
        token.unicodeScalars.count >= 4
            && !notAVerb.contains(token)
            && (token.hasSuffix("лась") || token.hasSuffix("ла"))
    }

    /// No exclusion list here on purpose: an `-л` noun beside `я` reads as
    /// masculine, which costs nothing — the pool is where a male or unknown
    /// speaker lands either way.
    private static func isMalePast(_ token: String) -> Bool {
        token.unicodeScalars.count >= 3 && (token.hasSuffix("лся") || token.hasSuffix("л"))
    }

    /// Whether a marked form sits within `selfWindow` tokens of a first-person
    /// pronoun. `меня` is not `я`: only the nominative claims the verb.
    private static func speaksOfSelf(
        _ tokens: [String], using marker: (String) -> Bool
    ) -> Bool {
        let pronouns = tokens.indices.filter { tokens[$0] == "я" }
        guard !pronouns.isEmpty else { return false }
        return tokens.indices.contains { index in
            marker(tokens[index]) && pronouns.contains { abs(index - $0) <= selfWindow }
        }
    }
}
