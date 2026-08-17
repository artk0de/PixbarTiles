import Foundation

/// Prepared anecdotes waiting to play, and the ids of those already played.
///
/// Both live in one file because they answer one question together: what may be
/// played next. A played id is never forgotten — the requirement is that
/// anecdotes do not repeat, and the feed's guid is the identity that makes that
/// checkable.
public actor AnecdoteQueue {
    private struct Store: Codable {
        var pending: [PreparedAnecdote] = []
        var played: Set<String> = []
        /// The clip directory of the anecdote retired before the current one.
        /// Persisted so a restart between two anecdotes reclaims it rather than
        /// leaking it.
        var spentClipDirectory: String?
    }

    /// The half that must never be lost, readable on its own.
    ///
    /// One non-optional field added to `PreparedAnecdote` — a prepared-at
    /// timestamp is the obvious next one — makes every existing store fail to
    /// decode. Read as a single unit, that failure takes the played history
    /// with it and every anecdote the user has heard becomes unheard, silently,
    /// on the first launch after an upgrade. A lost batch costs one model load;
    /// a lost played set costs the requirement this type exists for.
    private struct SalvagedPlayed: Codable {
        var played: Set<String>?
    }

    private let storeURL: URL
    private var store: Store

    /// Why the last write failed, or nil if it landed.
    ///
    /// The mutators do not throw. The in-memory change always succeeds and only
    /// its durability is at risk, so an anecdote already handed out cannot be
    /// un-handed because the disk was full — throwing there would report a
    /// problem by creating a worse one. What a failed write actually costs is
    /// the next launch: a played id that never reached disk comes back
    /// unplayed and the anecdote repeats. The host reads this and says so.
    public private(set) var lastPersistFailure: (any Error)?

    public init(storeURL: URL) {
        self.storeURL = storeURL
        let data = try? Data(contentsOf: storeURL)

        if let data, let decoded = try? JSONDecoder().decode(Store.self, from: data) {
            self.store = decoded
        } else if let data,
                  let salvaged = try? JSONDecoder().decode(SalvagedPlayed.self, from: data) {
            // The pending batch could not be read; the played set could.
            self.store = Store(played: salvaged.played ?? [])
        } else {
            // A store we cannot read at all is treated as absent. Refusing to
            // start because of a corrupt cache would be worse than losing it.
            self.store = Store()
        }
    }

    public func ready() -> Int { store.pending.count }

    public func enqueue(_ anecdote: PreparedAnecdote) {
        store.pending.append(anecdote)
        persist()
    }

    public func next() -> PreparedAnecdote? {
        guard !store.pending.isEmpty else { return nil }
        let head = store.pending.removeFirst()
        persist()
        return head
    }

    public func markPlayed(_ id: String) {
        store.played.insert(id)
        persist()
    }

    /// Takes an anecdote out of service: records it played, and reclaims the
    /// disk held by the one retired before it.
    ///
    /// One behind on purpose. `anecdote` is on its way to the player as this
    /// returns, so its own files have to survive the call; by the time the next
    /// one is due — half an hour later by default — it has long finished. That
    /// lag is what lets the audio be reclaimed with no lifecycle callback from
    /// the player and no coordination with the host.
    public func retire(_ anecdote: PreparedAnecdote) {
        store.played.insert(anecdote.id)
        reclaimSpentClips()
        store.spentClipDirectory = Self.clipDirectory(of: anecdote)?.path
        persist()
    }

    public func hasPlayed(_ id: String) -> Bool { store.played.contains(id) }

    /// Anecdotes neither played nor already waiting, each id at most once.
    ///
    /// Three ways the same joke reaches the queue twice, and all three are the
    /// same defect: it was played before, it is already pending, or the feed
    /// page listed the guid twice. Filtering through one growing set closes all
    /// three in a single pass.
    public func unseen(from anecdotes: [Anecdote]) -> [Anecdote] {
        var excluded = store.played.union(store.pending.map(\.id))
        return anecdotes.filter { excluded.insert($0.id).inserted }
    }

    /// Writes the store and reports whether it landed. The one call that turns
    /// a durability failure into something the caller can act on directly.
    public func flush() throws {
        try writeStore()
        lastPersistFailure = nil
    }

    private func reclaimSpentClips() {
        guard let spent = store.spentClipDirectory else { return }
        try? FileManager.default.removeItem(atPath: spent)
        store.spentClipDirectory = nil
    }

    /// The directory holding an anecdote's clips, but only when the reaper can
    /// prove it is one we made.
    ///
    /// Two things must hold. Every clip shares one directory — otherwise the
    /// only directory covering them all is a parent that holds other things
    /// too. And that directory is *named for the anecdote*:
    /// `namespace(for:)` is the name the preparer hands the synthesizer, so a
    /// directory carrying it is one the synthesizer made for this anecdote and
    /// for nothing else.
    ///
    /// The name is what makes this safe rather than merely tidy. `retire`
    /// removes a directory tree, and `PreparedAnecdote` is `Codable` — it is
    /// read back with `try?` from a file on the user's own disk at every
    /// launch. A truncated write, a merged sync copy or a hand-edit during
    /// debugging can each produce a perfectly decodable anecdote whose clips
    /// point somewhere else entirely. An operation that deletes recursively
    /// must not take its target from data it did not create, and the write path
    /// promising to use a subdirectory is not a promise the delete path can
    /// lean on — least of all after someone changes how clips are produced.
    ///
    /// A mismatch leaks a directory instead of removing the wrong one, which is
    /// the right way round to fail.
    private static func clipDirectory(of anecdote: PreparedAnecdote) -> URL? {
        let directories = Set(anecdote.clips.map { $0.url.deletingLastPathComponent() })
        guard directories.count == 1, let directory = directories.first else { return nil }
        guard directory.lastPathComponent == PreparedAnecdote.namespace(for: anecdote.id) else {
            return nil
        }
        return directory
    }

    private func persist() {
        do {
            try writeStore()
            lastPersistFailure = nil
        } catch {
            lastPersistFailure = error
        }
    }

    private func writeStore() throws {
        let data = try JSONEncoder().encode(store)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: storeURL, options: .atomic)
    }
}
