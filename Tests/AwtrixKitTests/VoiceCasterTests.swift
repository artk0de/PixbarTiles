import Testing
@testable import AwtrixKit

private let extra = Voice(id: "extra")

private func makeCaster() -> VoiceCaster {
    VoiceCaster(narrator: .arthas, pool: [.arthas, .peon, extra])
}

@Test func narrationUsesTheNarratorVoice() {
    let cast = makeCaster().cast([Turn(speaker: .narrator, text: "Звонок от курьера:")])

    #expect(cast == [VoicedTurn(voice: .arthas, text: "Звонок от курьера:")])
}

@Test func firstActorIsArthasAndSecondIsPeon() {
    let cast = makeCaster().cast([
        Turn(speaker: .actor(0), text: "Я подъехал"),
        Turn(speaker: .actor(1), text: "Я вас не вижу"),
    ])

    #expect(cast.map(\.voice.id) == ["arthas", "peon"])
}

@Test func aRepeatedActorKeepsTheSameVoice() {
    let cast = makeCaster().cast([
        Turn(speaker: .actor(0), text: "раз"),
        Turn(speaker: .actor(1), text: "два"),
        Turn(speaker: .actor(0), text: "три"),
    ])

    #expect(cast.map(\.voice.id) == ["arthas", "peon", "arthas"])
}

@Test func aThirdActorDrawsTheNextPoolVoice() {
    let cast = makeCaster().cast([
        Turn(speaker: .actor(0), text: "раз"),
        Turn(speaker: .actor(1), text: "два"),
        Turn(speaker: .actor(2), text: "три"),
    ])

    #expect(cast.map(\.voice.id) == ["arthas", "peon", "extra"])
}

@Test func moreActorsThanVoicesWrapsAroundThePool() {
    let caster = VoiceCaster(narrator: .arthas, pool: [.arthas, .peon])
    let cast = caster.cast((0..<3).map { Turn(speaker: .actor($0), text: "\($0)") })

    #expect(cast.map(\.voice.id) == ["arthas", "peon", "arthas"])
}

@Test func laughterAppendedAsNarrationIsArthas() {
    let cast = makeCaster().cast([
        Turn(speaker: .actor(0), text: "реплика"),
        Turn(speaker: .narrator, text: "АХАХАХАХАХА"),
    ])

    #expect(cast.last?.voice == .arthas)
}

// Task 5 pins this shape: actor alternation runs ACROSS a mid-dialogue
// narration break. A narrator turn between two actor turns must not consume
// a pool slot or otherwise disturb which voice the next actor draws.
@Test func aNarratorTurnBetweenActorsDoesNotDisturbTheVoiceMap() {
    let cast = makeCaster().cast([
        Turn(speaker: .actor(0), text: "А"),
        Turn(speaker: .narrator, text: "он замолчал"),
        Turn(speaker: .actor(1), text: "Б"),
    ])

    #expect(cast.map(\.voice.id) == ["arthas", "arthas", "peon"])
}

// Cross-task contract: Task 10's fixture parses to
// [.narrator, .actor(0), .actor(1)] plus an appended narrator laughter turn,
// and must cast to [arthas, arthas, peon, arthas] with the default pool.
@Test func defaultPoolMatchesTaskTensExpectedSequence() {
    let cast = VoiceCaster().cast([
        Turn(speaker: .narrator, text: "Заходит в лифт:"),
        Turn(speaker: .actor(0), text: "А"),
        Turn(speaker: .actor(1), text: "Б"),
        Turn(speaker: .narrator, text: "АХАХАХАХАХА"),
    ])

    #expect(cast.map(\.voice.id) == ["arthas", "arthas", "peon", "arthas"])
}

// An empty pool would otherwise divide by zero on the first actor turn.
// Falling back to the narrator voice keeps casting total instead of trapping.
@Test func anEmptyPoolFallsBackToTheNarratorVoiceForActors() {
    let caster = VoiceCaster(narrator: .arthas, pool: [])
    let cast = caster.cast([
        Turn(speaker: .actor(0), text: "раз"),
        Turn(speaker: .actor(1), text: "два"),
    ])

    #expect(cast.map(\.voice) == [.arthas, .arthas])
}

// First-APPEARANCE order, not numeric index order: a non-contiguous actor
// index (e.g. actor(3) speaking before actor(1)) must not skip pool slots or
// be keyed by its numeric value.
@Test func nonContiguousActorIndicesCastInAppearanceOrder() {
    let cast = makeCaster().cast([
        Turn(speaker: .actor(3), text: "раз"),
        Turn(speaker: .actor(1), text: "два"),
        Turn(speaker: .actor(3), text: "три"),
    ])

    #expect(cast.map(\.voice.id) == ["arthas", "peon", "arthas"])
}
