import Foundation
import Testing
@testable import PixelClockKit

private func loadFixture() throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: "export_top_sample", withExtension: "xml"
    ))
    return try Data(contentsOf: url)
}

/// A one-item feed built inline, so a test about markup shape can state its own
/// input without perturbing the fixture's item count.
private func feed(item: String) -> Data {
    Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0"><channel><item>\(item)</item></channel></rss>
    """.utf8)
}

@Test func parseExtractsEveryItem() throws {
    let anecdotes = AnecdoteSource.parse(try loadFixture())

    #expect(anecdotes.count == 2)
}

@Test func parseUsesGuidAsTheIdentity() throws {
    let anecdotes = AnecdoteSource.parse(try loadFixture())

    #expect(anecdotes[0].id == "https://www.anekdot.ru/id/1622958/")
}

@Test func parseTurnsBreakTagsIntoNewlines() throws {
    let anecdotes = AnecdoteSource.parse(try loadFixture())

    #expect(anecdotes[0].text == "- Ты у меня зонт забыла!\n- Это не зонт, это трость!")
}

@Test func parseDecodesHtmlEntities() throws {
    let anecdotes = AnecdoteSource.parse(try loadFixture())

    #expect(anecdotes[1].text.contains("\"Теремок\""))
    #expect(!anecdotes[1].text.contains("&quot;"))
}

@Test func parseOfGarbageYieldsNothingRatherThanThrowing() {
    #expect(AnecdoteSource.parse(Data("not xml at all".utf8)).isEmpty)
}

@Test func fetchRequestsTheTopFeed() async throws {
    let transport = RecordingTransport()
    transport.body = try loadFixture()
    let source = AnecdoteSource(transport: transport)

    let anecdotes = try await source.fetch()

    #expect(transport.requests.first?.url == AnecdoteSource.topFeed)
    #expect(anecdotes.count == 2)
}

// MARK: markup the live feed actually varies on

@Test func parseAcceptsEveryBreakTagSpelling() {
    let anecdotes = AnecdoteSource.parse(feed(item: """
    <description><![CDATA[один<br>два<br/>три<br />четыре<BR>пять]]></description>
    <guid>https://www.anekdot.ru/id/1/</guid>
    """))

    #expect(anecdotes.first?.text == "один\nдва\nтри\nчетыре\nпять")
}

@Test func parseDoesNotDoubleDecodeAmpersandEscapes() {
    let anecdotes = AnecdoteSource.parse(feed(item: """
    <description><![CDATA[&amp;quot; и &amp; сам по себе]]></description>
    <guid>https://www.anekdot.ru/id/2/</guid>
    """))

    #expect(anecdotes.first?.text == "&quot; и & сам по себе")
}

@Test func parseReadsTagsThatCarryAttributes() {
    let anecdotes = AnecdoteSource.parse(feed(item: """
    <description><![CDATA[текст]]></description>
    <guid isPermaLink="false">1622958</guid>
    """))

    #expect(anecdotes.first?.id == "1622958")
}

@Test func parseKeepsCdataTextContainingItsOwnClosingTag() {
    let anecdotes = AnecdoteSource.parse(feed(item: """
    <description><![CDATA[Он написал </description> и ушёл]]></description>
    <guid>https://www.anekdot.ru/id/3/</guid>
    """))

    #expect(anecdotes.first?.text == "Он написал </description> и ушёл")
}

@Test func parseDropsItemsWithNoIdentityOrNoText() {
    let noGuid = AnecdoteSource.parse(
        feed(item: "<description><![CDATA[текст]]></description>")
    )
    let noDescription = AnecdoteSource.parse(
        feed(item: "<guid>https://www.anekdot.ru/id/4/</guid>")
    )
    let emptyText = AnecdoteSource.parse(feed(item: """
    <description><![CDATA[<br>]]></description>
    <guid>https://www.anekdot.ru/id/5/</guid>
    """))

    #expect(noGuid.isEmpty)
    #expect(noDescription.isEmpty)
    #expect(emptyText.isEmpty)
}

@Test func parseDoesNotLeakCdataMarkersWhenPrecededByWhitespace() {
    let anecdotes = AnecdoteSource.parse(feed(item: """
    <description>
    <![CDATA[текст]]>
    </description>
    <guid>https://www.anekdot.ru/id/6/</guid>
    """))

    #expect(anecdotes.count == 1)
    #expect(anecdotes.first?.text == "текст")
}

@Test func fetchRejectsANonSuccessStatusInsteadOfParsingTheErrorPage() async {
    let transport = RecordingTransport()
    transport.status = 503
    transport.body = Data("<html>maintenance</html>".utf8)
    let source = AnecdoteSource(transport: transport)

    await #expect(throws: AwtrixError.self) {
        _ = try await source.fetch()
    }
}

// MARK: - Popularity, which the feed gives away as position

// The feed carries no rating, no vote count and no score — checked against the
// live document, whose item elements are `title`, `pubDate`, `link`,
// `description` and `guid`. What it IS, by its own definition, is ranked by
// reader votes, so the ordering IS the popularity and there is nothing else to
// read. Fetching each anecdote's HTML page to recover a number would be one
// request per anecdote, against markup nobody controls, for an ordering that
// already arrived.
//
// Three items rather than two: with two, "ascending from zero" and "descending
// from the last index" agree on nothing but the count, and reversing the
// assignment would still put the first item at a different number from the
// second. The middle one is what makes the direction observable.
@Test func theFeedsOrderIsCarriedThroughAsRank() {
    let anecdotes = AnecdoteSource.parse(Data("""
    <rss><channel>
    <item><description><![CDATA[самый популярный]]></description>
    <guid>https://www.anekdot.ru/id/1/</guid></item>
    <item><description><![CDATA[второй]]></description>
    <guid>https://www.anekdot.ru/id/2/</guid></item>
    <item><description><![CDATA[третий]]></description>
    <guid>https://www.anekdot.ru/id/3/</guid></item>
    </channel></rss>
    """.utf8))

    #expect(anecdotes.map(\.id) == [
        "https://www.anekdot.ru/id/1/",
        "https://www.anekdot.ru/id/2/",
        "https://www.anekdot.ru/id/3/",
    ])
    // Ascending, and from the top of the feed: the most-voted anecdote is the
    // one the queue will play first, and the number it sorts on has to be the
    // smallest rather than the largest.
    #expect(anecdotes.map(\.rank) == [0, 1, 2])
}
