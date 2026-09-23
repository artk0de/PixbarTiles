import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The shared usage face's two settings — "Show reset every", "Show reset
// after" — as the tile settings window writes them: on the Claude tile and on
// the z.ai tile alike, into the tile's own record, beside whatever else that
// record already says. A picker that saved its own field and dropped the
// neighbour's would be the window undoing the user's last choice.

private let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.7")
private let tuned = UsageFaceConfig(resetEvery: 30, resetAfter: 65)

/// Answers one fixed reading; the preview is drawn from it, never from a file.
private struct FixedClaude: ClaudeUsageReporting {
    let reading: ClaudeUsageReading?
    func read() async throws -> ClaudeUsageReading? { reading }
}

@MainActor
private func model(
    tiles: [TileRecord], connectors: [any Connector] = [StubConnector()],
    keychain: any TileKeyStoring = MemoryKeychainStore()
) -> AppModel {
    testModel(connectors: connectors, clocks: [kitchen], tiles: tiles, keychain: keychain)
}

private func tile(_ connectorId: String, config: TileConfig? = nil) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: kitchen.id, connectorId: connectorId),
        policy: TilePolicyRecord(isPaused: false, refreshSeconds: 300),
        config: config
    )
}

@MainActor
private func opened(_ model: AppModel, _ key: TileKey) async -> TileSettingsModel {
    let subject = TileSettingsModel(model: model, debounce: 0)
    model.openDetail(for: key)
    _ = await waitUntil { subject.key == key }
    return subject
}

@MainActor
@Suite struct UsageFaceSettingsTests {
    private let claudeKey = TileKey(clockId: kitchen.id, connectorId: ClaudeUsageConnector.id)
    private let zaiKey = TileKey(clockId: kitchen.id, connectorId: ZaiUsageConnector.connectorId)

    // A tile nobody has tuned shows the defaults in its pickers — the
    // record from before the settings existed included.
    @Test func anUntunedUsageTileShowsTheDefaults() async {
        let subject = await opened(
            model(tiles: [tile("claude", config: .claude(.daily))]), claudeKey
        )
        #expect(subject.usageFace == .standard)
    }

    // A tile that does not draw the usage face has no such pickers at all.
    @Test func aTileWithoutTheUsageFaceHasNoUsageSettings() async {
        let subject = await opened(model(tiles: [tile("stub")]), TileKey(
            clockId: kitchen.id, connectorId: "stub"
        ))
        #expect(subject.usageFace == nil)
    }

    @Test func theClaudeTileKeepsItsMetricWhenTheUsageFaceIsTuned() async {
        let app = model(tiles: [tile("claude", config: .claude(.daily))])
        let subject = await opened(app, claudeKey)

        subject.setUsageFace(tuned)

        #expect(app.storedTile(claudeKey)?.config?.usageFace == tuned)
        #expect(app.storedTile(claudeKey)?.config?.claude == .daily)
        #expect(subject.usageFace == tuned)
    }

    @Test func theClaudeTileKeepsItsUsageFaceWhenTheMetricMoves() async {
        let app = model(tiles: [
            tile("claude", config: .claude(ClaudeTileConfig(metric: .daily, usageFace: tuned))),
        ])
        let subject = await opened(app, claudeKey)

        subject.setClaudeMetric(.session)

        #expect(app.storedTile(claudeKey)?.config?.claude == .session)
        #expect(app.storedTile(claudeKey)?.config?.usageFace == tuned)
    }

    // A z.ai tile with no key yet has no config; tuning it writes the handle
    // its key WILL live under (derived, never minted) beside the settings.
    @Test func aZaiTileWithoutAKeyCanBeTuned() async {
        let app = model(tiles: [tile("zai")])
        let subject = await opened(app, zaiKey)

        subject.setUsageFace(tuned)

        #expect(app.storedTile(zaiKey)?.config?.key == ZaiTileConfig(
            keyAccount: ZaiTileConfig.account(for: zaiKey), usageFace: tuned
        ))
    }

    // And a key pasted afterwards joins the record without resetting them.
    @Test func aKeyPastedLaterKeepsTheZaiTilesSettings() async {
        let app = model(tiles: [
            tile("zai", config: .zai(ZaiTileConfig(
                keyAccount: ZaiTileConfig.account(for: zaiKey), usageFace: tuned
            ))),
        ])

        app.saveZaiKey("sk-paste", for: zaiKey)

        #expect(app.storedTile(zaiKey)?.config?.usageFace == tuned)
    }

    // The preview is the real face: the very GIF the clock would be sent,
    // every frame and its own delay — here a hot session row, so two frames.
    @Test func theTC002PreviewIsTheFacesOwnGif() async throws {
        let reading = ClaudeUsageReading(
            utilization: 41, resetsAt: nil,
            fiveHour: ClaudeUsageWindow(
                utilization: 91, resetsAt: Date(timeIntervalSince1970: 1_790_240_700)
            )
        )
        let connector = ClaudeUsageConnector(
            reporter: FixedClaude(reading: reading), usageFace: { tuned }
        )
        let app = model(tiles: [tile("claude", config: .claude(.weekly))], connectors: [connector])
        let subject = await opened(app, claudeKey)

        #expect(await waitUntil { subject.preview != nil })

        let sent = try #require(connector.ulanziFace?.draw(reading).scene.frames.first?.image.first)
        #expect(subject.preview == Data(base64Encoded: sent.base64))
        let preview = try #require(subject.preview)
        let frames = try #require(PixelPreviewFrames(gif: preview))
        #expect(frames.images.count == 2)
        #expect(frames.delays.count == 2)
        #expect(abs(frames.delays[0] - 30) < 0.001)
        #expect(abs(frames.delays[1] - 5) < 0.001)
    }
}
