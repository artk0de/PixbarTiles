// Sources/PixbarKit/Tiles/Kinds/GitHubKind.swift
import Foundation

/// A repository's stars, forks and PRs — one tile per repository.
public enum GitHubKind: TileKind {
    public typealias Parameters = GitHubTileConfig
    public static let id = GitHubConnector.connectorId
    public static let presentation = TilePresentation(
        category: .dev, icon: "star", blurb: "A repository's stars, forks and PRs"
    )
    public static let models: Set<ClockModel> = [.awtrix3, .ulanziTC002]
    public static let instancing = Instancing.perKey

    /// Its short name, else its repository's name as typed (the instance
    /// lowercases it).
    public static func secondaryName(of tile: TileRecord, parameters: GitHubTileConfig?) -> String? {
        if let short = parameters?.shortName?.trimmingCharacters(in: .whitespaces), !short.isEmpty {
            return short
        }
        let repo = parameters?.repo ?? tile.key.instance
        let name = repo.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }
}

extension GitHubTileConfig: TileParameters {}
