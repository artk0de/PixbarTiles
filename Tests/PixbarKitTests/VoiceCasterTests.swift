import Foundation
import Testing
@testable import PixbarKit

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
// and must cast to [arthas, arthas, acolyte, arthas] with the default pool.
// The second actor draws acolyte rather than peon because the default pool is
// the prototype's four — arthas, acolyte, batrak, peon — not the two it was
// ported as.
@Test func defaultPoolMatchesTaskTensExpectedSequence() {
    let cast = VoiceCaster().cast([
        Turn(speaker: .narrator, text: "Заходит в лифт:"),
        Turn(speaker: .actor(0), text: "А"),
        Turn(speaker: .actor(1), text: "Б"),
        Turn(speaker: .narrator, text: "АХАХАХАХАХА"),
    ])

    #expect(cast.map(\.voice.id) == ["arthas", "arthas", "acolyte", "arthas"])
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

// MARK: - The prototype's casting

// Five voice packs are installed. The prototype narrates with arthas, reserves
// crystal for speakers it detects as female, and pools the remaining three plus
// the narrator. Everything below pins that arrangement; the expected sequences
// were produced by running the prototype's own `cast` over the same turns
// rather than reasoned out here.

@Test func everyInstalledVoiceIsReachable() {
    let cast = VoiceCaster().cast([
        Turn(speaker: .narrator, text: "Заходят в бар:"),
        Turn(speaker: .actor(0), text: "раз"),
        Turn(speaker: .actor(1), text: "два"),
        Turn(speaker: .actor(2), text: "три"),
        Turn(speaker: .actor(3), text: "четыре"),
        Turn(speaker: .actor(4), text: "Я закрыла глаза"),
    ])

    // The roster size is asserted too. Without it, dropping a voice pack from
    // `installed` would make the set comparison pass while a voice that is on
    // disk stops being cast — the failure this test exists to catch.
    #expect(Voice.installed.count == 5)
    #expect(Set(cast.map(\.voice)) == Set(Voice.installed))
    #expect(cast.map(\.voice.id)
        == ["arthas", "arthas", "acolyte", "batrak", "peon", "crystal"])
}

@Test func aSpeakerWhoRevealsHerselfFemaleGetsTheReservedVoice() {
    let cast = VoiceCaster().cast([
        Turn(speaker: .actor(0), text: "Ты спишь?"),
        Turn(speaker: .actor(1), text: "Неее, я просто закрыла глаза и слушаю дождь..."),
    ])

    #expect(cast.map(\.voice.id) == ["arthas", "crystal"])
}

@Test func theReservedFemaleVoiceIsNeverDrawnForAMaleOrUnknownSpeaker() {
    let lines = ["Я подъехал", "раз", "Я умылся", "два", "Я ушёл", "три"]
    let cast = VoiceCaster().cast(
        lines.enumerated().map { Turn(speaker: .actor($0.offset), text: $0.element) }
    )

    // More speakers than the pool holds, on purpose: a run shorter than the
    // pool never wraps, so the reservation is never put under any pressure and
    // the assertion below would hold with crystal sitting in the pool untouched.
    #expect(lines.count > VoiceCaster.defaultPool.count)
    #expect(!cast.map(\.voice).contains(VoiceCaster.reservedFemale))
    #expect(cast.map(\.voice.id)
        == ["arthas", "acolyte", "batrak", "peon", "arthas", "acolyte"])
}

@Test func aThirdSpeakerDoesNotReuseTheNarratorsVoiceWhileAnotherIsFree() {
    let cast = VoiceCaster().cast([
        Turn(speaker: .narrator, text: "Заходят:"),
        Turn(speaker: .actor(0), text: "раз"),
        Turn(speaker: .actor(1), text: "два"),
        Turn(speaker: .actor(2), text: "три"),
    ])

    // Actor 0 sharing the narrator's voice is the prototype's own casting — the
    // narrator voice opens the pool — and is left alone. What was broken is the
    // THIRD speaker wrapping back onto it with two voices still unused.
    #expect(cast[3].voice != VoiceCaster.defaultNarrator)
    #expect(Set(cast.dropFirst().map(\.voice)).count == 3)
    #expect(cast.map(\.voice.id) == ["arthas", "arthas", "acolyte", "batrak"])
}

@Test func castingIsStableAcrossOneAnecdote() {
    let cast = VoiceCaster().cast([
        Turn(speaker: .narrator, text: "Заходят:"),
        Turn(speaker: .actor(0), text: "Я закрыла дверь"),
        Turn(speaker: .actor(1), text: "Я подъехал"),
        Turn(speaker: .actor(2), text: "А я только пришёл"),
        Turn(speaker: .narrator, text: "он замолчал"),
        Turn(speaker: .actor(0), text: "И что?"),
        Turn(speaker: .actor(1), text: "Ничего"),
        Turn(speaker: .actor(2), text: "Совсем ничего"),
        Turn(speaker: .narrator, text: "АХАХАХА"),
    ])

    #expect(cast.map(\.voice.id) == [
        "arthas", "crystal", "arthas", "acolyte",
        "arthas", "crystal", "arthas", "acolyte", "arthas",
    ])
}

@Test func aFemaleSpeakerDoesNotConsumeAPoolSlot() {
    let cast = VoiceCaster().cast([
        Turn(speaker: .actor(0), text: "Я закрыла дверь"),
        Turn(speaker: .actor(1), text: "раз"),
        Turn(speaker: .actor(2), text: "два"),
    ])

    // The reserved voice is drawn from outside the pool, so the two speakers
    // after her still open the pool at its start rather than one voice in.
    #expect(cast.map(\.voice.id) == ["crystal", "arthas", "acolyte"])
}

@Test func aFifthSpeakerWrapsBackToTheStartOfTheDefaultPool() {
    let cast = VoiceCaster().cast(
        (0..<5).map { Turn(speaker: .actor($0), text: "\($0)") }
    )

    #expect(cast.count > VoiceCaster.defaultPool.count)
    #expect(cast.map(\.voice.id) == ["arthas", "acolyte", "batrak", "peon", "arthas"])
}

@Test func theReservedVoiceIsStrippedFromAnyPoolItIsHandedIn() {
    let caster = VoiceCaster(narrator: .arthas, pool: [.arthas, .crystal, .peon])
    let cast = caster.cast((0..<3).map { Turn(speaker: .actor($0), text: "\($0)") })

    #expect(cast.map(\.voice.id) == ["arthas", "peon", "arthas"])
}

// The strip above sits in front of the empty-pool fallback, so a pool holding
// nothing else reaches that fallback rather than dividing by zero.
@Test func aPoolOfNothingButTheReservedVoiceFallsBackToTheNarrator() {
    let caster = VoiceCaster(narrator: .arthas, pool: [.crystal])
    let cast = caster.cast([Turn(speaker: .actor(0), text: "раз")])

    #expect(cast.map(\.voice) == [.arthas])
}

// The anecdote the female rule was built against, end to end from raw text:
// the woman answers in the reserved voice, the man does not.
@Test func theHelicopterAnecdoteCastsTheWomanInTheReservedVoice() {
    let turns = DialogueParser.parse("""
    — Ты спишь?
    — Неее, я просто закрыла глаза и слушаю дождь...
    — Но дождя нет!!!
    — Я его слушаю по памяти.
    """)

    #expect(VoiceCaster().cast(turns).map(\.voice.id)
        == ["arthas", "crystal", "arthas", "crystal"])
}

// MARK: - A voice per connector

// Giving each connector its own narrator is what makes the weather and a broken
// build sound like two different characters. Everything below pins the four
// rules that keeps it from disturbing the casting Task 27 restored.

/// A connector that names the voice its narration is spoken in.
private struct NarratedConnector: Connector {
    let id = "narrated"
    let displayName = "Narrated"
    let defaultInterval: TimeInterval = 60
    let narrator: Voice

    func read() async throws -> AwtrixDelivery { AwtrixDelivery(text: "") }
}

/// A connector that names none, so what reaches the caster is the protocol's
/// own answer rather than one written down here.
private struct UnnarratedConnector: Connector {
    let id = "unnarrated"
    let displayName = "Unnarrated"
    let defaultInterval: TimeInterval = 60

    func read() async throws -> AwtrixDelivery { AwtrixDelivery(text: "") }
}

/// Narration at both ends and three speakers between them — the shape every
/// prepared anecdote has.
private let anAnecdote = [
    Turn(speaker: .narrator, text: "Заходят в бар:"),
    Turn(speaker: .actor(0), text: "раз"),
    Turn(speaker: .actor(1), text: "два"),
    Turn(speaker: .actor(2), text: "три"),
    Turn(speaker: .narrator, text: "АХАХАХА"),
]

/// The voices of the actor turns only, in order.
private func actorVoices(_ cast: [VoicedTurn]) -> [String] {
    zip(anAnecdote, cast).filter { $0.0.speaker != .narrator }.map { $0.1.voice.id }
}

@Test func aConnectorsNarratorVoiceIsUsedForItsNarratorLines() {
    let cast = VoiceCaster(narrating: NarratedConnector(narrator: .batrak)).cast(anAnecdote)

    // Asserted to differ from the default first. A connector whose narrator
    // happened to BE the default would satisfy the two expectations below with
    // the connector ignored altogether — which is this file's own failure mode.
    #expect(Voice.batrak != VoiceCaster.defaultNarrator)
    #expect(cast.first?.voice == .batrak)
    #expect(cast.last?.voice == .batrak)
}

@Test func perSpeakerCastingInsideTheTextIsUnchanged() {
    let byDefault = VoiceCaster().cast(anAnecdote)
    let byPeon = VoiceCaster(narrating: NarratedConnector(narrator: .peon)).cast(anAnecdote)

    // The narration moved, or the comparison below holds for the uninteresting
    // reason that nothing about the caster changed at all.
    #expect(byDefault.first?.voice == .arthas)
    #expect(byPeon.first?.voice == .peon)
    #expect(actorVoices(byPeon) == actorVoices(byDefault))
    #expect(actorVoices(byPeon) == ["arthas", "acolyte", "batrak"])
}

@Test func aConnectorNarratorDoesNotConsumeTheReservedFemaleVoice() {
    let turns = [
        Turn(speaker: .narrator, text: "Заходят:"),
        Turn(speaker: .actor(0), text: "Я закрыла дверь"),
        Turn(speaker: .actor(1), text: "раз"),
    ]

    let cast = VoiceCaster(narrating: NarratedConnector(narrator: .crystal)).cast(turns)

    #expect(cast[0].voice != VoiceCaster.reservedFemale)
    #expect(cast[0].voice == VoiceCaster.defaultNarrator)
    // And she still gets it. The reservation is the whole point of refusing it
    // to the narrator, so a fallback that also lost her the voice would be no
    // better than handing it over.
    #expect(cast[1].voice == VoiceCaster.reservedFemale)
    #expect(cast[2].voice != VoiceCaster.reservedFemale)
}

@Test func anUnknownNarratorFallsBackRatherThanFailing() {
    let deleted = Voice(id: "deleted-from-the-pack-directory")

    let cast = VoiceCaster(narrating: NarratedConnector(narrator: deleted)).cast(anAnecdote)

    #expect(Voice.installed.contains(deleted) == false)
    #expect(cast.first?.voice == VoiceCaster.defaultNarrator)
    // Nothing anywhere in the anecdote names a pack that is not on disk: the
    // sidecar resolves a voice to `voices/<name>.wav` and would fail the whole
    // batch on one that is missing.
    #expect(cast.allSatisfy { Voice.installed.contains($0.voice) })
}

// The two fallbacks compose, and the order they compose in is the whole of it:
// the empty pool falls back to the narrator, so a narrator that was refused
// above would come straight back as the voice every actor draws.
@Test func aRefusedNarratorIsNotWhatAnEmptyPoolFallsBackTo() {
    let caster = VoiceCaster(narrator: Voice(id: "deleted-from-the-pack-directory"), pool: [])

    let cast = caster.cast([Turn(speaker: .actor(0), text: "раз")])

    #expect(cast.map(\.voice) == [VoiceCaster.defaultNarrator])
}

@Test func connectorsWithoutANarratorSoundExactlyAsBefore() {
    let cast = VoiceCaster(narrating: UnnarratedConnector()).cast(anAnecdote)

    #expect(cast.first?.voice.id == "arthas")
    #expect(cast.map(\.voice.id) == VoiceCaster().cast(anAnecdote).map(\.voice.id))
}
