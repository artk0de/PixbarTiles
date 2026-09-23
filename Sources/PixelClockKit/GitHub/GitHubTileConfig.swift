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

    /// The lengths the settings offer.
    public static let celebrationChoices = [5, 8, 10, 15]

    public init(repo: String, shortName: String? = nil, celebrationSeconds: Int = 8) {
        self.repo = repo
        self.shortName = shortName
        self.celebrationSeconds = celebrationSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case repo, shortName, celebrationSeconds
    }

    /// A record written without a celebration length reads the default, so a
    /// setting added later never makes an older record undecodable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repo = try container.decode(String.self, forKey: .repo)
        shortName = try container.decodeIfPresent(String.self, forKey: .shortName)
        celebrationSeconds = try container.decodeIfPresent(Int.self, forKey: .celebrationSeconds) ?? 8
    }
}
