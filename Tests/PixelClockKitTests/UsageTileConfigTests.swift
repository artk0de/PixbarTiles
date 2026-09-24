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
private let tuned = CodeUsage.Parameters(resetEvery: 30, resetAfter: 65)

@Suite struct ClaudeTileConfigTests {
    // Every spelling a Claude tile has ever been written in still decodes. A
    // tile that stops decoding is a tile that vanishes from a clock at the
    // update that changed its settings, and the reader is never told why.
    @Test func everyStoredSpellingOfAClaudeTileStillDecodes() throws {
        // Before the parameters existed: the display metric's bare word. The
        // metric is gone — one vendor's setting the other had no counterpart
        // for — so the word carries nothing now, but it must still be READ.
        for word in ["daily", "weekly", "session"] {
            #expect(try decoded(TileConfig.self, #"{"claude":"\#(word)"}"#).parameters == .standard)
        }
        // After the metric, before it was dropped: the word beside the
        // parameters. The parameters survive; the metric is ignored.
        let both = #"{"claude":{"metric":"daily","showResetAfter":65,"showResetEvery":30}}"#
        #expect(try decoded(TileConfig.self, both).parameters == tuned)
        // A record with no parameters chosen.
        #expect(try decoded(TileConfig.self, #"{"claude":{}}"#).parameters == .standard)
    }

    @Test func aTunedTileWritesItsParameters() throws {
        let config = TileConfig.claude(ClaudeTileConfig(parameters: tuned))

        #expect(try json(config) == """
        {"claude":{"showResetAfter":65,"showResetEvery":30}}
        """)
        #expect(try decoded(TileConfig.self, try json(config)) == config)
        #expect(config.parameters == tuned)
    }

    // The two tiles take the SAME parameters — the property the substrate
    // exists to hold. A setting that appears on one and not the other is the
    // drift this asserts against.
    @Test func bothVendorsTilesCarryTheSameParameters() throws {
        let claude = TileConfig.claude(ClaudeTileConfig(parameters: tuned))
        let zai = TileConfig.zai(ZaiTileConfig(keyAccount: account, parameters: tuned))

        #expect(claude.parameters == zai.parameters)
    }
}

// The layout a tile draws, and which windows it draws, are stored with the
// same rule the other two settings follow: a record that never chose one says
// nothing about it, and reads as the default.
@Suite struct CodeUsageParametersTests {
    @Test func aRecordFromBeforeTheLayoutReadsAsCompactShowingBothWindows() throws {
        let stored = try decoded(TileConfig.self, #"{"claude":{"showResetAfter":65,"showResetEvery":30}}"#)

        #expect(stored.parameters?.layout == .compact)
        #expect(stored.parameters?.windows == CodeUsage.WindowKind.allCases)
        #expect(CodeUsage.Parameters.standard.layout == .compact)
        #expect(CodeUsage.Parameters.standard.windows == CodeUsage.WindowKind.allCases)
    }

    // A tile left at the standard layout writes exactly what it wrote before
    // the layout existed — so upgrading the app rewrites no record.
    @Test func aTileLeftAtTheStandardLayoutWritesNoLayoutKey() throws {
        let config = TileConfig.claude(ClaudeTileConfig(parameters: tuned))

        #expect(try json(config).contains("layout") == false)
        #expect(try json(config).contains("windows") == false)
    }

    @Test func aTileMovedToTheCircleWritesTheLayoutAndItsWindows() throws {
        let circle = CodeUsage.Parameters(
            resetEvery: 30, resetAfter: 65, layout: .circle, windows: [.weekly]
        )
        let config = TileConfig.claude(ClaudeTileConfig(parameters: circle))

        #expect(try json(config) == """
        {"claude":{"layout":"circle","showResetAfter":65,"showResetEvery":30,"windows":["weekly"]}}
        """)
        #expect(try decoded(TileConfig.self, try json(config)).parameters == circle)
    }

    // A tile showing no window at all has nothing to draw, so the stored set is
    // never empty: an empty list — hand-edited, or written by a build that let
    // the last checkbox go — reads as both.
    @Test func aRecordThatNamesNoWindowReadsAsBoth() throws {
        let stored = try decoded(
            TileConfig.self, #"{"claude":{"layout":"circle","windows":[]}}"#
        )

        #expect(stored.parameters?.windows == CodeUsage.WindowKind.allCases)
    }

    // The date order is the reader's setting, stored like the rest and, like
    // the rest, silent while it is at its default.
    @Test func aTileWritesItsDateOrderOnlyWhenItIsNotTheDefault() throws {
        #expect(CodeUsage.Parameters.standard.dateOrder == .dayFirst)
        #expect(try json(TileConfig.claude(ClaudeTileConfig(parameters: tuned)))
            .contains("dateOrder") == false)

        var moved = tuned
        moved.dateOrder = .monthFirst
        let config = TileConfig.claude(ClaudeTileConfig(parameters: moved))

        #expect(try json(config) == """
        {"claude":{"dateOrder":"monthFirst","showResetAfter":65,"showResetEvery":30}}
        """)
        #expect(try decoded(TileConfig.self, try json(config)).parameters == moved)
    }

    // The windows are drawn in the order the panel shows them, shortest period
    // first, however the record happens to list them.
    @Test func theWindowsAreOrderedByThePeriodTheyMeasure() throws {
        let stored = try decoded(
            TileConfig.self, #"{"claude":{"windows":["weekly","fiveHour"]}}"#
        )

        #expect(stored.parameters?.windows == [.fiveHour, .weekly])
    }
}

@Suite struct ZaiTileUsageFaceTests {
    @Test func aRecordFromBeforeTheSettingsReadsAsTheDefaults() throws {
        let config = try decoded(TileConfig.self, #"{"zai":{"keyAccount":"\#(account)"}}"#)

        #expect(config.key == ZaiTileConfig(keyAccount: account))
        #expect(config.parameters == .standard)
    }

    @Test func aTunedTileWritesItsSettingsBesideTheHandle() throws {
        let config = TileConfig.zai(ZaiTileConfig(keyAccount: account, parameters: tuned))

        #expect(try json(config) == """
        {"zai":{"keyAccount":"\(account)","showResetAfter":65,"showResetEvery":30}}
        """)
        #expect(try decoded(TileConfig.self, try json(config)) == config)
        #expect(config.parameters == tuned)
    }

    // Only the two usage tiles carry the settings.
    @Test func otherTilesCarryNoUsageFaceSettings() {
        #expect(TileConfig.weather(Coordinates(latitude: 55.7, longitude: 37.6)).parameters == nil)
    }
}
