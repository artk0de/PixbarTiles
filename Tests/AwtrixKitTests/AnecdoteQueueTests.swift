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

/// An anecdote whose single clip really exists, in a directory named the way
/// the synthesizer names one — so retiring it registers a directory the reaper
/// will accept as its own.
private func preparedOnDisk(_ id: String) throws -> PreparedAnecdote {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("clips-\(UUID().uuidString)")
        .appendingPathComponent(PreparedAnecdote.namespace(for: id))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let clip = directory.appendingPathComponent("turn-0.wav")
    try Data().write(to: clip)
    return PreparedAnecdote(
        id: id, text: "joke \(id)", clips: [SpokenClip(url: clip)], laughter: "АХАХАХА"
    )
}

// The reaper removes a whole directory, so it may only do that when the
// directory holds nothing but that anecdote's clips. Clips spread across two
// directories have no such directory — the only one covering both is their
// parent, and deleting that would take everything else in it.
@Test func clipsSpreadAcrossTwoDirectoriesReclaimNothing() async throws {
    // BOTH directories carry the anecdote's namespace, under different
    // parents. That is deliberate: it keeps the name check from answering this
    // question, so what is under test is the count of directories and nothing
    // else. Named anything else, this test would pass for the wrong reason.
    let namespace = PreparedAnecdote.namespace(for: "split")
    let left = FileManager.default.temporaryDirectory
        .appendingPathComponent("split-a-\(UUID().uuidString)").appendingPathComponent(namespace)
    let right = FileManager.default.temporaryDirectory
        .appendingPathComponent("split-b-\(UUID().uuidString)").appendingPathComponent(namespace)
    for directory in [left, right] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let leftClip = left.appendingPathComponent("turn-0.wav")
    let rightClip = right.appendingPathComponent("turn-1.wav")
    // Files the reaper has no business touching, beside each clip.
    let leftBystander = left.appendingPathComponent("bystander.txt")
    let rightBystander = right.appendingPathComponent("bystander.txt")
    for file in [leftClip, rightClip, leftBystander, rightBystander] {
        try Data().write(to: file)
    }

    let queue = AnecdoteQueue(storeURL: temporaryStore())
    await queue.retire(PreparedAnecdote(
        id: "split", text: "joke",
        clips: [SpokenClip(url: leftClip), SpokenClip(url: rightClip)],
        laughter: "АХАХАХА"
    ))
    // The retire that would reclaim whatever the previous one registered.
    await queue.retire(try preparedOnDisk("next"))

    #expect(FileManager.default.fileExists(atPath: leftClip.path))
    #expect(FileManager.default.fileExists(atPath: rightClip.path))
    #expect(FileManager.default.fileExists(atPath: leftBystander.path))
    #expect(FileManager.default.fileExists(atPath: rightBystander.path))
}

// `retire` removes a directory tree, and a `PreparedAnecdote` is not something
// this process necessarily created — it is decoded with `try?` from a file on
// the user's own disk at every launch. A truncated write, a merged sync copy or
// a hand-edit during debugging all decode cleanly while pointing the clips
// somewhere else, and "the synthesizer always writes a subdirectory" is a
// promise about the write path, offered to the delete path.
//
// So the reaper reclaims only a directory NAMED for the anecdote it belongs to.
// That is a naming rule rather than a proof of authorship — a store written
// deliberately can satisfy it — but it is decisive against every accidental
// shape, which is the case that needs defending.
@Test func aClipDirectoryNotNamedForItsAnecdoteIsNeverReclaimed() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("somewhere-else-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let clip = directory.appendingPathComponent("turn-0.wav")
    let bystander = directory.appendingPathComponent("something-of-the-users.txt")
    for file in [clip, bystander] { try Data().write(to: file) }

    let queue = AnecdoteQueue(storeURL: temporaryStore())
    // Clips sitting directly in a directory that is not their namespace: what a
    // store restored from a bad copy looks like.
    await queue.retire(PreparedAnecdote(
        id: "https://www.anekdot.ru/id/1/", text: "joke",
        clips: [SpokenClip(url: clip)], laughter: "АХАХАХА"
    ))
    // The retire that reclaims whatever the previous one registered.
    await queue.retire(try preparedOnDisk("https://www.anekdot.ru/id/2/"))

    #expect(FileManager.default.fileExists(atPath: directory.path))
    #expect(FileManager.default.fileExists(atPath: bystander.path))
}

// The check is a naming rule, not a ban on reclaiming: a directory that does
// carry the namespace is still removed. Without this, disabling the reaper
// outright would satisfy the test above.
@Test func aClipDirectoryNamedForItsAnecdoteIsStillReclaimed() async throws {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    let spent = try preparedOnDisk("https://www.anekdot.ru/id/1/")
    let spentDirectory = try #require(spent.clips.first?.url.deletingLastPathComponent())

    await queue.retire(spent)
    #expect(FileManager.default.fileExists(atPath: spentDirectory.path))
    await queue.retire(try preparedOnDisk("https://www.anekdot.ru/id/2/"))

    #expect(FileManager.default.fileExists(atPath: spentDirectory.path) == false)
}

@Test func aCorruptStoreStartsEmptyInsteadOfThrowing() async {
    let store = temporaryStore()
    try? Data("not json".utf8).write(to: store)

    let queue = AnecdoteQueue(storeURL: store)

    #expect(await queue.ready() == 0)
    #expect(await queue.hasPlayed("anything") == false)
}
