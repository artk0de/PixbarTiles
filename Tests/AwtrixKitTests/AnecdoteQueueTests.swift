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

@Test func aPlayedAnecdoteIsRememberedAcrossInstances() async {
    let store = temporaryStore()
    let first = AnecdoteQueue(storeURL: store)
    await first.markPlayed("https://www.anekdot.ru/id/1/")
    await first.flush()

    let second = AnecdoteQueue(storeURL: store)

    #expect(await second.hasPlayed("https://www.anekdot.ru/id/1/"))
    #expect(await second.hasPlayed("https://www.anekdot.ru/id/2/") == false)
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
