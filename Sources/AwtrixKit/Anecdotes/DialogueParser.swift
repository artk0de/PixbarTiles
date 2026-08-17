import Foundation

public enum Speaker: Sendable, Equatable, Hashable {
    case narrator
    case actor(Int)
}

public struct Turn: Sendable, Equatable {
    public let speaker: Speaker
    public let text: String

    public init(speaker: Speaker, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

/// Splits an anecdote into speaker turns.
///
/// A dash opens a turn only at the start of a line. Russian prose uses dashes
/// mid-sentence freely, so splitting on any dash shreds ordinary text.
public enum DialogueParser {
    private static let speakerMarkers: Set<Character> = ["-", "—", "–"]

    public static func parse(_ text: String) -> [Turn] {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var turns: [Turn] = []
        var nextActor = 0

        for line in lines {
            guard let first = line.first, speakerMarkers.contains(first) else {
                turns.append(Turn(speaker: .narrator, text: line))
                continue
            }
            let body = line.dropFirst()
                .trimmingCharacters(in: .whitespaces)
            // A marker with nothing after it is a separator, not speech. Emitting
            // it would voice an empty string, and consuming a speaker slot would
            // flip who talks next.
            guard !body.isEmpty else { continue }
            turns.append(Turn(speaker: .actor(nextActor), text: body))
            nextActor = (nextActor + 1) % 2
        }

        return turns
    }
}
