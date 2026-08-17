import Foundation

/// An anecdote whose audio already exists on disk, waiting for its turn.
public struct PreparedAnecdote: Sendable, Codable, Equatable {
    public let id: String
    public let text: String
    public let clips: [SpokenClip]
    public let laughter: String

    /// A filename-safe key derived from the feed guid, which contains slashes.
    ///
    /// The tail is kept rather than the head: every anekdot.ru guid opens with
    /// the same host and path, so truncating from the front would collapse the
    /// whole feed onto one name — the exact collision this key exists to stop.
    public static func namespace(for id: String) -> String {
        let sanitized = String(
            id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        )
        return String(sanitized.suffix(48))
    }

    public init(id: String, text: String, clips: [SpokenClip], laughter: String) {
        self.id = id
        self.text = text
        self.clips = clips
        self.laughter = laughter
    }
}
