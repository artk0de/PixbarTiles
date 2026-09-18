import Foundation
import Testing
@testable import PixelClockKit

@Test func plainTextIsOneNarratorTurn() {
    let turns = DialogueParser.parse("Посмотрел \"Теремок\". Что вам сказать? Сказка короче...")

    #expect(turns == [Turn(speaker: .narrator, text: "Посмотрел \"Теремок\". Что вам сказать? Сказка короче...")])
}

@Test func twoDashedLinesAlternateBetweenTwoActors() {
    let turns = DialogueParser.parse("""
    - Ты у меня зонт забыла!
    - Это не зонт, это трость!
    """)

    #expect(turns == [
        Turn(speaker: .actor(0), text: "Ты у меня зонт забыла!"),
        Turn(speaker: .actor(1), text: "Это не зонт, это трость!"),
    ])
}

@Test func aDashInsideALineDoesNotStartANewTurn() {
    // Real sample: the second dash is punctuation, not a speaker marker.
    let turns = DialogueParser.parse("""
    - Вот я - убеждённый жаворонок. И после десяти вечера я не работаю!
    - Получается, будильник таки звонит...
    """)

    #expect(turns.count == 2)
    #expect(turns[0].text == "Вот я - убеждённый жаворонок. И после десяти вечера я не работаю!")
    #expect(turns[1].speaker == .actor(1))
}

@Test func leadingNarrationKeepsItsOwnTurnBeforeTheDialogue() {
    let turns = DialogueParser.parse("""
    Звонок от курьера:
    - Здравствуйте! Я подъехал...
    - Здравствуйте! Но я вас не вижу...
    - Такое бывает. Я у соседнего подъезда!
    """)

    #expect(turns.count == 4)
    #expect(turns[0] == Turn(speaker: .narrator, text: "Звонок от курьера:"))
    #expect(turns[1].speaker == .actor(0))
    #expect(turns[2].speaker == .actor(1))
    #expect(turns[3].speaker == .actor(0))
}

@Test func consecutiveDashedLinesAlternateBetweenTwoActors() {
    // Plain dashed lines carry no speaker identity, so alternation between two
    // is the honest reading. A third actor would need naming the parser cannot see.
    let turns = DialogueParser.parse("""
    - раз
    - два
    - три
    - четыре
    """)

    #expect(turns.map(\.speaker) == [.actor(0), .actor(1), .actor(0), .actor(1)])
}

@Test func emDashAndHyphenAreBothSpeakerMarkers() {
    let turns = DialogueParser.parse("""
    — Первый.
    - Второй.
    """)

    #expect(turns.map(\.speaker) == [.actor(0), .actor(1)])
    #expect(turns[0].text == "Первый.")
}

@Test func blankLinesAreDropped() {
    let turns = DialogueParser.parse("""
    Первая строка.

    Вторая строка.
    """)

    #expect(turns.count == 2)
}

@Test func emptyInputYieldsNoTurns() {
    #expect(DialogueParser.parse("   \n\n  ").isEmpty)
}

@Test func markerLinesWithNoSpeechAreDroppedAndDoNotConsumeASpeakerSlot() {
    // A marker with nothing after it is a separator, not speech. Emitting it
    // would voice an empty string, and consuming a speaker slot would flip who
    // talks next. Each input skips exactly one line, so a consumed slot would
    // show up as "Второй." landing back on actor 0.
    let bareDash = DialogueParser.parse("- Первый.\n-\n- Второй.")
    let dashThenSpaces = DialogueParser.parse("- Первый.\n-   \n- Второй.")

    #expect(bareDash == [
        Turn(speaker: .actor(0), text: "Первый."),
        Turn(speaker: .actor(1), text: "Второй."),
    ])
    #expect(dashThenSpaces == bareDash)
}

@Test func carriageReturnLineEndingsSplitWithoutLeavingEmptyTurns() {
    // The feed arrives over HTTP, so CRLF is a live possibility.
    let turns = DialogueParser.parse("Звонок от курьера:\r\n- Здравствуйте!\r\n- Не вижу вас...")

    #expect(turns == [
        Turn(speaker: .narrator, text: "Звонок от курьера:"),
        Turn(speaker: .actor(0), text: "Здравствуйте!"),
        Turn(speaker: .actor(1), text: "Не вижу вас..."),
    ])
}

@Test func nonBreakingSpacesAroundAMarkerStillReadAsASpeakerTurn() {
    // Scraped HTML decodes &nbsp; to U+00A0; a marker hidden behind one must
    // still register, and an all-NBSP line must not survive as a turn.
    let turns = DialogueParser.parse("\u{00A0}- Первый.\u{00A0}\n\u{00A0}\n\u{00A0}- Второй.")

    #expect(turns == [
        Turn(speaker: .actor(0), text: "Первый."),
        Turn(speaker: .actor(1), text: "Второй."),
    ])
}

// MARK: - Parity with the prototype

/// A corpus of real anecdotes together with the splits the prototype produced
/// for them.
///
/// The dialogue parser is the one piece of the port that had never been
/// compared against the prototype it was written from, and a disagreement here
/// is inaudible as a parsing bug: the turn count decides how many lead-ins the
/// pacing lays down, so a joke split into a different number of turns has its
/// pauses in the wrong places while every pause constant still matches.
///
/// Regenerate with `Scripts/make_parser_parity_corpus.py`, which fetches the
/// three live feeds and records what `prototype/demo_anecdote.py parse_turns`
/// makes of each one.
private struct ParityCorpus: Decodable {
    struct RecordedTurn: Decodable, Equatable {
        let speaker: String
        let text: String
    }

    struct RecordedAnecdote: Decodable {
        let id: String
        let text: String
        let turns: [RecordedTurn]
    }

    let capturedOn: String
    let source: String
    let splitBy: String
    let anecdotes: [RecordedAnecdote]
}

/// The prototype names its speakers `narrator` / `actor0` / `actor1`, so the
/// comparison is against those strings rather than against a Swift shape the
/// fixture could not have recorded.
private func recordedName(of speaker: Speaker) -> String {
    switch speaker {
    case .narrator: return "narrator"
    case let .actor(index): return "actor\(index)"
    }
}

private func loadParityCorpus() throws -> ParityCorpus {
    let url = try #require(Bundle.module.url(
        forResource: "parser_parity_corpus", withExtension: "json"
    ))
    return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
}

@Test func theSwiftParserSplitsARealCorpusExactlyAsTheProtoypeDoes() throws {
    let corpus = try loadParityCorpus()
    let dialogues = corpus.anecdotes.filter { anecdote in
        anecdote.turns.contains { $0.speaker != "narrator" }
    }

    // Asserted before the comparison, because an empty or all-narration corpus
    // agrees with anything: this test can only fail if the fixture is big
    // enough and mixed enough to disagree.
    #expect(corpus.anecdotes.count >= 50)
    #expect(dialogues.count >= 10)
    #expect(corpus.anecdotes.reduce(0) { $0 + $1.turns.count } >= 100)

    var divergences: [String] = []
    for anecdote in corpus.anecdotes {
        let swiftSplit = DialogueParser.parse(anecdote.text).map {
            ParityCorpus.RecordedTurn(speaker: recordedName(of: $0.speaker), text: $0.text)
        }
        guard swiftSplit != anecdote.turns else { continue }
        divergences.append("""
        \(anecdote.id)
          input:     \(anecdote.text.debugDescription)
          prototype: \(anecdote.turns.map { "\($0.speaker)|\($0.text)" })
          swift:     \(swiftSplit.map { "\($0.speaker)|\($0.text)" })
        """)
    }

    #expect(
        divergences.isEmpty,
        """
        \(divergences.count) of \(corpus.anecdotes.count) anecdotes \
        (captured \(corpus.capturedOn), split by \(corpus.splitBy)) \
        split differently:
        \(divergences.joined(separator: "\n\n"))
        """
    )
}
