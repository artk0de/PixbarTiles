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
    /// The highest PR number ever seen. Numbers are monotonic per repository,
    /// so a freshly opened PR is always above it — which is what tells it
    /// apart from an older open PR sliding into the query's `last: 20` page
    /// when a newer one closes. Optional so an older snapshot still decodes;
    /// the detector then falls back to the set for one read.
    public var lastPRNumber: Int?
    /// The totals at the last read. They exist for one case the timestamps
    /// cannot see: more stars (or forks) arriving between two reads than the
    /// query's `last: 20` page holds. Optional so a snapshot encoded before
    /// they were remembered still decodes — the detector then falls back to
    /// what the page shows.
    public var stars: Int?
    public var forks: Int?
    /// The last default-branch head commit seen failing. A failure is news
    /// once per commit: a later read, a relaunch, or a re-run failing the
    /// same commit again finds it here. Kept through green reads for that
    /// last reason; optional so an older snapshot still decodes.
    public var lastFailedOid: String?
    /// True when the last read could not see who starred (the token was
    /// refused the stargazers): `lastStarAt` then says nothing about the
    /// stars since, and the first read that sees them again names only the
    /// total's rise instead of the whole page. Nil otherwise.
    public var starsUnnamed: Bool?

    public init(
        lastStarAt: Date?, lastForkAt: Date?, openPRs: Set<Int>,
        stars: Int? = nil, forks: Int? = nil, lastPRNumber: Int? = nil, lastFailedOid: String? = nil,
        starsUnnamed: Bool? = nil
    ) {
        self.lastStarAt = lastStarAt
        self.lastForkAt = lastForkAt
        self.openPRs = openPRs
        self.lastPRNumber = lastPRNumber
        self.stars = stars
        self.forks = forks
        self.lastFailedOid = lastFailedOid
        self.starsUnnamed = starsUnnamed
    }

    public var isBaseline: Bool { lastStarAt == nil && lastForkAt == nil && openPRs.isEmpty }
}

/// The default branch's head commit failing its checks, as a celebration
/// names it.
public struct GitHubCIFailure: Sendable, Equatable {
    public var branch: String
    /// The commit author's login, nil when the commit is linked to no account.
    public var author: String?
    public var oid: String

    public init(branch: String, author: String?, oid: String) {
        self.branch = branch
        self.author = author
        self.oid = oid
    }
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
    /// The default branch's head commit newly seen failing.
    public var ciFailure: GitHubCIFailure?

    public init() {}

    /// The events the tile's Notify toggles let through; the rest are
    /// dropped here, before either face sees them.
    public func notifying(_ config: GitHubTileConfig) -> GitHubEvents {
        var kept = self
        if !config.notifyStars {
            kept.newStars = []
            kept.newStarCount = 0
        }
        if !config.notifyForks {
            kept.newForks = []
            kept.newForkCount = 0
        }
        if !config.notifyPRs { kept.newPRs = [] }
        if !config.notifyCI { kept.ciFailure = nil }
        return kept
    }

    /// Counts, not only logins: a burst the page could not name is still an
    /// event.
    public var isEmpty: Bool {
        newStarCount == 0 && newForkCount == 0
            && newStars.isEmpty && newForks.isEmpty && newPRs.isEmpty
            && ciFailure == nil
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
        let highestPR = current.max()
        // The head commit failing now, if it is; a baseline records it
        // without celebrating, like the stars already there.
        let failing = state.ci.flatMap { $0.state == .failure ? $0 : nil }
        // What GitHub withheld reads empty, and empty is not data: withheld
        // counts do not move the totals, withheld PRs do not move the set.
        let starsUnnamed: Bool? = state.stargazersRefused ? true : nil
        let countsWithheld = state.withheld.contains(.metadata)
        let prsWithheld = state.withheld.contains(.pullRequests)

        guard let snapshot else {
            return (
                GitHubEvents(),
                GitHubSnapshot(
                    lastStarAt: newestStar, lastForkAt: newestFork, openPRs: prsWithheld ? [] : current,
                    stars: countsWithheld ? nil : state.stars, forks: countsWithheld ? nil : state.forks,
                    lastPRNumber: highestPR, lastFailedOid: failing?.headOid, starsUnnamed: starsUnnamed
                )
            )
        }
        let previousStars = countsWithheld ? nil : snapshot.stars
        let previousForks = countsWithheld ? nil : snapshot.forks

        var stars = state.stargazers
            .filter { isNewer($0.starredAt, than: snapshot.lastStarAt) }
            .sorted { $0.starredAt > $1.starredAt }
        // The first read to see who starred after reads that could not: the
        // page's timestamps have nothing to be compared against, so only the
        // total's rise since the last read is news, named from the newest.
        if snapshot.starsUnnamed == true, !state.stargazersRefused {
            let rise = previousStars.map { max(0, state.stars - $0) } ?? 0
            stars = Array(stars.prefix(rise))
        }
        let forks = state.forkEvents
            .filter { isNewer($0.createdAt, than: snapshot.lastForkAt) }
            .sorted { $0.createdAt > $1.createdAt }

        var events = GitHubEvents()
        events.newStars = stars.map(\.login)
        events.newForks = forks.map(\.login)
        events.newPRs = prsWithheld ? [] : state.openPRNumbers
            .filter { isNewPR($0.number, in: snapshot) }
            .sorted { $0.number > $1.number }
        events.newStarCount = count(pageNew: stars.count, total: state.stars, previous: previousStars)
        events.newForkCount = count(pageNew: forks.count, total: state.forks, previous: previousForks)
        // By commit, not by transition: pending → failure on one commit is
        // one event, and the same failing commit read again is none.
        if let failing, failing.headOid != snapshot.lastFailedOid {
            events.ciFailure = GitHubCIFailure(branch: failing.branch, author: failing.author, oid: failing.headOid)
        }

        // Advances only: when every newer star was withdrawn, the page's
        // newest is older than the last seen, and moving back would make an
        // old star new again at the next read.
        let next = GitHubSnapshot(
            lastStarAt: latest(snapshot.lastStarAt, newestStar),
            lastForkAt: latest(snapshot.lastForkAt, newestFork),
            openPRs: prsWithheld ? snapshot.openPRs : current,
            stars: countsWithheld ? snapshot.stars : state.stars,
            forks: countsWithheld ? snapshot.forks : state.forks,
            lastPRNumber: [snapshot.lastPRNumber, highestPR].compactMap { $0 }.max(),
            lastFailedOid: failing?.headOid ?? snapshot.lastFailedOid,
            starsUnnamed: starsUnnamed
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

    /// Not in the last read's set, AND above the highest number ever seen.
    /// The set alone misfires past 20 open PRs: the page is the newest 20, so
    /// merging a recent one slides an older, long-open PR into it, absent
    /// from the set yet not new. Numbers only grow, so the bound rules it out.
    /// Without a recorded bound (an older snapshot) the set is all there is.
    private static func isNewPR(_ number: Int, in snapshot: GitHubSnapshot) -> Bool {
        guard !snapshot.openPRs.contains(number) else { return false }
        guard let highest = snapshot.lastPRNumber else { return true }
        return number > highest
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
