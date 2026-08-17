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
    }

    private let storeURL: URL
    private var store: Store

    public init(storeURL: URL) {
        self.storeURL = storeURL
        // A store we cannot read is treated as absent. Refusing to start because
        // of a corrupt cache would be worse than losing the cache.
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode(Store.self, from: data) {
            self.store = decoded
        } else {
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

    public func flush() { persist() }

    private func persist() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: storeURL, options: .atomic)
    }
}
