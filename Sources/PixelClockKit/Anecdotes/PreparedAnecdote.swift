import Foundation

/// An anecdote whose audio already exists on disk, waiting for its turn.
public struct PreparedAnecdote: Sendable, Codable, Equatable {
    public let id: String
    public let text: String
    public let clips: [SpokenClip]
    public let laughter: String
    /// When this was prepared, or nil for a record written before the field
    /// existed.
    ///
    /// Optional on purpose, and the reason is the same one `AnecdoteQueue.Store`
    /// spells out: this type is decoded from a file the user's previous launch
    /// wrote, and Swift's synthesised `init(from:)` throws on a missing key for
    /// a non-optional property. An `Optional` one is read with
    /// `decodeIfPresent` instead, so absent decodes as absent rather than
    /// taking the whole batch — and the played set with it — down.
    ///
    /// Absent is not "just now". The queue reads it as a generation before
    /// today's, so a record that predates the field plays last rather than
    /// first, and the reaper falls back to the age of the clips on disk.
    public let preparedAt: Date?
    /// Where this sat in the feed it came from, or nil for a record written
    /// before the field existed. Lower is more popular; absent is worst.
    public let rank: Int?

    /// Whether the audio this anecdote promises is still on disk.
    ///
    /// A prepared batch outlives the run that made it, but its clips live in
    /// the temporary directory and the queue's reaper removes them once they
    /// have outlived its retention window. Handing out an anecdote whose files
    /// are gone would put a banner on the clock with `holdUntilAudioEnds` set
    /// and no audio to end it.
    ///
    /// An anecdote with no clips at all fails this for the same reason.
    public var isPlayable: Bool {
        !clips.isEmpty && clips.allSatisfy {
            FileManager.default.fileExists(atPath: $0.url.path)
        }
    }

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

    /// Neither new field is defaulted, and that is deliberate: both are sort
    /// keys, and a call site that forgot one would silently mint an anecdote
    /// that plays last for ever. Saying `nil` is a decision; omitting it is not.
    public init(
        id: String,
        text: String,
        clips: [SpokenClip],
        laughter: String,
        preparedAt: Date?,
        rank: Int?
    ) {
        self.id = id
        self.text = text
        self.clips = clips
        self.laughter = laughter
        self.preparedAt = preparedAt
        self.rank = rank
    }
}

/// An anecdote that has been played, and when.
///
/// The whole anecdote rather than its id, because what this record is for is
/// playing it again: the clips are the point, and an id would only name a
/// pending entry that has already been popped.
///
/// The moment is what makes the record expire. Clips are large and the
/// temporary directory is not endless, so a played anecdote is kept for a
/// window and then reclaimed — `playedAt` is the only thing that says which
/// side of that window it is on.
public struct PlayedAnecdote: Sendable, Codable, Equatable {
    public let anecdote: PreparedAnecdote
    public let playedAt: Date

    public init(anecdote: PreparedAnecdote, playedAt: Date) {
        self.anecdote = anecdote
        self.playedAt = playedAt
    }
}
