import Foundation

public enum SpeechError: Error, Sendable {
    case sidecarUnavailable(String)
    case synthesisFailed(String)
}

/// Turns voiced text into audio files, in order.
///
/// The namespace scopes one batch's output away from every other batch's. It is
/// the only signature on purpose: an un-namespaced overload beside it would
/// leave the footgun exactly where it was, and the next caller reaching for the
/// shorter one would silently overwrite another anecdote's clips.
public protocol SpeechSynthesizing: Sendable {
    func synthesize(_ turns: [VoicedTurn], namespace: String) async throws -> [URL]
}

/// Produces placeholder file references. Lets everything above this line run
/// without a Python environment or a 1.8 GB model on disk.
///
/// A class rather than a struct on purpose: a test hands the same instance to a
/// connector and afterwards reads back what the connector asked for.
public final class StubSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [VoicedTurn] = []
    private var recordedNamespaces: [String] = []

    /// Every turn handed to `synthesize`, in call order.
    public var received: [VoicedTurn] {
        lock.withLock { recorded }
    }

    /// One entry per `synthesize` call, in call order.
    public var namespaces: [String] {
        lock.withLock { recordedNamespaces }
    }

    public init() {}

    public func synthesize(_ turns: [VoicedTurn], namespace: String) async throws -> [URL] {
        lock.withLock {
            recorded.append(contentsOf: turns)
            recordedNamespaces.append(namespace)
        }

        // The namespace reaches the returned paths. A double that ignored it
        // would reproduce the collision the namespace exists to prevent, and no
        // test above this line could ever catch the regression.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(namespace)
        return turns.indices.map { directory.appendingPathComponent("stub-turn-\($0).wav") }
    }
}
