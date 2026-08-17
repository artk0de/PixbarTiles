import Foundation

public enum SpeechError: Error, Sendable {
    case sidecarUnavailable(String)
    case synthesisFailed(String)
}

/// Turns voiced text into audio files, in order.
public protocol SpeechSynthesizing: Sendable {
    func synthesize(_ turns: [VoicedTurn]) async throws -> [URL]
}

/// Produces placeholder file references. Lets everything above this line run
/// without a Python environment or a 1.8 GB model on disk.
///
/// A class rather than a struct on purpose: a test hands the same instance to a
/// connector and afterwards reads back what the connector asked for.
public final class StubSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [VoicedTurn] = []

    /// Every turn handed to `synthesize`, in call order.
    public var received: [VoicedTurn] {
        lock.withLock { recorded }
    }

    public init() {}

    public func synthesize(_ turns: [VoicedTurn]) async throws -> [URL] {
        lock.withLock { recorded.append(contentsOf: turns) }

        return turns.indices.map {
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("stub-turn-\($0).wav")
        }
    }
}
