import Foundation

public struct Anecdote: Sendable, Equatable {
    public let id: String
    public let text: String
    /// Where this anecdote sat in the feed it came from, counting from zero.
    ///
    /// The feed carries no rating, no vote count and no score — its elements are
    /// `title`, `pubDate`, `link`, `description` and `guid`, and that was checked
    /// against the live document rather than assumed. What the feed IS, by its
    /// own definition, is ranked by reader votes. So popularity is available for
    /// free as position and only as position, and recovering a number would mean
    /// one request per anecdote against a page nobody controls to obtain an
    /// ordering that arrived with the feed.
    ///
    /// Defaulted, because the only producer that has a position to give is
    /// `parse`, and the callers that build one by hand — the `unseen` filter
    /// reads nothing but the id — have no feed to be positioned in.
    public let rank: Int

    public init(id: String, text: String, rank: Int = 0) {
        self.id = id
        self.text = text
        self.rank = rank
    }
}

/// Reads the day's popular anecdotes.
///
/// The chosen feed ranks by reader votes rather than recency; the sibling
/// `export_j.xml` is only the fresh ten and does not answer "most popular".
///
/// Parsing is a hand-rolled scan rather than `XMLParser`, so that a malformed
/// or truncated download degrades to fewer anecdotes instead of throwing on a
/// path whose only caller wants something to display.
public struct AnecdoteSource: Sendable {
    public static let topFeed = URL(string: "https://www.anekdot.ru/rss/export_top.xml")!
    /// Twelve, the best of past years on this date.
    public static let bestOfDayFeed = URL(string: "https://www.anekdot.ru/rss/export_bestday.xml")!
    /// The fresh ten, unranked.
    public static let freshFeed = URL(string: "https://www.anekdot.ru/rss/export_j.xml")!

    /// Widest-first, most popular first. Roughly 72 items in total, refreshed
    /// daily — enough that a half-hourly reading never doubles back, which
    /// resetting the played set instead would break inside a day.
    public static let cascade: [URL] = [topFeed, bestOfDayFeed, freshFeed]

    private let transport: Transport
    private let feed: URL

    public init(transport: Transport, feed: URL = AnecdoteSource.topFeed) {
        self.transport = transport
        self.feed = feed
    }

    public func fetch() async throws -> [Anecdote] {
        try await fetch(from: feed)
    }

    public func fetch(from feed: URL) async throws -> [Anecdote] {
        var request = URLRequest(url: feed)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.send(request)
        // Checked before parsing: an error page is well-formed HTML that scans
        // to zero anecdotes, which would read as "the feed is empty today".
        guard (200..<300).contains(response.statusCode) else {
            throw AwtrixError.http(
                status: response.statusCode,
                body: String(decoding: data, as: UTF8.self),
                endpoint: feed.absoluteString
            )
        }
        return Self.parse(data)
    }

    public static func parse(_ xml: Data) -> [Anecdote] {
        let document = String(decoding: xml, as: UTF8.self)
        // Enumerated over the items as the document lists them, before the
        // dropping below: the rank is where the anecdote sat in the feed, and an
        // item discarded for having no text really did occupy the place it left.
        // The numbers may therefore have gaps, which costs nothing — only their
        // order is ever read.
        return items(in: document).enumerated().compactMap { position, item in
            guard
                let guid = value(of: "guid", in: item),
                let description = value(of: "description", in: item)
            else { return nil }
            let text = normalize(description)
            // The caller picks one of these blind, so an item with no identity
            // or nothing to say is dropped rather than shown as a blank frame.
            guard !guid.isEmpty, !text.isEmpty else { return nil }
            return Anecdote(id: guid, text: text, rank: position)
        }
    }

    // MARK: parsing helpers

    private static let cdataOpen = "<![CDATA["
    private static let cdataClose = "]]>"

    private static func items(in document: String) -> [String] {
        var items: [String] = []
        var cursor = document.startIndex
        while let open = openingTag("item", in: document, from: cursor) {
            guard let close = document.range(
                of: "</item>", range: open.upperBound..<document.endIndex
            ) else {
                // A truncated download leaves the last item unclosed; half an
                // anecdote is worse than one fewer.
                break
            }
            items.append(String(document[open.upperBound..<close.lowerBound]))
            cursor = close.upperBound
        }
        return items
    }

    /// The full span of an opening tag, attributes included — RSS routinely
    /// writes `<guid isPermaLink="false">`, and the attributes are not part of
    /// the value. Only `>` or whitespace ends a tag name, so a search for
    /// `guid` does not latch onto `<guidance>`.
    private static func openingTag(
        _ tag: String, in text: String, from start: String.Index
    ) -> Range<String.Index>? {
        var cursor = start
        while let name = text.range(of: "<\(tag)", range: cursor..<text.endIndex) {
            cursor = name.upperBound
            guard cursor < text.endIndex else { return nil }
            if text[cursor] == ">" {
                return name.lowerBound..<text.index(after: cursor)
            }
            if text[cursor].isWhitespace,
               let close = text.range(of: ">", range: cursor..<text.endIndex) {
                return name.lowerBound..<close.upperBound
            }
        }
        return nil
    }

    private static func value(of tag: String, in item: String) -> String? {
        guard let open = openingTag(tag, in: item, from: item.startIndex) else { return nil }
        let rest = item[open.upperBound...]

        // CDATA is resolved before the closing tag is looked for: its payload
        // may legally contain "</description>", and searching for the closing
        // tag first would cut the text there.
        let leading = rest.drop(while: \.isWhitespace)
        if leading.hasPrefix(cdataOpen) {
            guard let end = leading.range(of: cdataClose) else { return nil }
            let start = leading.index(leading.startIndex, offsetBy: cdataOpen.count)
            return String(leading[start..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let close = rest.range(of: "</\(tag)>") else { return nil }
        return String(rest[rest.startIndex..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ordered rather than a dictionary, because `&amp;` has to be decoded
    /// last. Dictionary iteration order is unspecified, so decoding it first
    /// would turn a literal `&amp;quot;` into `&quot;` and then into a quote.
    private static let entities: [(entity: String, character: String)] = [
        ("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
        ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"), ("&amp;", "&"),
    ]

    /// The feed separates lines with a literal `<br>` tag, which the dialogue
    /// parser expects as a newline — it treats a dash as a speaker marker only
    /// at the start of a line, and never strips markup itself.
    ///
    /// Break tags are replaced before entities are decoded, so an escaped
    /// `&lt;br&gt;` stays the literal text it was written as.
    private static func normalize(_ raw: String) -> String {
        var text = raw
        for tag in ["<br/>", "<br />", "<br>"] {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
