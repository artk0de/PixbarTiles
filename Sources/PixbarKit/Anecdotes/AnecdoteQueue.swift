import Foundation

/// Prepared anecdotes waiting to play, the ids of those already played, and the
/// recently played ones in full.
///
/// All three live in one file because they answer one question together: what
/// may be played next. A played id is never forgotten — the requirement is that
/// anecdotes do not repeat, and the feed's guid is the identity that makes that
/// checkable. History is the opposite kind of record: it holds whole anecdotes,
/// clips included, so one can be heard again, and it expires because those clips
/// are large. An anecdote that has left history is still never played twice.
public actor AnecdoteQueue {
    private struct Store: Codable {
        var pending: [PreparedAnecdote]
        var played: Set<String>
        var history: [PlayedAnecdote]

        private enum CodingKeys: String, CodingKey {
            case pending, played, history
        }

        init(
            pending: [PreparedAnecdote] = [],
            played: Set<String> = [],
            history: [PlayedAnecdote] = []
        ) {
            self.pending = pending
            self.played = played
            self.history = history
        }

        /// Every field read with `decodeIfPresent`, and that is the whole point
        /// of writing this by hand.
        ///
        /// Swift's synthesised `init(from:)` does not fall back to a property's
        /// default value for a missing key: it throws. So a field added here in
        /// any later version would make every store written before it fail to
        /// decode, and the played set — the one thing that must never be lost —
        /// would go down with the rest of the file. Absent is not corrupt, and
        /// this says so once rather than once per upgrade.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pending = try container.decodeIfPresent([PreparedAnecdote].self, forKey: .pending) ?? []
            played = try container.decodeIfPresent(Set<String>.self, forKey: .played) ?? []
            history = try container.decodeIfPresent([PlayedAnecdote].self, forKey: .history) ?? []
        }
    }

    /// The field versions before history existed parked the one-behind reaper's
    /// next victim in, read on its own.
    ///
    /// Not a property of `Store`, which describes what this version writes. A
    /// retired field that stayed on the current shape would be a value the
    /// encoder has to be told to leave out, and being told twice is how it comes
    /// back: writing that path again means the next launch removing whatever has
    /// taken the name since, and the name is the sanitized guid — so the same
    /// anecdote prepared again lands on exactly it. Absent from the type, it
    /// cannot be written by anything.
    private struct RetiredSpentClips: Codable {
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

    /// How long a played anecdote's clips are kept before the reaper may take
    /// them, and the same bound applied to a prepared batch nobody played.
    ///
    /// Required, with no default, for the reason `clipRoot` is: it is a policy
    /// about the user's disk, and the composition root is what knows it. A
    /// default here would be a number invented by the type that enforces it,
    /// which is how a window ends up documented in one place and applied from
    /// another.
    ///
    /// Readable so a test can ask what the shipped app actually keeps. A bound
    /// nothing can read back is a bound that can be set to zero without a
    /// single test noticing, and zero here deletes the audio of everything
    /// history offers to replay.
    public nonisolated let retention: TimeInterval
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

    public init(storeURL: URL, clipRoot: URL, retention: TimeInterval) {
        self.storeURL = storeURL
        self.clipRoot = clipRoot
        self.retention = retention
        let loaded = Self.loadStore(from: storeURL)
        self.store = loaded.store

        // The upgrade from the one-behind reaper. Whatever the previous version
        // parked is the last directory nothing else will ever come back for, so
        // this launch reclaims it — leaving it would leak that directory for the
        // life of the install, which is a regression from the version being
        // replaced.
        //
        // Written back immediately rather than at the next mutation, because the
        // rewritten file is what makes this happen once. `Store` has no such
        // field, so the write is what retires it.
        if let spent = loaded.retiredSpentClips {
            Self.reclaim(URL(fileURLWithPath: spent), inside: clipRoot)
            do {
                try Self.write(store, to: storeURL)
            } catch {
                lastPersistFailure = error
            }
        }
    }

    /// Reads the store, salvaging what can be salvaged, and reports any directory
    /// an earlier version left parked.
    ///
    /// Static because this runs while the actor is still being initialised. It
    /// touches nothing but its argument, so there is no isolation to have.
    private static func loadStore(from url: URL) -> (store: Store, retiredSpentClips: String?) {
        guard let data = try? Data(contentsOf: url) else { return (Store(), nil) }
        // Read on its own pass, so a file whose batch is unreadable still gives
        // up its parked directory rather than leaking it.
        let retired = (try? JSONDecoder().decode(RetiredSpentClips.self, from: data))?
            .spentClipDirectory

        if let decoded = try? JSONDecoder().decode(Store.self, from: data) {
            return (decoded, retired)
        }
        if let salvaged = try? JSONDecoder().decode(SalvagedPlayed.self, from: data) {
            // The pending batch could not be read; the played set could.
            return (Store(played: salvaged.played ?? []), retired)
        }
        // A store we cannot read at all is treated as absent. Refusing to start
        // because of a corrupt cache would be worse than losing it.
        return (Store(), retired)
    }

    public func ready() -> Int { store.pending.count }

    /// Whether anything still waiting was prepared on the calendar day that
    /// `moment` falls in.
    ///
    /// A calendar day, not a span of hours, and the difference is the whole
    /// point: what the daily refresh is for is having jokes from TODAY, so an
    /// anecdote prepared at half past eleven last night does not count as
    /// today's because it is only an hour old. The comparison lives here rather
    /// than in the connector because `pending` does, and a caller that had to
    /// fetch the batch to date it would be free to date it a second way.
    public func hasAnythingPrepared(onTheDayOf moment: Date) -> Bool {
        let day = Self.calendar.startOfDay(for: moment)
        return store.pending.contains { Self.generation(of: $0) == day }
    }

    public func enqueue(_ anecdote: PreparedAnecdote) {
        store.pending.append(anecdote)
        persist()
    }

    /// The anecdote that plays next: newest generation first, and within a
    /// generation the one the feed ranked highest.
    ///
    /// Both keys, and neither is optional. Rank alone lets a high-ranked
    /// leftover from last week outrank everything prepared since, for ever —
    /// it wins every comparison it is ever in. Generation alone plays today's
    /// batch in whatever order it happened to be synthesized, which throws away
    /// the only measure of popularity the feed gives.
    public func next() -> PreparedAnecdote? {
        guard let best = Self.indexOfNext(in: store.pending) else { return nil }
        let head = store.pending.remove(at: best)
        persist()
        return head
    }

    public func markPlayed(_ id: String) {
        store.played.insert(id)
        persist()
    }

    /// Takes an anecdote out of service: records it played, and keeps it, clips
    /// and all, for as long as the retention window allows.
    ///
    /// Nothing is deleted here. `anecdote` is on its way to the player as this
    /// returns — but that was never the reason to wait, because the user can ask
    /// to hear it again long after it has finished, and audio reclaimed at the
    /// moment of playing leaves history with nothing to offer. Age is what
    /// removes clips now, and `reapExpired` is where that happens.
    ///
    /// The moment is taken here rather than passed in, because this is the call
    /// that IS the playing: a caller supplying it could only be reporting a
    /// different instant than the one that happened.
    public func retire(_ anecdote: PreparedAnecdote) {
        store.played.insert(anecdote.id)
        store.history.append(PlayedAnecdote(anecdote: anecdote, playedAt: Date()))
        persist()
    }

    public func hasPlayed(_ id: String) -> Bool { store.played.contains(id) }

    /// What has been played recently and can still be heard again, newest first.
    ///
    /// Reversed rather than sorted by `playedAt`. Append order is the order the
    /// anecdotes were actually retired in, and two retires inside the same
    /// millisecond would otherwise come back in whichever order the sort
    /// happened to leave them.
    public func history() -> [PlayedAnecdote] { store.history.reversed() }

    /// Removes what has outlived the retention window — the clips first, then
    /// the records — and reports how many records went.
    ///
    /// `now` is a parameter, not a clock. The caller supplies the instant, and
    /// the app's is `Date()`; a clock abstraction would buy a seam that only
    /// tests use, where a parameter does the same thing in a signature the
    /// reader can see through. A test cannot wait ten days either way.
    ///
    /// `AnecdoteConnector.maintain()` is the caller: it already runs off the
    /// play path, and it is the one pass that happens both before and after
    /// every run, so the window is enforced at the same cadence the queue is
    /// restocked at.
    ///
    /// Pending is bounded by the same window as history, and it has to be:
    /// anecdotes prepared but never played accumulate across days — the daily
    /// refresh keeps yesterday's leftovers rather than discarding them — so
    /// history's window alone would leave the batch nobody heard growing until
    /// the disk did.
    ///
    /// A record whose directory the reaper is not allowed to touch is still
    /// dropped. The record is ours to forget; the directory may not be ours to
    /// remove, and re-deciding that at every reap for the rest of the install
    /// would not change the answer.
    public func reapExpired(now: Date) -> Int {
        var keptHistory: [PlayedAnecdote] = []
        for entry in store.history {
            guard hasExpired(entry.playedAt, at: now) else {
                keptHistory.append(entry)
                continue
            }
            Self.reclaim(Self.clipDirectory(of: entry.anecdote), inside: clipRoot)
        }

        var keptPending: [PreparedAnecdote] = []
        for anecdote in store.pending {
            guard let prepared = Self.age(of: anecdote), hasExpired(prepared, at: now) else {
                keptPending.append(anecdote)
                continue
            }
            Self.reclaim(Self.clipDirectory(of: anecdote), inside: clipRoot)
        }

        let reaped =
            (store.history.count - keptHistory.count) + (store.pending.count - keptPending.count)
        guard reaped > 0 else { return 0 }
        store.history = keptHistory
        store.pending = keptPending
        persist()
        return reaped
    }

    /// Whether `moment` is further back than the window allows, seen from `now`.
    ///
    /// Strictly further. The retention is the age clips are ALLOWED to reach, so
    /// one that has just reached it has not outlived it; expiry starts past the
    /// edge, not at it.
    private func hasExpired(_ moment: Date, at now: Date) -> Bool {
        now.timeIntervalSince(moment) > retention
    }

    /// The moment a pending anecdote's age is measured from, or nil when there
    /// is nothing to measure.
    ///
    /// The record's own `preparedAt` wherever there is one, and only the file
    /// system for a record written before that field existed. A modification
    /// date is not the age of the batch — it is the age of the last write to
    /// the file, which a backup pass, a sync client or a `touch` resets — and a
    /// batch whose clips are touched every week under a ten-day window is a
    /// batch that never expires.
    private static func age(of anecdote: PreparedAnecdote) -> Date? {
        anecdote.preparedAt ?? lastWrite(of: anecdote)
    }

    /// When this anecdote's clips were last written, or nil if none of them is
    /// on disk any more.
    ///
    /// The newest of them, so a batch counts as old only once all of it is. And
    /// nil is not an age: an anecdote whose files are already gone has nothing
    /// to reclaim, and reading "not found" as "infinitely old" would let a
    /// detached volume take the records too. `AnecdoteConnector` drops an
    /// unplayable pending entry when it pops one, which is the right place for
    /// it — that path knows the file system was asked at the moment of playing.
    private static func lastWrite(of anecdote: PreparedAnecdote) -> Date? {
        anecdote.clips.compactMap { clip in
            let attributes = try? FileManager.default.attributesOfItem(atPath: clip.url.path)
            return attributes?[.modificationDate] as? Date
        }.max()
    }

    // MARK: play order

    /// Read once rather than at every comparison. `Calendar.current` rebuilds
    /// its answer from the user's current locale each time it is asked, and one
    /// launch does not need two of them.
    private static let calendar = Calendar.current

    /// Where the next anecdote to play sits, or nil when nothing is waiting.
    ///
    /// A scan keeping the FIRST of any tie, rather than a sort. Ties are the
    /// ordinary case — a whole batch shares a generation, and a store written
    /// before this task has neither key on anything — and `sort` is not stable,
    /// so an equal pair could come back either way round and the queue would
    /// hand out a different anecdote on a rerun of the same state. The tie is
    /// broken by the order they were enqueued in, which is the order they were
    /// prepared in.
    private static func indexOfNext(in pending: [PreparedAnecdote]) -> Int? {
        guard var best = pending.indices.first else { return nil }
        for index in pending.indices.dropFirst()
        where playsBefore(pending[index], pending[best]) {
            best = index
        }
        return best
    }

    /// Whether `left` plays before `right`.
    private static func playsBefore(_ left: PreparedAnecdote, _ right: PreparedAnecdote) -> Bool {
        let leftDay = generation(of: left)
        let rightDay = generation(of: right)
        // Newest generation first: today's batch outranks yesterday's leftovers
        // entirely, whatever the feed thought of either.
        guard leftDay == rightDay else { return leftDay > rightDay }
        // Then the feed's own order, ascending — position zero was the most
        // voted for.
        return rank(of: left) < rank(of: right)
    }

    /// The calendar day an anecdote belongs to, or the distant past for one
    /// prepared before the field existed.
    ///
    /// Distant past rather than the present: a record restored from an older
    /// store plays after everything that has a generation. Read as "now" it
    /// would join today's batch instead of queueing behind it, which is the
    /// wrong way for this to fail — the whole point of the key is that stale
    /// material sinks.
    private static func generation(of anecdote: PreparedAnecdote) -> Date {
        guard let preparedAt = anecdote.preparedAt else { return .distantPast }
        return calendar.startOfDay(for: preparedAt)
    }

    /// The feed position an anecdote sorts on, or the worst possible one for a
    /// record that predates the field. Absent is worst, for the same reason an
    /// absent generation is oldest.
    private static func rank(of anecdote: PreparedAnecdote) -> Int {
        anecdote.rank ?? .max
    }

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

    /// Removes a directory, if this queue is allowed to.
    ///
    /// The containment check is here, at the one place a directory is actually
    /// spent, rather than wherever the path came from. Every path that reaches
    /// this was read back from the store with `try?` — written by an earlier
    /// process, possibly an earlier version — so whatever admitted it ran
    /// somewhere this code cannot vouch for. What it is checked against is
    /// `root`, which came from the composition root in THIS process and is the
    /// one part of the decision the store cannot influence.
    ///
    /// Nothing is retried. A path outside the root will never become inside it,
    /// so the caller drops the record either way.
    private static func reclaim(_ directory: URL?, inside root: URL) {
        guard let directory, isContained(directory, in: root) else { return }
        try? FileManager.default.removeItem(at: directory)
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
    /// satisfy it. That is not the case being defended against. `reapExpired`
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

    private func writeStore() throws { try Self.write(store, to: storeURL) }

    /// Static so `init` can write too, on the one path that has to: the
    /// migration off `spentClipDirectory` is only safe because it happens once,
    /// and it only happens once if the file says so.
    private static func write(_ store: Store, to url: URL) throws {
        let data = try JSONEncoder().encode(store)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
