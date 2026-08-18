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
    /// The directory this app writes clips into, and the only tree the reaper
    /// may reclaim inside.
    ///
    /// Required, with no default. A default would read as a guarantee while
    /// supplying none: the value has to be the directory the synthesizer was
    /// actually given, and only the composition root knows that. Whoever
    /// constructs a queue against a different root gets a reaper that leaks,
    /// which is visible; a queue that invented its own root would get one that
    /// deletes somewhere nobody chose.
    ///
    /// Readable for the same reason the synthesizer's `outputDirectory` is: the
    /// two being one value is this reaper's whole safety argument, and an
    /// argument nothing can ask about is one nothing can check.
    public nonisolated let clipRoot: URL
    private var store: Store

    /// Why the last write failed, or nil if it landed.
    ///
    /// The mutators do not throw. The in-memory change always succeeds and only
    /// its durability is at risk, so an anecdote already handed out cannot be
    /// un-handed because the disk was full — throwing there would report a
    /// problem by creating a worse one. What a failed write actually costs is
    /// the next launch: a played id that never reached disk comes back
    /// unplayed and the anecdote repeats.
    ///
    /// Nothing in production reads this, and that is deliberate. The host's
    /// background pass calls `flush()` instead, which re-attempts the write:
    /// that is both the cure and a live error, where this flag can only
    /// describe a state the retry may already have repaired. It stays as a
    /// diagnostic for whoever is looking at a queue in a debugger.
    public private(set) var lastPersistFailure: (any Error)?

    public init(storeURL: URL, clipRoot: URL) {
        self.storeURL = storeURL
        self.clipRoot = clipRoot
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

    /// Removes the directory registered by the previous retire, if this queue
    /// is allowed to.
    ///
    /// The containment check is here rather than at registration because this
    /// is where the untrusted value is spent: `spentClipDirectory` was written
    /// by an earlier process and read back with `try?`, so the name check that
    /// admitted it ran somewhere this code cannot vouch for. What it is checked
    /// against is `clipRoot`, which came from the composition root in THIS
    /// process and is the one part of the decision the store cannot influence.
    ///
    /// Forgotten either way. A path outside the root will never become inside
    /// it, so keeping it would only mean re-deciding the same question at every
    /// retire for the rest of the install.
    private func reclaimSpentClips() {
        guard let spent = store.spentClipDirectory else { return }
        store.spentClipDirectory = nil
        guard Self.isContained(URL(fileURLWithPath: spent), in: clipRoot) else { return }
        try? FileManager.default.removeItem(atPath: spent)
    }

    /// Whether `directory` lies strictly inside `root`.
    ///
    /// Compared as path components rather than as text, because `clips-evil` is
    /// a string with `clips` as its prefix and is not inside it. Strictly, so
    /// the root itself is never the thing removed — a store naming the root
    /// would otherwise take every prepared batch with it in one call.
    ///
    /// Standardized but not symlink-resolved. Both sides are built from the
    /// same value the composition root handed out, so they agree already;
    /// resolving would introduce a disagreement of its own between a directory
    /// that exists and one that does not, and its failure direction is a leak
    /// rather than a deletion — which is the way round this has to fail.
    private static func isContained(_ directory: URL, in root: URL) -> Bool {
        let inside = directory.standardizedFileURL.pathComponents
        let boundary = root.standardizedFileURL.pathComponents
        guard inside.count > boundary.count else { return false }
        return Array(inside.prefix(boundary.count)) == boundary
    }

    /// The directory holding an anecdote's clips, when it is named for that
    /// anecdote.
    ///
    /// Two things must hold. Every clip shares one directory — otherwise the
    /// only directory covering them all is a parent that holds other things
    /// too. And that directory's name equals `namespace(for:)`, the name the
    /// preparer hands the synthesizer.
    ///
    /// This establishes naming, not authorship: `id` and the clip paths come
    /// out of the same record, so a store written deliberately can always
    /// satisfy it. That is not the case being defended against. `retire`
    /// removes a directory tree, and `PreparedAnecdote` is `Codable` — read
    /// back with `try?` from a file on the user's own disk at every launch. A
    /// truncated write, a merged sync copy or a hand-edit during debugging each
    /// decode cleanly while pointing the clips somewhere else, and against
    /// those the name is decisive: none of them lands on a directory named for
    /// the sanitized guid. A store crafted on purpose needs no defence here,
    /// because it sits at the user's own permissions — whoever can write it can
    /// already delete what the reaper would.
    ///
    /// What the name really buys is that the delete path stops depending on the
    /// write path's promise to use a subdirectory, which is not a promise it
    /// can lean on once someone changes how clips are produced.
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
