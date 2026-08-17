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
@Test func aConnectorFoundInTheRegistryCanBeAskedToProduce() async throws {
    let registry = ConnectorRegistry()
    registry.register(
        FakeConnector(id: "a", displayName: "A", output: ConnectorOutput(text: "produced"))
    )

    let connector = try #require(registry.connector(id: "a"))

    #expect(try await connector.produce().text == "produced")
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

// A batch of clips is prepared in one run and played in a later one, so clips
// are written to disk in between. Both halves have to survive the trip: a file
// that no longer resolves plays nothing, and a lost lead-in loses the timing.
@Test func aClipSurvivesBeingWrittenAndReadBack() throws {
    let clip = SpokenClip(url: URL(fileURLWithPath: "/tmp/turn-0.wav"), leadIn: 0.7)

    let restored = try JSONDecoder().decode(
        SpokenClip.self,
        from: try JSONEncoder().encode(clip)
    )

    #expect(restored == clip)
    #expect(restored.url.path == "/tmp/turn-0.wav")
    #expect(restored.leadIn == 0.7)
}
