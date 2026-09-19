// Sources/PixelClockKit/Tiles/TilePolicyRecord+Policy.swift
import Foundation

extension TilePolicy {
    /// What a stored record means, with anything it does not say taken from
    /// the connector's defaults row.
    ///
    /// A record written before Phase 4 carries only `isPaused` and
    /// `refreshSeconds`. Its Focus rule and hours are the ones every tile of
    /// its connector had until then, which is what the defaults row says, so
    /// reading the absent keys as the row changes nothing the user chose.
    public init(_ record: TilePolicyRecord, defaults: TilePolicy) {
        self.init(
            isPaused: record.isPaused,
            refreshSeconds: record.refreshSeconds,
            focus: record.focus ?? defaults.focus,
            window: record.window ?? defaults.window
        )
    }
}

extension TilePolicyRecord {
    /// Everything the policy says, written out. From Phase 4 on a saved record
    /// never leans on a default, so a defaults row changed later moves new
    /// tiles and never one the user already has.
    public init(_ policy: TilePolicy) {
        self.init(
            isPaused: policy.isPaused,
            refreshSeconds: policy.refreshSeconds,
            focus: policy.focus,
            window: policy.window
        )
    }
}
