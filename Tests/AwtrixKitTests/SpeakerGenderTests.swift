import Testing
@testable import AwtrixKit

/// One case from `prototype/test_gender.py`, carried over unchanged.
///
/// The prototype's acceptance set is the port's acceptance set: same inputs,
/// same verdicts, or the app does not sound like the demo that was signed off.
/// A case that fails here is the implementation being wrong, not the case.
struct GenderCase: Sendable, CustomTestStringConvertible {
    let name: String
    /// As the prototype's harness writes them: several lines become a dashed
    /// dialogue, a single line stays bare narration.
    let lines: [String]
    let expected: [Speaker: SpeakerGender]

    var testDescription: String { name }

    var text: String {
        guard lines.count > 1 else { return lines[0] }
        return lines.map { "— \($0)" }.joined(separator: "\n")
    }

    static let all: [GenderCase] = [
        // --- the signal we are actually after -------------------------------
        GenderCase(
            name: "a woman speaking about herself",
            lines: ["Ты спишь?", "Неее, я просто закрыла глаза и слушаю дождь..."],
            expected: [.actor(1): .female]
        ),
        GenderCase(
            name: "reflexive -лась counts",
            lines: ["Ну что?", "Я улыбнулась и ушла."],
            expected: [.actor(1): .female]
        ),
        GenderCase(
            name: "the verb may come before the pronoun",
            lines: ["Где была?", "Опоздала я на работу."],
            expected: [.actor(1): .female]
        ),
        // --- men, so the female voice is not handed out by default ----------
        GenderCase(
            name: "a man speaking about himself",
            lines: ["Здравствуйте! Я подъехал…", "Иду."],
            expected: [.actor(0): .male]
        ),
        GenderCase(
            name: "masculine reflexive",
            lines: ["Я умылся и побрился.", "Молодец."],
            expected: [.actor(0): .male]
        ),
        // --- the traps that make a bare -ла suffix unusable -----------------
        GenderCase(
            name: "a noun ending in -ла is not a verb",
            lines: ["Я сила!", "Ну-ну."],
            expected: [:]
        ),
        GenderCase(
            name: "a feminine verb about somebody else does not out the speaker",
            lines: ["Она закрыла дверь, а я ушёл.", "И что?"],
            expected: [.actor(0): .male]
        ),
        GenderCase(
            name: "distance kills it: the verb is four tokens from the pronoun",
            lines: ["Дверь закрыла соседка сверху, я слышал.", "Ага."],
            expected: [.actor(0): .male]
        ),
        GenderCase(
            name: "no first-person pronoun at all, so no verdict",
            lines: ["Пришла, увидела, победила.", "Классика."],
            expected: [:]
        ),
        GenderCase(
            name: "меня is not я",
            lines: ["У меня сила воли железная.", "Проверим."],
            expected: [:]
        ),
        // --- stability ------------------------------------------------------
        GenderCase(
            name: "a line carrying both signals decides nothing — it is reported speech",
            lines: ["Я пришёл домой. Потом я устала от всего этого.", "Бывает."],
            expected: [:]
        ),
        GenderCase(
            name: "first signal wins, so a speaker does not change sex mid-anecdote",
            lines: ["Я устал.", "Ну?", "Вчера я купила машину."],
            expected: [.actor(0): .male]
        ),
        GenderCase(
            name: "the narrator is never assigned a sex",
            lines: ["Заходит женщина в бар и говорит, что она устала."],
            expected: [:]
        ),
    ]
}

@Test(arguments: GenderCase.all)
func theFemaleRuleAgreesWithThePrototypeOnEveryAcceptanceCase(_ testCase: GenderCase) {
    let verdict = SpeakerGenders.detect(in: DialogueParser.parse(testCase.text))

    #expect(verdict == testCase.expected, "\(testCase.name)\ninput: \(testCase.text)")
}

/// The set is what the rule was validated against, so its size is part of the
/// contract. Losing a case would quietly narrow the acceptance without a single
/// assertion going red.
@Test func theAcceptanceSetStillHoldsThePrototypesThirteenCases() {
    #expect(GenderCase.all.count == 13)
}

/// The thirteen cover the narrator with a line that has no first-person pronoun
/// in it, so that case decides nothing either way: it passes whether narration
/// is skipped or not. This one would read female if narration were eligible, so
/// it is the assertion that actually holds the rule up. The prototype gives the
/// same verdict — `speaker_genders` skips the narrator before it tokenizes.
@Test func narrationIsNeverGivenASexEvenWhenItSpeaksInTheFirstPerson() {
    let turns = DialogueParser.parse("Я закрыла дверь и вышла.")

    #expect(turns.map(\.speaker) == [.narrator])
    #expect(SpeakerGenders.detect(in: turns).isEmpty)
}

/// The floor under a feminine form is four scalars, so `шла` — a real feminine
/// past tense — is not read as one, while `пришла` is. That blind spot is the
/// prototype's: it draws the line in the same place, and the price of moving it
/// is `ла` fragments and short nouns reading as verbs. Pinned so that lowering
/// the floor is a decision somebody makes rather than something that slips.
@Test func aFeminineFormShorterThanFourScalarsIsNotReadAsOne() {
    let short = SpeakerGenders.detect(in: DialogueParser.parse("— Я шла домой.\n— Ага."))
    let long = SpeakerGenders.detect(in: DialogueParser.parse("— Я пришла домой.\n— Ага."))

    #expect(short.isEmpty)
    #expect(long == [.actor(0): .female])
}
