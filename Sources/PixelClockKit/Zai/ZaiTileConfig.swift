// Sources/PixelClockKit/Zai/ZaiTileConfig.swift
import Foundation

/// What the z.ai tile needs that no other tile does: where its key lives.
///
/// A HANDLE, and the distinction is the whole point of the type: the API key
/// itself is stored in the login keychain under the account this names, so
/// the tiles JSON in UserDefaults never holds the secret — a defaults dump
/// cannot leak what it never carried.
public struct ZaiTileConfig: Equatable, Sendable, Codable {
    /// The keychain account the tile's key is filed under, as `account(for:)`
    /// derived it.
    public let keyAccount: String

    public init(keyAccount: String) {
        self.keyAccount = keyAccount
    }

    /// The one account a z.ai tile on this clock can have. A `.single`
    /// connector sits on a clock once, so clock plus connector is the whole
    /// tile; the handle is derived rather than minted, which is what makes the
    /// derivation usable before the tile's config has ever been saved.
    public static func account(for key: TileKey) -> String {
        "\(key.clockId.uuidString).\(key.connectorId)"
    }
}
