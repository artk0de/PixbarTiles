// Sources/PixbarKit/Tiles/TileKind.swift
import Foundation

/// What one kind of tile stores beside its policy: the weather tile's place,
/// the VPN tile's lamp. Stored inside a `TileConfig` under the kind's id.
public protocol TileParameters: Codable, Sendable, Equatable {}

/// The parameters of a kind that has none — the anecdotes tile.
public struct NoParameters: TileParameters {
    public init() {}
}

/// One kind of tile, as the kit knows it: its id, how it presents, which
/// clocks it has a face for, how many of it a clock may carry, and whether it
/// speaks. Every fact the catalogue used to answer from a switch on the
/// connector id lives here, so a new tile is a new kind and one line in
/// `TileKinds.all`.
public protocol TileKind: Sendable {
    associatedtype Parameters: TileParameters
    /// The connector id its tiles are keyed by.
    static var id: String { get }
    static var presentation: TilePresentation { get }
    /// The models it has a face for.
    static var models: Set<ClockModel> { get }
    static var instancing: Instancing { get }
    static var isAudible: Bool { get }
    /// The name of one tile of this kind beside the kind's own name —
    /// `GitHub (TeaRAGs)` — or nil for a kind a clock carries one of.
    static func secondaryName(of tile: TileRecord, parameters: Parameters?) -> String?
}

extension TileKind {
    public static var instancing: Instancing { .single }
    public static var isAudible: Bool { false }
    public static func secondaryName(of tile: TileRecord, parameters: Parameters?) -> String? { nil }
}

/// Every kind of tile the kit knows, listed once.
public enum TileKinds {
    public static let all: [any TileKind.Type] = [
        WeatherKind.self, ClaudeKind.self, ZaiKind.self, GitHubKind.self, AnecdotesKind.self, VPNKind.self,
    ]

    public static func kind(id: String) -> (any TileKind.Type)? {
        all.first { $0.id == id }
    }
}
