// Sources/PixelClockKit/Tiles/TileCatalogue.swift
import Foundation

/// How many tiles of one connector a clock may carry.
public enum Instancing: Sendable, Equatable {
    /// One. Every scene connector is this.
    case single
    /// One per key — the VPN tile, one per watched VPN.
    case perKey
}

/// A connector as the Add tile menu needs to see it: no reading, no faces,
/// just what decides whether it may go on a clock.
public struct TileCandidate: Equatable, Sendable {
    public let connectorId: String
    /// The models it has a face for — which is the only thing that says what
    /// it supports, so the two cannot disagree.
    public let models: Set<ClockModel>
    public let instancing: Instancing
    public let isAudible: Bool

    public init(
        connectorId: String, models: Set<ClockModel>, instancing: Instancing, isAudible: Bool
    ) {
        self.connectorId = connectorId
        self.models = models
        self.instancing = instancing
        self.isAudible = isAudible
    }

    /// A scene connector. Every one has an AWTRIX face; the TC002 face arrives
    /// with Phase 3b's `UlanziFace`, and inserts `.ulanziTC002` there.
    public init(_ connector: some Connector) {
        self.init(
            connectorId: connector.id,
            models: [.awtrix3],
            instancing: .single,
            isAudible: connector.isAudible
        )
    }

    /// The VPN tile: a lamp on an AWTRIX clock, one per watched VPN, silent.
    public init(_ vpn: VPNConnector) {
        self.init(
            connectorId: vpn.id, models: [.awtrix3], instancing: .perKey, isAudible: false
        )
    }
}

public enum TileAvailability: Equatable, Sendable {
    case available
    /// Listed, disabled, with the reason beside it.
    case unavailable(String)
    /// Not listed at all — a single tile of it is already on this clock.
    case notListed
}

/// Which connectors the Add tile menu offers for a clock, and why not.
public enum TileCatalogue {
    /// Asked of the tiles as they are now, never stamped when a tile was made,
    /// so a tile removed from the kitchen frees its connector for the desk.
    ///
    /// The rules in the design's order. The face comes first because it is
    /// about the connector and the model and nothing placed anywhere: an
    /// unsupported connector says so whatever else is true.
    public static func availability(
        of candidate: TileCandidate,
        on clock: ClockRecord,
        tiles: [TileRecord],
        clocks: [ClockRecord]
    ) -> TileAvailability {
        guard candidate.models.contains(clock.model) else {
            return .unavailable("not supported on \(modelName(clock.model))")
        }
        let placed = tiles.filter { $0.key.connectorId == candidate.connectorId }
        if candidate.instancing == .single, placed.contains(where: { $0.key.clockId == clock.id }) {
            return .notListed
        }
        // Every audible connector plays through the Mac's speakers today, so
        // one on any other clock is already the voice in this room. A clock
        // that gains a speaker of its own (follow-up F1) changes this rule to
        // "whose sound plays through the Mac", not the rule's place here.
        if candidate.isAudible,
            let elsewhere = placed.first(where: { $0.key.clockId != clock.id }) {
            let name = clocks.first { $0.id == elsewhere.key.clockId }?.name ?? "another clock"
            return .unavailable("already speaking through \(name)")
        }
        return .available
    }

    private static func modelName(_ model: ClockModel) -> String {
        switch model {
        case .awtrix3: "AWTRIX 3"
        case .ulanziTC002: "TC002"
        }
    }
}
