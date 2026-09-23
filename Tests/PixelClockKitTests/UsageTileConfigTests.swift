// Tests/PixelClockKitTests/UsageTileConfigTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The usage face's two settings, stored with the tile the way every tile
// setting is: inside the Claude tile's config and the z.ai tile's config, the
// same two fields under the same two names. Records written before the
// settings existed read as the defaults, and nothing rewrites them — a config
// still AT the defaults encodes exactly as it did before, so an untouched
// record is byte-identical across the upgrade.

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func decoded<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(text.utf8))
}

private let account = "8C0D2E7A-6A4B-4E5C-9D1F-2B3A4C5D6E7F.zai"
private let tuned = UsageFaceConfig(resetEvery: 30, resetAfter: 65)

@Suite struct ClaudeTileConfigTests {
    // The Claude tile's config before the settings: the metric's bare word.
    @Test func aRecordFromBeforeTheSettingsReadsAsTheDefaults() throws {
        let config = try decoded(TileConfig.self, #"{"claude":"daily"}"#)

        #expect(config == .claude(ClaudeTileConfig(metric: .daily, usageFace: .standard)))
        #expect(config.claude == .daily)
        #expect(config.usageFace == .standard)
    }

    @Test func aTileAtTheDefaultsStillWritesTheBareWord() throws {
        #expect(try json(TileConfig.claude(.session)) == #"{"claude":"session"}"#)
    }

    @Test func aTunedTileWritesItsSettingsBesideTheMetric() throws {
        let config = TileConfig.claude(ClaudeTileConfig(metric: .weekly, usageFace: tuned))

        #expect(try json(config) == """
        {"claude":{"metric":"weekly","showResetAfter":65,"showResetEvery":30}}
        """)
        #expect(try decoded(TileConfig.self, try json(config)) == config)
        #expect(config.usageFace == tuned)
    }
}

@Suite struct ZaiTileUsageFaceTests {
    @Test func aRecordFromBeforeTheSettingsReadsAsTheDefaults() throws {
        let config = try decoded(TileConfig.self, #"{"zai":{"keyAccount":"\#(account)"}}"#)

        #expect(config.key == ZaiTileConfig(keyAccount: account))
        #expect(config.usageFace == .standard)
    }

    @Test func aTunedTileWritesItsSettingsBesideTheHandle() throws {
        let config = TileConfig.zai(ZaiTileConfig(keyAccount: account, usageFace: tuned))

        #expect(try json(config) == """
        {"zai":{"keyAccount":"\(account)","showResetAfter":65,"showResetEvery":30}}
        """)
        #expect(try decoded(TileConfig.self, try json(config)) == config)
        #expect(config.usageFace == tuned)
    }

    // Only the two usage tiles carry the settings.
    @Test func otherTilesCarryNoUsageFaceSettings() {
        #expect(TileConfig.weather(Coordinates(latitude: 55.7, longitude: 37.6)).usageFace == nil)
    }
}
