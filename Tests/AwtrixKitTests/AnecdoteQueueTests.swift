import Foundation
import Testing
@testable import AwtrixKit

private func temporaryStore() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("queue-\(UUID().uuidString).json")
}

private func prepared(_ id: String) -> PreparedAnecdote {
    PreparedAnecdote(
        id: id, text: "joke \(id)",
        clips: [SpokenClip(url: URL(fileURLWithPath: "/tmp/\(id).wav"), leadIn: 0)],
        laughter: "АХАХАХА"
    )
}

@Test func anEmptyQueueHasNothingReady() async {
    let queue = AnecdoteQueue(storeURL: temporaryStore())

    #expect(await queue.ready() == 0)
    #expect(await queue.next() == nil)
}

@Test func nextReturnsInEnqueueOrderAndDrains() async {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    await queue.enqueue(prepared("a"))
    await queue.enqueue(prepared("b"))

    #expect(await queue.ready() == 2)
    #expect(await queue.next()?.id == "a")
    #expect(await queue.next()?.id == "b")
    #expect(await queue.next() == nil)
}

// No `flush()` between the two: the app is killed, it does not shut down. What
// has to be pinned is `markPlayed`'s own write, and a flush in the middle would
// pin the flush instead.
@Test func aPlayedAnecdoteIsRememberedAcrossInstances() async {
    let store = temporaryStore()
    let first = AnecdoteQueue(storeURL: store)
    await first.markPlayed("https://www.anekdot.ru/id/1/")

    let second = AnecdoteQueue(storeURL: store)

    #expect(await second.hasPlayed("https://www.anekdot.ru/id/1/"))
    #expect(await second.hasPlayed("https://www.anekdot.ru/id/2/") == false)
}

// The other half, and the reason `PreparedAnecdote` and `SpokenClip` are
// `Codable` at all: a batch that does not survive a restart costs the
// 70-second model load and a whole round of synthesis at every launch.
@Test func aPreparedBatchSurvivesARestart() async {
    let store = temporaryStore()
    let first = AnecdoteQueue(storeURL: store)
    await first.enqueue(prepared("a"))
    await first.enqueue(prepared("b"))

    let second = AnecdoteQueue(storeURL: store)

    #expect(await second.ready() == 2)
    #expect(await second.next() == prepared("a"))
}

@Test func drainingTheQueueSurvivesARestart() async {
    let store = temporaryStore()
    let first = AnecdoteQueue(storeURL: store)
    await first.enqueue(prepared("a"))
    await first.enqueue(prepared("b"))
    _ = await first.next()

    let second = AnecdoteQueue(storeURL: store)

    // Without the pop reaching disk, a restart replays what was handed out.
    #expect(await second.ready() == 1)
    #expect(await second.next()?.id == "b")
}

// The upgrade case: one non-optional field added to `PreparedAnecdote` makes
// every existing store's `pending` undecodable. Read as one unit that takes the
// played history with it, and every anecdote the user has heard becomes
// unheard on the first launch after the upgrade.
@Test func aStoreWhosePendingCannotBeReadStillKeepsThePlayedSet() async throws {
    let store = temporaryStore()
    try Data("""
    {"pending":[{"unexpected":"shape"}],"played":["https://www.anekdot.ru/id/1/"]}
    """.utf8).write(to: store)

    let queue = AnecdoteQueue(storeURL: store)

    #expect(await queue.ready() == 0)
    #expect(await queue.hasPlayed("https://www.anekdot.ru/id/1/"))
}

// A write that cannot land must not report success. The ordinary shapes are a
// full disk and a sandbox denial; an unmakeable parent directory stands in for
// them. Swallowed, this loses played ids and the anecdote repeats after a
// restart, with nothing anywhere saying why.
@Test func aStoreThatCannotBeWrittenIsReportedRatherThanSwallowed() async throws {
    let blocker = FileManager.default.temporaryDirectory
        .appendingPathComponent("blocker-\(UUID().uuidString)")
    try Data("occupied".utf8).write(to: blocker)
    let queue = AnecdoteQueue(storeURL: blocker.appendingPathComponent("store.json"))

    await queue.markPlayed("https://www.anekdot.ru/id/1/")

    #expect(await queue.lastPersistFailure != nil)
    await #expect(throws: (any Error).self) { try await queue.flush() }
}

@Test func aStoreThatCanBeWrittenReportsNoFailure() async {
    let queue = AnecdoteQueue(storeURL: temporaryStore())

    await queue.markPlayed("https://www.anekdot.ru/id/1/")

    #expect(await queue.lastPersistFailure == nil)
}

@Test func unseenFiltersOutWhatWasAlreadyPlayed() async {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    await queue.markPlayed("b")

    let fresh = await queue.unseen(from: [
        Anecdote(id: "a", text: "one"),
        Anecdote(id: "b", text: "two"),
        Anecdote(id: "c", text: "three"),
    ])

    #expect(fresh.map(\.id) == ["a", "c"])
}

@Test func unseenAlsoExcludesWhatIsAlreadyQueued() async {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    await queue.enqueue(prepared("b"))

    let fresh = await queue.unseen(from: [
        Anecdote(id: "a", text: "one"),
        Anecdote(id: "b", text: "two"),
    ])

    // Queueing the same anecdote twice would play it twice — the whole point
    // of the seen set is defeated if the pending queue is not consulted.
    #expect(fresh.map(\.id) == ["a"])
}

// The same defect from the other direction: a feed page that lists one guid
// twice would otherwise be prepared twice, synthesized twice and played twice,
// with the pending list consulted faithfully and still no help.
@Test func unseenReturnsARepeatedIdOnlyOnce() async {
    let queue = AnecdoteQueue(storeURL: temporaryStore())

    let fresh = await queue.unseen(from: [
        Anecdote(id: "a", text: "one"),
        Anecdote(id: "b", text: "two"),
        Anecdote(id: "a", text: "one again"),
    ])

    #expect(fresh.map(\.id) == ["a", "b"])
}

@Test func aCorruptStoreStartsEmptyInsteadOfThrowing() async {
    let store = temporaryStore()
    try? Data("not json".utf8).write(to: store)

    let queue = AnecdoteQueue(storeURL: store)

    #expect(await queue.ready() == 0)
    #expect(await queue.hasPlayed("anything") == false)
}
