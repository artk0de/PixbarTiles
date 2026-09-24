// Tests/PixelClockKitTests/TileSecondaryNameTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// An instanced tile names its instance beside the tile's name — `GitHub
// (TeaRAGs)`, `VPN (Pritunl)`. The kit answers which name, per connector; the
// cards only draw it.

private let clock = UUID()

private func record(_ connectorId: String, instance: String = "", config: TileConfig? = nil) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock, connectorId: connectorId, instance: instance),
        policy: TilePolicyRecord(isPaused: false, refreshSeconds: 60),
        config: config
    )
}

@Suite struct TileSecondaryNameTests {
    @Test func aGitHubTileIsNamedByItsShortName() {
        let config = GitHubTileConfig(repo: "artk0de/TeaRAGs-MCP", shortName: "TeaRAGs")
        #expect(TilePresentation.secondaryName(of: record("github", instance: "artk0de/tearags-mcp", config: .github(config)))
            == "TeaRAGs")
    }

    /// No short name: the repository's name as typed, without its owner.
    @Test func aGitHubTileWithoutAShortNameIsNamedByItsRepo() {
        let config = GitHubTileConfig(repo: "artk0de/TeaRAGs-MCP", shortName: "  ")
        #expect(TilePresentation.secondaryName(of: record("github", instance: "artk0de/tearags-mcp", config: .github(config)))
            == "TeaRAGs-MCP")
        // A record with no config falls back to its instance, as the connector does.
        #expect(TilePresentation.secondaryName(of: record("github", instance: "a/x")) == "x")
        #expect(TilePresentation.secondaryName(of: record("github")) == nil)
    }

    @Test func aVPNTileIsNamedByItsVPN() {
        let lamp = VPNTileConfig(vpn: "pritunl", slot: IndicatorSlot.allCases[0], upColour: "#00FF00", whenDown: .off)
        #expect(TilePresentation.secondaryName(of: record("vpn", instance: "pritunl", config: .vpn(lamp))) == "Pritunl")
        let unknown = VPNTileConfig(vpn: "wireguard-x", slot: IndicatorSlot.allCases[0], upColour: "#00FF00", whenDown: .off)
        #expect(TilePresentation.secondaryName(of: record("vpn", config: .vpn(unknown))) == "wireguard-x")
    }

    /// A single tile has no instance to name.
    @Test func aSingleTileHasNoSecondaryName() {
        for id in ["weather", "claude", "zai", "anecdotes"] {
            #expect(TilePresentation.secondaryName(of: record(id)) == nil, "\(id)")
        }
    }
}
