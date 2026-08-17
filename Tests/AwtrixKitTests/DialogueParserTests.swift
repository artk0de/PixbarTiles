import Testing
@testable import AwtrixKit

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
