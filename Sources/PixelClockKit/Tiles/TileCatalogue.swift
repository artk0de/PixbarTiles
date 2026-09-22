// Sources/PixelClockKit/Tiles/TileCatalogue.swift
import Foundation

/// How many tiles of one connector a clock may carry.
public enum Instancing: Sendable, Equatable {
    /// One. Every scene connector is this.
    case single
    /// One per key — the VPN tile, one per watched VPN.
    case perKey
}

/// Where a tile belongs on the store's shelves, as the sidebar names them.
public enum TileCategory: String, CaseIterable, Sendable, Equatable {
    case weather
    case system
    case dev
    case network

    /// The sidebar's word for the shelf.
    public var title: String {
        switch self {
        case .weather: "Weather"
        case .system: "System"
        case .dev: "Dev"
        case .network: "Network"
        }
    }
}

/// A connector as the Add tile menu needs to see it: no reading, no faces,
/// just what decides whether it may go on a clock — and, since the store
/// became its front door, how it presents there: its shelf, its mark, and
/// the one line under its name.
public struct TileCandidate: Hashable, Sendable {
    public let connectorId: String
    /// The models it has a face for — which is the only thing that says what
    /// it supports, so the two cannot disagree.
    public let models: Set<ClockModel>
    public let instancing: Instancing
    public let isAudible: Bool
    /// The shelf the store files it on.
    public let category: TileCategory
    /// The store card's mark, in the app's own dialect of SF Symbols. The
    /// row's mark reads the same table (the app's `TileRowIcon`), so a tile
    /// wears one face everywhere and the tables are the price of the kit
    /// never naming screen marks for the app.
    public let storeIcon: String
    /// The one line under the card's name.
    public let blurb: String

    public init(
        connectorId: String, models: Set<ClockModel>, instancing: Instancing, isAudible: Bool,
        category: TileCategory? = nil, storeIcon: String? = nil, blurb: String? = nil
    ) {
        self.connectorId = connectorId
        self.models = models
        self.instancing = instancing
        self.isAudible = isAudible
        let presentation = Self.presentation(for: connectorId)
        self.category = category ?? presentation.category
        self.storeIcon = storeIcon ?? presentation.icon
        self.blurb = blurb ?? presentation.blurb
    }

    /// A scene connector. The faces it HAS are the models it supports, and
    /// nothing else says so — the AWTRIX face is required, and a connector
    /// carrying a TC002 face carries `.ulanziTC002` with it.
    public init(_ connector: some Connector) {
        var models: Set<ClockModel> = [.awtrix3]
        if connector.ulanziFace != nil {
            models.insert(.ulanziTC002)
        }
        self.init(
            connectorId: connector.id,
            models: models,
            instancing: .single,
            isAudible: connector.isAudible
        )
    }

    /// The VPN tile: a lamp on an AWTRIX clock, one per watched VPN, silent.
    public init(_ vpn: VPNConnector) {
        self.init(
            connectorId: vpn.id, models: [.awtrix3], instancing: .perKey, isAudible: false,
            category: .network, storeIcon: "lock.shield",
            blurb: "A watched VPN, as a lamp on the clock"
        )
    }

    /// The store's presentation, by connector id — one table, because a tile
    /// that moved shelves or changed its line in one surface and not the
    /// others would be two tiles wearing one name.
    private static func presentation(for connectorId: String) -> (
        category: TileCategory, icon: String, blurb: String
    ) {
        switch connectorId {
        case WeatherConnector.appName:
            return (.weather, "cloud.sun", "The sky where the clock is")
        case ClaudeUsageConnector.id:
            return (.dev, "terminal", "Claude usage, from the status line")
        case ZaiUsageConnector.connectorId:
            return (.dev, "chart.bar", "z.ai usage, week to date")
        case "anecdotes":
            return (.system, "text.bubble", "The day's anecdotes, spoken")
        default:
            return (.dev, "app.dashed", "")
        }
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
