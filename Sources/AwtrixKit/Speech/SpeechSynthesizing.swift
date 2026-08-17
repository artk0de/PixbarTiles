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

    /// Where this instance's namespaced directories are written.
    ///
    /// Per instance rather than the bare temporary directory: two tests using
    /// the same feed derive the same namespace, and one of them deleting a
    /// directory to stage a missing-audio case would reach into the other.
    public let root: URL

    /// Every turn handed to `synthesize`, in call order.
    public var received: [VoicedTurn] {
        lock.withLock { recorded }
    }

    /// One entry per `synthesize` call, in call order.
    public var namespaces: [String] {
        lock.withLock { recordedNamespaces }
    }

    public init() {
        self.root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stub-speech-\(UUID().uuidString)")
    }

    public func synthesize(_ turns: [VoicedTurn], namespace: String) async throws -> [URL] {
        lock.withLock {
            recorded.append(contentsOf: turns)
            recordedNamespaces.append(namespace)
        }

        // The namespace reaches the returned paths. A double that ignored it
        // would reproduce the collision the namespace exists to prevent, and no
        // test above this line could ever catch the regression.
        let directory = root.appendingPathComponent(namespace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return try turns.indices.map { index in
            let url = directory.appendingPathComponent("stub-turn-\(index).wav")
            // An empty file rather than none. A caller that checks whether the
            // audio it was promised still exists has to get the same answer
            // from the stub as it would from the sidecar.
            try Data().write(to: url)
            return url
        }
    }
}
