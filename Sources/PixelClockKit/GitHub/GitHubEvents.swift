// Sources/PixelClockKit/GitHub/GitHubEvents.swift
import Foundation

/// What a tile had seen of its repository at the last good read — the line
/// between "already celebrated" and "new".
///
/// Per tile and persisted, so a relaunch does not celebrate again and an
/// outage celebrates what it missed once, at the next good read.
public struct GitHubSnapshot: Codable, Sendable, Equatable {
    /// The newest `starredAt` seen. Nil when no star has been seen yet.
    public var lastStarAt: Date?
    /// The newest fork `createdAt` seen.
    public var lastForkAt: Date?
    /// The open PR numbers at the last read. A PR is new by being absent here.
    public var openPRs: Set<Int>
    /// The totals at the last read. They exist for one case the timestamps
    /// cannot see: more stars (or forks) arriving between two reads than the
    /// query's `last: 20` page holds. Optional so a snapshot encoded before
    /// they were remembered still decodes — the detector then falls back to
    /// what the page shows.
    public var stars: Int?
    public var forks: Int?

    public init(
        lastStarAt: Date?, lastForkAt: Date?, openPRs: Set<Int>,
        stars: Int? = nil, forks: Int? = nil
    ) {
        self.lastStarAt = lastStarAt
        self.lastForkAt = lastForkAt
        self.openPRs = openPRs
        self.stars = stars
        self.forks = forks
    }

    public var isBaseline: Bool { lastStarAt == nil && lastForkAt == nil && openPRs.isEmpty }
}

/// What arrived since the snapshot.
///
/// The logins are what the page could name; the counts are how many arrived.
/// They differ when more arrived than the page holds — the celebration says
/// "+25" and names the ten it can.
public struct GitHubEvents: Sendable, Equatable {
    /// Logins, newest first.
    public var newStars: [String] = []
    public var newForks: [String] = []
    /// Newest first, by number.
    public var newPRs: [OpenPR] = []
    /// At least `newStars.count`.
    public var newStarCount = 0
    /// At least `newForks.count`.
    public var newForkCount = 0

    public init() {}

    /// Counts, not only logins: a burst the page could not name is still an
    /// event.
    public var isEmpty: Bool {
        newStarCount == 0 && newForkCount == 0
            && newStars.isEmpty && newForks.isEmpty && newPRs.isEmpty
    }
}

/// Finds new stars, forks and PRs by identity, not by count delta.
///
/// A delta hides an unstar-and-star, or a PR opened while another merged,
/// inside one interval; a timestamp newer than the last seen, or a PR number
/// not seen before, does not. The totals only widen a count the page already
/// found (see `count(pageNew:total:previous:)`).
public enum GitHubEventDetector {
    /// First call (snapshot nil) returns no events and the baseline: whatever
    /// the repository already has is not news to a tile just added.
    public static func detect(_ state: GitHubRepoState, since snapshot: GitHubSnapshot?)
        -> (events: GitHubEvents, snapshot: GitHubSnapshot)
    {
        let newestStar = state.stargazers.map(\.starredAt).max()
        let newestFork = state.forkEvents.map(\.createdAt).max()
        let current = Set(state.openPRNumbers.map(\.number))

        guard let snapshot else {
            return (
                GitHubEvents(),
                GitHubSnapshot(
                    lastStarAt: newestStar, lastForkAt: newestFork, openPRs: current,
                    stars: state.stars, forks: state.forks
                )
            )
        }

        let stars = state.stargazers
            .filter { isNewer($0.starredAt, than: snapshot.lastStarAt) }
            .sorted { $0.starredAt > $1.starredAt }
        let forks = state.forkEvents
            .filter { isNewer($0.createdAt, than: snapshot.lastForkAt) }
            .sorted { $0.createdAt > $1.createdAt }

        var events = GitHubEvents()
        events.newStars = stars.map(\.login)
        events.newForks = forks.map(\.login)
        events.newPRs = state.openPRNumbers
            .filter { !snapshot.openPRs.contains($0.number) }
            .sorted { $0.number > $1.number }
        events.newStarCount = count(pageNew: stars.count, total: state.stars, previous: snapshot.stars)
        events.newForkCount = count(pageNew: forks.count, total: state.forks, previous: snapshot.forks)

        // Advances only: when every newer star was withdrawn, the page's
        // newest is older than the last seen, and moving back would make an
        // old star new again at the next read.
        let next = GitHubSnapshot(
            lastStarAt: latest(snapshot.lastStarAt, newestStar),
            lastForkAt: latest(snapshot.lastForkAt, newestFork),
            openPRs: current,
            stars: state.stars, forks: state.forks
        )
        return (events, next)
    }

    /// How many arrived: what the page found, widened by the total's rise when
    /// the previous total is known.
    ///
    /// The page is the query's newest 20, so 25 stars in one interval show 20
    /// (or fewer) newer timestamps while the total rose by 25 — the rise is
    /// the truer count. The other way round, unstars pull the total down, so a
    /// fall (or a rise smaller than the page's find) never lowers what the page
    /// saw, and the result is never negative. Without a previous total (an
    /// older snapshot) the page is all there is.
    static func count(pageNew: Int, total: Int, previous: Int?) -> Int {
        guard let previous else { return pageNew }
        return max(pageNew, total - previous, 0)
    }

    /// Strictly newer: an equal timestamp is the one already seen.
    private static func isNewer(_ date: Date, than last: Date?) -> Bool {
        guard let last else { return true }
        return date > last
    }

    private static func latest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): max(a, b)
        case let (a?, nil): a
        case let (nil, b): b
        }
    }
}

/// Where each tile's snapshot is kept between reads and launches.
public protocol GitHubSnapshotStoring: Sendable {
    func snapshot(for tile: TileKey) -> GitHubSnapshot?
    func save(_ snapshot: GitHubSnapshot, for tile: TileKey)
}

/// One JSON-encoded snapshot per tile in `UserDefaults`, beside the tile
/// records.
///
/// No lock, for the reason `UserDefaultsBorrowedOverlayStore` has none: `save`
/// writes the whole value, and `UserDefaults` is safe for that on its own.
public struct UserDefaultsGitHubSnapshots: GitHubSnapshotStoring, @unchecked Sendable {
    /// Per tile and per clock: the same repository on two clocks is two tiles,
    /// each celebrating on its own clock.
    public static func key(for tile: TileKey) -> String {
        "githubSnapshot.\(tile.tileId).\(tile.clockId.uuidString)"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func snapshot(for tile: TileKey) -> GitHubSnapshot? {
        guard let data = defaults.data(forKey: Self.key(for: tile)) else { return nil }
        // An unreadable snapshot is no snapshot: the next read is a baseline,
        // which celebrates nothing rather than everything.
        return try? JSONDecoder().decode(GitHubSnapshot.self, from: data)
    }

    public func save(_ snapshot: GitHubSnapshot, for tile: TileKey) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.key(for: tile))
    }
}
