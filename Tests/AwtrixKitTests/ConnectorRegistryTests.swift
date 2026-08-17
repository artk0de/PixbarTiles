import Foundation
import Testing
@testable import AwtrixKit

private struct FakeConnector: Connector {
    let id: String
    let displayName: String
    let defaultInterval: TimeInterval = 300
    var output = ConnectorOutput(text: "hi")

    func produce() async throws -> ConnectorOutput { output }
}

// MARK: - The registry

@Test func registryReturnsRegisteredConnectorsInOrder() {
    let registry = ConnectorRegistry()
    registry.register(FakeConnector(id: "a", displayName: "A"))
    registry.register(FakeConnector(id: "b", displayName: "B"))

    #expect(registry.all.map(\.id) == ["a", "b"])
}

@Test func registryLooksUpByIdentifier() {
    let registry = ConnectorRegistry()
    registry.register(FakeConnector(id: "anecdotes", displayName: "Anecdotes"))

    #expect(registry.connector(id: "anecdotes")?.displayName == "Anecdotes")
    #expect(registry.connector(id: "missing") == nil)
}

@Test func registeringTheSameIdentifierReplacesRatherThanDuplicates() {
    let registry = ConnectorRegistry()
    registry.register(FakeConnector(id: "a", displayName: "first"))
    registry.register(FakeConnector(id: "a", displayName: "second"))

    #expect(registry.all.count == 1)
    #expect(registry.all.first?.displayName == "second")
}

// Replacing must not reshuffle the menu: the position a connector was first
// registered at is the position it keeps.
@Test func replacingAConnectorKeepsItsOriginalPosition() {
    let registry = ConnectorRegistry()
    registry.register(FakeConnector(id: "a", displayName: "A"))
    registry.register(FakeConnector(id: "b", displayName: "B"))
    registry.register(FakeConnector(id: "a", displayName: "A again"))

    #expect(registry.all.map(\.id) == ["a", "b"])
    #expect(registry.all.first?.displayName == "A again")
}

// The one call the host in Task 11 makes: reach a connector through the
// registry's existential and await it.
// Two connectors, and the one asked is not the one at the head, so the lookup
// half of this has to be right as well as the await half.
@Test func aConnectorFoundInTheRegistryCanBeAskedToProduce() async throws {
    let registry = ConnectorRegistry()
    registry.register(
        FakeConnector(id: "a", displayName: "A", output: ConnectorOutput(text: "first"))
    )
    registry.register(
        FakeConnector(id: "b", displayName: "B", output: ConnectorOutput(text: "second"))
    )

    let connector = try #require(registry.connector(id: "b"))

    #expect(try await connector.produce().text == "second")
}

// `@unchecked Sendable` turns the compiler's check off, so the lock inside the
// registry is the only thing keeping `storage` consistent and nothing else
// would notice if it went away. Task 11's host actor looks connectors up while
// Task 14's `@MainActor` model reads `all`, so two isolation domains really do
// touch this. Hammering it from 200 tasks is what makes the lock's absence
// visible: unsynchronized, appends are lost.
@Test func everyConcurrentRegistrationSurvives() async {
    let registry = ConnectorRegistry()
    let count = 200

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<count {
            group.addTask {
                registry.register(FakeConnector(id: "c\(index)", displayName: "C\(index)"))
            }
            // A reader in the same window: `all` copies the array while the
            // writers above are mutating it.
            group.addTask {
                _ = registry.all.count
            }
        }
    }

    #expect(registry.all.count == count)
    #expect(Set(registry.all.map(\.id)).count == count)
}

// MARK: - The output shape

@Test func outputDefaultsToNoIconNoJingleNoAudio() {
    let output = ConnectorOutput(text: "plain")

    #expect(output.icon == nil)
    #expect(output.jingle == nil)
    #expect(output.localAudio.isEmpty)
}

// The banner holds for a fixed duration unless the producer says otherwise.
// Holding by default would strand a silent connector's text on the clock.
@Test func outputDoesNotHoldForAudioUnlessAsked() {
    #expect(ConnectorOutput(text: "plain").holdUntilAudioEnds == false)
}

// MARK: - The clip shape

// Pacing is opt-in. A clip with no stated lead-in starts the moment the one
// before it ends; the values that space an anecdote out belong to its producer.
@Test func aClipWithoutAStatedLeadInStartsImmediately() {
    let clip = SpokenClip(url: URL(fileURLWithPath: "/tmp/turn-0.wav"))

    #expect(clip.leadIn == 0)
}

// A batch of clips is prepared in one run and played in a later one, which is
// why a clip is encodable at all. Encoding is the part that can silently drop a
// field, so this round-trips in memory rather than through a file: a URL that
// no longer resolves plays nothing, and a lost lead-in loses the timing.
@Test func aClipSurvivesEncodingAndDecoding() throws {
    let clip = SpokenClip(url: URL(fileURLWithPath: "/tmp/turn-0.wav"), leadIn: 0.7)

    let restored = try JSONDecoder().decode(
        SpokenClip.self,
        from: try JSONEncoder().encode(clip)
    )

    #expect(restored == clip)
    #expect(restored.url.path == "/tmp/turn-0.wav")
    #expect(restored.leadIn == 0.7)
}
