import Foundation

/// What one GitHub tile watches and how long it celebrates.
///
/// The token is not here: it is shared by every GitHub tile and lives in the
/// secret store under `SecretAccount.connector("github")`, never in a record.
public struct GitHubTileConfig: Codable, Sendable, Equatable {
    /// `owner/name`.
    public var repo: String
    /// What the face calls the repository instead of its name, or nil for
    /// the name itself.
    public var shortName: String?
    /// How long a new star, fork or PR holds the clock, one of
    /// `celebrationChoices`.
    public var celebrationSeconds: Int = 8
    /// Show: whether the TC002 ticker carries the forks and the open PRs, and
    /// whether the CI badge is drawn. The stars are the hero and always shown.
    public var showForks = true
    public var showPRs = true
    public var showCI = true
    /// Notify: whether each kind of arrival interrupts the clock. Off drops
    /// the event on both models; the snapshot still advances, so turning a
    /// toggle back on replays nothing.
    public var notifyStars = true
    public var notifyForks = true
    public var notifyPRs = true
    public var notifyCI = true
    /// Whether a star celebrates on every page the app owns on a TC002 (on)
    /// or on the tile's own page only, as a fork or a PR does (off). The
    /// TC001 shows every celebration as a notification over whatever is up,
    /// so it has nothing to choose here.
    public var celebrateOnAllPages = true
    /// Which metric holds the hero — always shown, whatever its Show toggle.
    public var mainWatch = GitHubMainWatch.stars

    /// The lengths the settings offer.
    public static let celebrationChoices = [5, 8, 10, 15]

    public init(repo: String, shortName: String? = nil, celebrationSeconds: Int = 8) {
        self.repo = repo
        self.shortName = shortName
        self.celebrationSeconds = celebrationSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case repo, shortName, celebrationSeconds
        case showForks, showPRs, showCI, notifyStars, notifyForks, notifyPRs, notifyCI, mainWatch
        case celebrateOnAllPages
    }

    /// A record written without a setting reads its default, so a setting
    /// added later never makes an older record undecodable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repo = try container.decode(String.self, forKey: .repo)
        shortName = try container.decodeIfPresent(String.self, forKey: .shortName)
        celebrationSeconds = try container.decodeIfPresent(Int.self, forKey: .celebrationSeconds) ?? 8
        func flag(_ key: CodingKeys) throws -> Bool { try container.decodeIfPresent(Bool.self, forKey: key) ?? true }
        showForks = try flag(.showForks)
        showPRs = try flag(.showPRs)
        showCI = try flag(.showCI)
        notifyStars = try flag(.notifyStars)
        notifyForks = try flag(.notifyForks)
        notifyPRs = try flag(.notifyPRs)
        notifyCI = try flag(.notifyCI)
        celebrateOnAllPages = try flag(.celebrateOnAllPages)
        mainWatch = try container.decodeIfPresent(GitHubMainWatch.self, forKey: .mainWatch) ?? .stars
    }
}

/// The Main watch: the metric that holds the hero — ggen's `Config.main`.
public enum GitHubMainWatch: String, Codable, Sendable, CaseIterable {
    case stars, prs, forks, ci

    /// What the settings' picker calls it.
    public var title: String {
        switch self {
        case .stars: "Stars"
        case .prs: "PRs"
        case .forks: "Forks"
        case .ci: "CI"
        }
    }
}
