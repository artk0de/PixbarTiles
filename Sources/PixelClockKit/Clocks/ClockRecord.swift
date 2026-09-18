import Foundation

/// One clock this app drives, as the settings keep it.
public struct ClockRecord: Codable, Sendable, Equatable {
    /// This app's key for the clock. It does not move when the address does,
    /// which is why tiles and custody are keyed by it and not by the address.
    public let id: UUID
    /// What the user calls it. "Clock" for the one a migration found.
    public var name: String
    public var model: ClockModel
    /// A host or an IP, as typed or as a relocation found it.
    public var address: String
    /// What the clock calls itself — AWTRIX `uid`, TC002 `devSn` — or nil
    /// until it has answered once. Relocation looks for this, so a moved
    /// lease is the same clock at a new address rather than a new clock.
    public var hardwareIdentity: String?

    public init(
        id: UUID = UUID(),
        name: String,
        model: ClockModel,
        address: String,
        hardwareIdentity: String? = nil
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.address = address
        self.hardwareIdentity = hardwareIdentity
    }
}
