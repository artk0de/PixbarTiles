import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

// The shared usage face's two settings — "Show reset every", "Show reset
// after" — as the tile settings window writes them: on the Claude tile and on
// the z.ai tile alike, into the tile's own record, beside whatever else that
// record already says. A picker that saved its own field and dropped the
// neighbour's would be the window undoing the user's last choice.

private let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.7")
private let tuned = CodeUsage.Parameters(resetEvery: 30, resetAfter: 65)

/// Answers one fixed reading; the preview is drawn from it, never from a file.
private struct FixedClaude: ClaudeUsageReporting {
    let reading: ClaudeUsageReading?
    func read() async throws -> ClaudeUsageReading? { reading }
}

@MainActor
private func model(
    tiles: [TileRecord], connectors: [any Connector] = [StubConnector()],
    secrets: any SecretStoring = MemorySecretStore()
) -> AppModel {
    testModel(connectors: connectors, clocks: [kitchen], tiles: tiles, secrets: secrets)
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
            model(tiles: [tile("claude", config: .claude(ClaudeTileConfig()))]), claudeKey
        )
        #expect(subject.parameters == .standard)
    }

    // A tile that does not draw the usage face has no such pickers at all.
    @Test func aTileWithoutTheUsageFaceHasNoUsageSettings() async {
        let subject = await opened(model(tiles: [tile("stub")]), TileKey(
            clockId: kitchen.id, connectorId: "stub"
        ))
        #expect(subject.parameters == nil)
    }

    @Test func tuningAClaudeTileWritesItsParameters() async {
        let app = model(tiles: [tile("claude", config: .claude(ClaudeTileConfig()))])
        let subject = await opened(app, claudeKey)

        subject.setParameters(tuned)

        #expect(app.storedTile(claudeKey)?.config?.parameters == tuned)
        #expect(subject.parameters == tuned)
    }

    // The two tiles take the SAME parameters, so tuning them is one act
    // through one control — what a vendor's record keeps of its own is the
    // way in, and nothing else.
    @Test func tuningEitherVendorsTileGoesThroughOneControl() async {
        let app = model(tiles: [
            tile("claude", config: .claude(ClaudeTileConfig())),
            tile("zai"),
        ])

        let claude = await opened(app, claudeKey)
        claude.setParameters(tuned)
        let zai = await opened(app, zaiKey)
        zai.setParameters(tuned)

        #expect(app.storedTile(claudeKey)?.config?.parameters == tuned)
        #expect(app.storedTile(zaiKey)?.config?.parameters == tuned)
    }

    // A z.ai tile with no key yet has no config; tuning it writes the handle
    // its key WILL live under (derived, never minted) beside the settings.
    @Test func aZaiTileWithoutAKeyCanBeTuned() async {
        let app = model(tiles: [tile("zai")])
        let subject = await opened(app, zaiKey)

        subject.setParameters(tuned)

        #expect(app.storedTile(zaiKey)?.config?.key == ZaiTileConfig(
            keyAccount: ZaiTileConfig.account(for: zaiKey), parameters: tuned
        ))
    }

    // And a key pasted afterwards joins the record without resetting them.
    @Test func aKeyPastedLaterKeepsTheZaiTilesSettings() async {
        let app = model(tiles: [
            tile("zai", config: .zai(ZaiTileConfig(
                keyAccount: ZaiTileConfig.account(for: zaiKey), parameters: tuned
            ))),
        ])

        app.saveZaiKey("sk-paste", for: zaiKey)

        #expect(app.storedTile(zaiKey)?.config?.parameters == tuned)
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
            reporter: FixedClaude(reading: reading), parameters: { tuned }
        )
        let app = model(tiles: [tile("claude", config: .claude(ClaudeTileConfig()))], connectors: [connector])
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
