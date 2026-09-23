// Sources/PixelClockKit/Zai/ZaiTileConfig.swift
import Foundation

/// What the z.ai tile needs that no other tile does: where its key lives.
///
/// A HANDLE, and the distinction is the whole point of the type: the API key
/// itself is stored in the login keychain under the account this names, so
/// the tiles JSON in UserDefaults never holds the secret — a defaults dump
/// cannot leak what it never carried.
///
/// It also carries the two settings of the TC002's shared usage face, beside
/// the handle under their own names. Left out of the JSON while they are the
/// defaults, so a record written before they existed — the handle alone —
/// reads as a tile at the defaults and is never rewritten.
public struct ZaiTileConfig: Equatable, Sendable, Codable {
    /// The keychain account the tile's key is filed under, as `account(for:)`
    /// derived it.
    public let keyAccount: String
    public var usageFace: UsageFaceConfig

    public init(keyAccount: String, usageFace: UsageFaceConfig = .standard) {
        self.keyAccount = keyAccount
        self.usageFace = usageFace
    }

    private enum CodingKeys: String, CodingKey {
        case keyAccount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyAccount = try container.decode(String.self, forKey: .keyAccount)
        usageFace = try UsageFaceConfig(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyAccount, forKey: .keyAccount)
        if usageFace != .standard {
            try usageFace.encode(to: encoder)
        }
    }

    /// The one account a z.ai tile on this clock can have. A `.single`
    /// connector sits on a clock once, so clock plus connector is the whole
    /// tile; the handle is derived rather than minted, which is what makes the
    /// derivation usable before the tile's config has ever been saved.
    public static func account(for key: TileKey) -> String {
        "\(key.clockId.uuidString).\(key.connectorId)"
    }
}
