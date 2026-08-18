import Foundation
import Testing
@testable import AwtrixKit

/// Every fixture in these tests writes its clips somewhere under the temporary
/// directory, so that is the root the reaper is contained by here. It is
/// deliberately wide: a narrower one would answer the earlier guards' questions
/// for them, and a name check that never runs because containment rejected
/// first is a check nothing is testing. The tests that are ABOUT containment
/// name their own root.
private let anyTemporaryRoot = FileManager.default.temporaryDirectory

/// The window for every test that is not about the window. Ten days, the value
/// the app ships: a fixture minted during a test run is nowhere near it, so a
/// reap in one of these can only be taking something for the reason that test
/// names. The tests that are ABOUT retention state their own.
private let anyRetention: TimeInterval = 10 * 24 * 60 * 60

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
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )

    #expect(await queue.ready() == 0)
    #expect(await queue.next() == nil)
}

@Test func nextReturnsInEnqueueOrderAndDrains() async {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
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
    let first = AnecdoteQueue(storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention)
    await first.markPlayed("https://www.anekdot.ru/id/1/")

    let second = AnecdoteQueue(storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention)

    #expect(await second.hasPlayed("https://www.anekdot.ru/id/1/"))
    #expect(await second.hasPlayed("https://www.anekdot.ru/id/2/") == false)
}

// The other half, and the reason `PreparedAnecdote` and `SpokenClip` are
// `Codable` at all: a batch that does not survive a restart costs the
// 70-second model load and a whole round of synthesis at every launch.
@Test func aPreparedBatchSurvivesARestart() async {
    let store = temporaryStore()
    let first = AnecdoteQueue(storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention)
    await first.enqueue(prepared("a"))
    await first.enqueue(prepared("b"))

    let second = AnecdoteQueue(storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention)

    #expect(await second.ready() == 2)
    #expect(await second.next() == prepared("a"))
}

@Test func drainingTheQueueSurvivesARestart() async {
    let store = temporaryStore()
    let first = AnecdoteQueue(storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention)
    await first.enqueue(prepared("a"))
    await first.enqueue(prepared("b"))
    _ = await first.next()

    let second = AnecdoteQueue(storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention)

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

    let queue = AnecdoteQueue(storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention)

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
    let queue = AnecdoteQueue(
        storeURL: blocker.appendingPathComponent("store.json"),
        clipRoot: anyTemporaryRoot, retention: anyRetention
    )

    await queue.markPlayed("https://www.anekdot.ru/id/1/")

    #expect(await queue.lastPersistFailure != nil)
    await #expect(throws: (any Error).self) { try await queue.flush() }
}

@Test func aStoreThatCanBeWrittenReportsNoFailure() async {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )

    await queue.markPlayed("https://www.anekdot.ru/id/1/")

    #expect(await queue.lastPersistFailure == nil)
}

@Test func unseenFiltersOutWhatWasAlreadyPlayed() async {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    await queue.markPlayed("b")

    let fresh = await queue.unseen(from: [
        Anecdote(id: "a", text: "one"),
        Anecdote(id: "b", text: "two"),
        Anecdote(id: "c", text: "three"),
    ])

    #expect(fresh.map(\.id) == ["a", "c"])
}

@Test func unseenAlsoExcludesWhatIsAlreadyQueued() async {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
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
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )

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

/// The same anecdote, with its clips backdated on disk.
///
/// A pending anecdote carries no timestamp of its own — the moment it was
/// prepared is Task 18's field — so its age is the age of the files the reaper
/// would be reclaiming, which is the thing actually being bounded.
private func preparedOnDisk(_ id: String, writtenAgo age: TimeInterval) throws -> PreparedAnecdote {
    let anecdote = try preparedOnDisk(id)
    let written = Date().addingTimeInterval(-age)
    for clip in anecdote.clips {
        try FileManager.default.setAttributes(
            [.modificationDate: written], ofItemAtPath: clip.url.path
        )
    }
    return anecdote
}

/// The moment `retire` stamped, read back rather than guessed.
///
/// A test that took a `Date()` of its own would be a few microseconds off the
/// one in the record, which is fine for a window of days and fatal for the
/// boundary — the one case where the two have to be the same instant.
private func onlyPlayedEntry(of queue: AnecdoteQueue) async throws -> PlayedAnecdote {
    let history = await queue.history()
    #expect(history.count == 1)
    return try #require(history.first)
}

/// Reaps whatever is already in history, by asking well past the window.
///
/// The tests below are about WHICH directories a reap touches once an entry has
/// expired. Where the window's edge falls is a different rule with a test of its
/// own, and repeating it here would only mean every one of these could fail for
/// that reason instead of its own.
private func reapEverything(in queue: AnecdoteQueue) async -> Int {
    await queue.reapExpired(now: Date().addingTimeInterval(anyRetention * 2))
}

// MARK: - Clips outlive the play

// What the one-behind reaper did instead: delete the previous anecdote's clips
// at the next retire. History has nothing to replay from if the audio is gone
// by then, so nothing removes clips at the moment of playing any more.
@Test func aPlayedAnecdoteKeepsItsClipsUntilTheyExpire() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let spent = try preparedOnDisk("https://www.anekdot.ru/id/1/")
    let spentDirectory = try #require(spent.clips.first?.url.deletingLastPathComponent())

    await queue.retire(spent)
    // The retire that used to reclaim it, and a reap on top — neither of which
    // is old enough to be the thing that takes it.
    await queue.retire(try preparedOnDisk("https://www.anekdot.ru/id/2/"))
    #expect(await queue.reapExpired(now: Date()) == 0)

    #expect(FileManager.default.fileExists(atPath: spentDirectory.path))
    #expect(await queue.history().count == 2)
}

@Test func historyIsNewestFirst() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    await queue.retire(prepared("a"))
    await queue.retire(prepared("b"))

    let history = await queue.history()

    #expect(history.map(\.anecdote.id) == ["b", "a"])
    // Newest first is a claim about the moments, not only about the order two
    // calls happened to be made in.
    let newest = try #require(history.first)
    let oldest = try #require(history.last)
    #expect(newest.playedAt >= oldest.playedAt)
}

// MARK: - Retention

// The window a played anecdote's audio is allowed to reach, and the only thing
// that takes it now.
@Test func clipsOlderThanTheRetentionWindowAreDeleted() async throws {
    let retention: TimeInterval = 10 * 24 * 60 * 60
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: retention
    )
    let spent = try preparedOnDisk("https://www.anekdot.ru/id/1/")
    let directory = try #require(spent.clips.first?.url.deletingLastPathComponent())
    await queue.retire(spent)
    let playedAt = try await onlyPlayedEntry(of: queue).playedAt

    let reaped = await queue.reapExpired(now: playedAt.addingTimeInterval(retention + 1))

    #expect(reaped == 1)
    #expect(FileManager.default.fileExists(atPath: directory.path) == false)
}

// A second apart from the test above, and the opposite answer — because a
// window that only ever sees fixtures days clear of it says nothing about where
// its edge is.
@Test func clipsInsideTheRetentionWindowSurviveAReap() async throws {
    let retention: TimeInterval = 10 * 24 * 60 * 60
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: retention
    )
    let spent = try preparedOnDisk("https://www.anekdot.ru/id/1/")
    let directory = try #require(spent.clips.first?.url.deletingLastPathComponent())
    await queue.retire(spent)
    let playedAt = try await onlyPlayedEntry(of: queue).playedAt

    let reaped = await queue.reapExpired(now: playedAt.addingTimeInterval(retention - 1))

    #expect(reaped == 0)
    #expect(FileManager.default.fileExists(atPath: directory.path))
    #expect(await queue.history().count == 1)
}

// The edge itself, decided deliberately: the retention is the age clips are
// ALLOWED to reach, so an entry that has reached it has not outlived it and is
// kept. Expiry starts strictly past it.
//
// Both sides in one test, from one recorded moment. Split in two, each half
// would pass on its own under `>=` or under `>` respectively, and the pair could
// drift apart without anything saying so.
@Test func anEntryExactlyAtTheRetentionAgeIsKeptAndAMillisecondOlderIsNot() async throws {
    let retention: TimeInterval = 10 * 24 * 60 * 60
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: retention
    )
    let spent = try preparedOnDisk("https://www.anekdot.ru/id/1/")
    let directory = try #require(spent.clips.first?.url.deletingLastPathComponent())
    await queue.retire(spent)
    let playedAt = try await onlyPlayedEntry(of: queue).playedAt

    #expect(await queue.reapExpired(now: playedAt.addingTimeInterval(retention)) == 0)
    #expect(FileManager.default.fileExists(atPath: directory.path))

    #expect(await queue.reapExpired(now: playedAt.addingTimeInterval(retention + 0.001)) == 1)
    #expect(FileManager.default.fileExists(atPath: directory.path) == false)
}

@Test func reapingDropsTheHistoryEntryItDeleted() async throws {
    let store = temporaryStore()
    let queue = AnecdoteQueue(
        storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    await queue.retire(try preparedOnDisk("https://www.anekdot.ru/id/1/"))

    #expect(await reapEverything(in: queue) == 1)

    #expect(await queue.history().isEmpty)
    // And stays dropped. An entry that came back on the next launch would offer
    // the user a replay of audio this reap has already removed.
    let reopened = AnecdoteQueue(
        storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    #expect(await reopened.history().isEmpty)
}

// History expires; the played set does not. The requirement the queue exists
// for is that an anecdote is never heard twice, and an entry ageing out of the
// replay list is not the user forgetting they heard it.
@Test func expiringFromHistoryDoesNotMakeAnAnecdotePlayableAgain() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    await queue.retire(try preparedOnDisk("https://www.anekdot.ru/id/1/"))

    #expect(await reapEverything(in: queue) == 1)

    #expect(await queue.history().isEmpty)
    #expect(await queue.hasPlayed("https://www.anekdot.ru/id/1/"))
    let fresh = await queue.unseen(from: [
        Anecdote(id: "https://www.anekdot.ru/id/1/", text: "one"),
    ])
    #expect(fresh.isEmpty)
}

// MARK: - What the reaper may remove

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

    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    await queue.retire(PreparedAnecdote(
        id: "split", text: "joke",
        clips: [SpokenClip(url: leftClip), SpokenClip(url: rightClip)],
        laughter: "АХАХАХА"
    ))

    #expect(await reapEverything(in: queue) == 1)

    #expect(FileManager.default.fileExists(atPath: leftClip.path))
    #expect(FileManager.default.fileExists(atPath: rightClip.path))
    #expect(FileManager.default.fileExists(atPath: leftBystander.path))
    #expect(FileManager.default.fileExists(atPath: rightBystander.path))
}

// `reapExpired` removes a directory tree, and a `PreparedAnecdote` is not
// something this process necessarily created — it is decoded with `try?` from a
// file on the user's own disk at every launch. A truncated write, a merged sync
// copy or a hand-edit during debugging all decode cleanly while pointing the
// clips somewhere else, and "the synthesizer always writes a subdirectory" is a
// promise about the write path, offered to the delete path.
//
// So the reaper reclaims only a directory NAMED for the anecdote it belongs to.
// That is a naming rule rather than a proof of authorship — a store written
// deliberately can satisfy it — but it is decisive against every accidental
// shape, which is the case that needs defending.
//
// The record is ours either way, so the entry goes; the directory may not be, so
// it stays. `clipsOlderThanTheRetentionWindowAreDeleted` is the other half:
// without it, a reaper that deleted nothing at all would satisfy this.
@Test func aHistoryEntryWhoseDirectoryIsMisnamedIsDroppedWithoutDeleting() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("somewhere-else-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let clip = directory.appendingPathComponent("turn-0.wav")
    let bystander = directory.appendingPathComponent("something-of-the-users.txt")
    for file in [clip, bystander] { try Data().write(to: file) }

    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    // Clips sitting directly in a directory that is not their namespace: what a
    // store restored from a bad copy looks like. Inside the root, so containment
    // admits it and only the name is wrong.
    await queue.retire(PreparedAnecdote(
        id: "https://www.anekdot.ru/id/1/", text: "joke",
        clips: [SpokenClip(url: clip)], laughter: "АХАХАХА"
    ))

    #expect(await reapEverything(in: queue) == 1)

    #expect(FileManager.default.fileExists(atPath: directory.path))
    #expect(FileManager.default.fileExists(atPath: bystander.path))
    #expect(await queue.history().isEmpty)
}

// MARK: - Containment

// The naming rule above establishes that a directory is named for its anecdote.
// It does not establish WHERE it is: a clip path is decoded with `try?` from a
// file on the user's disk, and any directory anywhere whose last component
// happens to be a 48-character sanitized guid satisfies the name. The clip root
// is the second half of the answer — the reaper may only reclaim inside the
// directory this app writes clips into, which is a fact the app supplies rather
// than one the store can claim.
@Test func aHistoryEntryOutsideTheClipRootIsDroppedWithoutDeleting() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("clip-root-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    // Named exactly as the synthesizer would name it, and a single directory —
    // so it passes both of the earlier guards and only its location is wrong.
    let elsewhere = FileManager.default.temporaryDirectory
        .appendingPathComponent("elsewhere-\(UUID().uuidString)")
        .appendingPathComponent(PreparedAnecdote.namespace(for: "https://www.anekdot.ru/id/1/"))
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let clip = elsewhere.appendingPathComponent("turn-0.wav")
    let bystander = elsewhere.appendingPathComponent("something-of-the-users.txt")
    for file in [clip, bystander] { try Data().write(to: file) }

    let queue = AnecdoteQueue(storeURL: temporaryStore(), clipRoot: root, retention: anyRetention)
    await queue.retire(PreparedAnecdote(
        id: "https://www.anekdot.ru/id/1/", text: "joke",
        clips: [SpokenClip(url: clip)], laughter: "АХАХАХА"
    ))

    #expect(await reapEverything(in: queue) == 1)

    #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    #expect(FileManager.default.fileExists(atPath: bystander.path))
    #expect(await queue.history().isEmpty)
}

// The root is the boundary, not a directory to be reclaimed. A store naming the
// root itself passes containment by any test written as "is it under the root,
// or the root" — and reclaiming it takes every prepared batch with it, which is
// the largest thing the reaper could possibly delete.
@Test func theClipRootItselfIsNeverReclaimed() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("clip-root-\(UUID().uuidString)")
        .appendingPathComponent(PreparedAnecdote.namespace(for: "https://www.anekdot.ru/id/1/"))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let clip = root.appendingPathComponent("turn-0.wav")
    try Data().write(to: clip)

    let queue = AnecdoteQueue(storeURL: temporaryStore(), clipRoot: root, retention: anyRetention)
    // Clips sitting directly in the root: the directory IS the root, and it is
    // named for this anecdote, so both earlier guards let it through.
    await queue.retire(PreparedAnecdote(
        id: "https://www.anekdot.ru/id/1/", text: "joke",
        clips: [SpokenClip(url: clip)], laughter: "АХАХАХА"
    ))

    #expect(await reapEverything(in: queue) == 1)

    #expect(FileManager.default.fileExists(atPath: root.path))
}

// A directory nested deeper than the synthesizer writes is still inside the
// root, and still reclaimed. Without this, containment could be implemented as
// "the parent is exactly the root" and nothing would say so — and the two tests
// above would both still pass.
@Test func aClipDirectoryNestedDeeperInsideTheClipRootIsStillReclaimed() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("clip-root-\(UUID().uuidString)")
    let nested = root.appendingPathComponent("batch-7")
        .appendingPathComponent(PreparedAnecdote.namespace(for: "https://www.anekdot.ru/id/1/"))
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let clip = nested.appendingPathComponent("turn-0.wav")
    try Data().write(to: clip)

    let queue = AnecdoteQueue(storeURL: temporaryStore(), clipRoot: root, retention: anyRetention)
    await queue.retire(PreparedAnecdote(
        id: "https://www.anekdot.ru/id/1/", text: "joke",
        clips: [SpokenClip(url: clip)], laughter: "АХАХАХА"
    ))

    #expect(await reapEverything(in: queue) == 1)

    #expect(FileManager.default.fileExists(atPath: nested.path) == false)
}

// A root whose name is a prefix of the directory's is not a root that contains
// it. Compared as text rather than as path components, `clips-evil` sits
// happily inside `clips` and the containment rule is decorative.
@Test func aDirectoryWhoseRootIsOnlyANamePrefixIsNeverReclaimed() async throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("prefix-\(UUID().uuidString)")
    let root = base.appendingPathComponent("clips")
    let sibling = base.appendingPathComponent("clips-evil")
        .appendingPathComponent(PreparedAnecdote.namespace(for: "https://www.anekdot.ru/id/1/"))
    for directory in [root, sibling] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let clip = sibling.appendingPathComponent("turn-0.wav")
    try Data().write(to: clip)

    let queue = AnecdoteQueue(storeURL: temporaryStore(), clipRoot: root, retention: anyRetention)
    await queue.retire(PreparedAnecdote(
        id: "https://www.anekdot.ru/id/1/", text: "joke",
        clips: [SpokenClip(url: clip)], laughter: "АХАХАХА"
    ))

    #expect(await reapEverything(in: queue) == 1)

    #expect(FileManager.default.fileExists(atPath: sibling.path))
}

// MARK: - Pending clips are bounded by the same window

// A prepared batch that is never played is bounded by nothing else. Task 18
// keeps yesterday's leftovers rather than discarding them, so "the queue drains
// within the day" stops being true and the only limit left on what synthesis
// puts on disk is this one.
@Test func pendingClipsOlderThanTheRetentionWindowAreDeletedToo() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let stale = try preparedOnDisk(
        "https://www.anekdot.ru/id/1/", writtenAgo: anyRetention + 60
    )
    let directory = try #require(stale.clips.first?.url.deletingLastPathComponent())
    await queue.enqueue(stale)

    #expect(await queue.reapExpired(now: Date()) == 1)

    #expect(FileManager.default.fileExists(atPath: directory.path) == false)
    #expect(await queue.ready() == 0)
}

// The other side of the same window. A minute younger and the batch is one the
// user has not heard yet, which is the whole reason it is on disk.
@Test func pendingClipsInsideTheRetentionWindowSurviveAReap() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let fresh = try preparedOnDisk(
        "https://www.anekdot.ru/id/1/", writtenAgo: anyRetention - 60
    )
    let directory = try #require(fresh.clips.first?.url.deletingLastPathComponent())
    await queue.enqueue(fresh)

    #expect(await queue.reapExpired(now: Date()) == 0)

    #expect(FileManager.default.fileExists(atPath: directory.path))
    #expect(await queue.ready() == 1)
}

// A batch is old only once all of it is. Clips are written a turn at a time, so
// the first file in a directory can be minutes older than the last — and a
// window read off the oldest one would take a turn written moments ago with it.
@Test func aPendingBatchIsOnlyExpiredOnceItsNewestClipIs() async throws {
    let id = "https://www.anekdot.ru/id/1/"
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("clips-\(UUID().uuidString)")
        .appendingPathComponent(PreparedAnecdote.namespace(for: id))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let old = directory.appendingPathComponent("turn-0.wav")
    let fresh = directory.appendingPathComponent("turn-1.wav")
    for file in [old, fresh] { try Data().write(to: file) }
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-(anyRetention + 60))],
        ofItemAtPath: old.path
    )

    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    await queue.enqueue(PreparedAnecdote(
        id: id, text: "joke",
        clips: [SpokenClip(url: old), SpokenClip(url: fresh)], laughter: "АХАХАХА"
    ))

    #expect(await queue.reapExpired(now: Date()) == 0)

    #expect(FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
    #expect(await queue.ready() == 1)
}

// A pending entry with nothing on disk has no age to read and nothing to
// reclaim, so the reaper leaves it where it is. `AnecdoteConnector` already
// drops an unplayable entry when it pops one, and treating "not found" as an
// age would let a detached volume take the record too.
@Test func aPendingEntryWhoseClipsAreAlreadyGoneIsLeftAlone() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    await queue.enqueue(prepared("never-written-\(UUID().uuidString)"))

    #expect(await queue.reapExpired(now: Date().addingTimeInterval(anyRetention * 10)) == 0)

    #expect(await queue.ready() == 1)
}

// MARK: - Stores written before history existed

/// The store as an earlier version wrote it: a pending batch, the played set,
/// and the one-behind reaper's parked directory.
///
/// Encoded through the same machinery that version used rather than spelled out
/// as JSON, so this is a file that release really could have left behind and not
/// a guess at how `URL` and `Set` come out.
private struct LegacyStore: Codable {
    var pending: [PreparedAnecdote] = []
    var played: Set<String> = []
    var spentClipDirectory: String?
}

private func writeLegacyStore(_ legacy: LegacyStore, to url: URL) throws {
    try JSONEncoder().encode(legacy).write(to: url)
}

// Swift's synthesised `init(from:)` does not fall back to a property's default
// for a missing key, so `history` added as a plain field would make every store
// written before this change fail to decode — and the played set goes down with
// it, which is the one thing that must never be lost.
@Test func aStoreWrittenBeforeHistoryExistedStillDecodes() async throws {
    let store = temporaryStore()
    try writeLegacyStore(
        LegacyStore(pending: [prepared("a")], played: ["https://www.anekdot.ru/id/1/"]),
        to: store
    )

    let queue = AnecdoteQueue(
        storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention
    )

    // All three, because what this guards against is one absent key taking the
    // whole file with it.
    #expect(await queue.ready() == 1)
    #expect(await queue.hasPlayed("https://www.anekdot.ru/id/1/"))
    #expect(await queue.history().isEmpty)
    #expect(await queue.next() == prepared("a"))
}

// The one-behind reaper's last parked directory. It was registered by a version
// that is gone, and nothing else will ever come back for it, so the upgrade
// reclaims it — and then forgets it, because a directory removed twice is a
// directory removed once too often when something else has taken the name.
@Test func anOldStoresSpentClipDirectoryIsReclaimedOnce() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("clip-root-\(UUID().uuidString)")
    let spent = root
        .appendingPathComponent(PreparedAnecdote.namespace(for: "https://www.anekdot.ru/id/1/"))
    try FileManager.default.createDirectory(at: spent, withIntermediateDirectories: true)
    try Data().write(to: spent.appendingPathComponent("turn-0.wav"))
    let store = temporaryStore()
    try writeLegacyStore(LegacyStore(spentClipDirectory: spent.path), to: store)

    _ = AnecdoteQueue(storeURL: store, clipRoot: root, retention: anyRetention)
    #expect(FileManager.default.fileExists(atPath: spent.path) == false)

    // The same anecdote prepared again takes the same path — the name is derived
    // from the guid, so that is the ordinary case rather than an exotic one.
    try FileManager.default.createDirectory(at: spent, withIntermediateDirectories: true)
    _ = AnecdoteQueue(storeURL: store, clipRoot: root, retention: anyRetention)

    #expect(FileManager.default.fileExists(atPath: spent.path))
}

// The parked path was written by a process this one cannot vouch for and read
// back with `try?`, so it is checked against the root THIS process was given
// before anything is removed — exactly as the version that parked it did.
@Test func anOldStoresSpentClipDirectoryOutsideTheClipRootIsLeftAlone() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("clip-root-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let elsewhere = FileManager.default.temporaryDirectory
        .appendingPathComponent("elsewhere-\(UUID().uuidString)")
        .appendingPathComponent(PreparedAnecdote.namespace(for: "https://www.anekdot.ru/id/1/"))
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let bystander = elsewhere.appendingPathComponent("something-of-the-users.txt")
    try Data().write(to: bystander)
    let store = temporaryStore()
    try writeLegacyStore(LegacyStore(spentClipDirectory: elsewhere.path), to: store)

    _ = AnecdoteQueue(storeURL: store, clipRoot: root, retention: anyRetention)

    #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    #expect(FileManager.default.fileExists(atPath: bystander.path))
}

@Test func aCorruptStoreStartsEmptyInsteadOfThrowing() async {
    let store = temporaryStore()
    try? Data("not json".utf8).write(to: store)

    let queue = AnecdoteQueue(
        storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention
    )

    #expect(await queue.ready() == 0)
    #expect(await queue.hasPlayed("anything") == false)
}
