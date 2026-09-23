import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The row's text and badge are computed here and tested here, the way
// `NextRunLine` is — the view that draws them stays thin, and the split means
// a badge bug cannot hide behind a layout bug or the other way round.

@Suite struct TileRowLineTests {
    // A running tile is its name and its latest answer, and nothing else: the
    // two spaces are the row's own spacing, not the renderer's.
    @Test func runningTileDrawsResultWithoutBadge() {
        let line = TileRowLine.drawn(name: "Weather", result: "12°C",
                                     hold: nil, failure: nil)
        #expect(line.text == "Weather  12°C")
        #expect(line.badge == nil)
    }

    @Test func aTileWithNoResultYetDrawsItsNameAlone() {
        let line = TileRowLine.drawn(name: "Weather", result: nil,
                                     hold: nil, failure: nil)
        #expect(line.text == "Weather")
        #expect(line.badge == nil)
    }

    // The hold already decided WHY the tile is quiet; the line only names it.
    // The names differ from the hold's because the badge speaks to the user.
    @Test func eachHoldDrawsItsBadge() {
        #expect(TileRowLine.drawn(name: "Weather", result: nil, hold: .paused,
                                  failure: nil).badge == .paused)
        #expect(TileRowLine.drawn(name: "Weather", result: nil, hold: .hours,
                                  failure: nil).badge == .silentHours)
        #expect(TileRowLine.drawn(name: "Weather", result: nil, hold: .focus,
                                  failure: nil).badge == .heldByFocus)
    }

    // A failing tile says what went wrong, in words a person would say. The
    // error's own dialect — domains, codes, quoted diagnostics — never
    // reaches the row.
    @Test func aFailingTileSaysWhatWentWrongInWords() {
        let line = TileRowLine.drawn(
            name: "Anecdotes", result: "failed", hold: nil,
            failure: "Error Domain=NSURLErrorDomain Code=-1001 "
                + "\"The request timed out.\""
        )
        #expect(line.badge == .failing)
        #expect(line.text == "Anecdotes  failing — timed out")
    }

    // Failure outranks a hold, as it did when it was only a flag: the last
    // thing a tile did wrong is the more urgent answer.
    @Test func failingOutranksAHold() {
        let line = TileRowLine.drawn(name: "Weather", result: nil,
                                     hold: .paused, failure: "the feed is down")
        #expect(line.badge == .failing)
        #expect(line.text == "Weather  failing — the feed is down")
    }

    // The mapping from the raw message to the words. Each dialect the
    // transports actually speak lands on its sentence.
    @Test func eachRawDialectBecomesItsWords() {
        #expect(TileRowLine.cause(from: "Error Domain=NSURLErrorDomain Code=-1001 "
            + "\"The request timed out.\"") == "timed out")
        #expect(TileRowLine.cause(from: "Error Domain=NSURLErrorDomain Code=-1009 "
            + "\"The Internet connection appears to be offline.\"") == "offline")
        #expect(TileRowLine.cause(from: "Error Domain=NSURLErrorDomain Code=-1005 "
            + "\"The network connection was lost.\"") == "connection lost")
        #expect(TileRowLine.cause(from: "Error Domain=NSURLErrorDomain Code=-1003 "
            + "\"A server with the specified hostname could not be found.\"")
            == "server not found")
        #expect(TileRowLine.cause(from: "Error Domain=NSURLErrorDomain Code=-1004 "
            + "\"Could not connect to the server.\"") == "could not reach the server")
    }

    // A failure with no dialect the app knows is still a sentence: the raw
    // message, cut to what a row has room to show.
    @Test func anUnknownFailureKeepsTheRawMessageCutToTheRow() {
        let raw = String(repeating: "x", count: 200)
        #expect(TileRowLine.cause(from: raw) == String(repeating: "x", count: 60))
    }
}

@Suite struct TileRowIconTests {
    // The mark a row opens with is the connector's own, and no two shipped
    // connectors share one.
    @Test func everyShippedConnectorHasItsOwnSymbol() {
        let symbols = [
            "weather", "claude", "anecdotes", ZaiUsageConnector.connectorId, VPNConnector.id,
        ].map { TileRowIcon.symbol(forConnectorId: $0) }
        #expect(Set(symbols).count == 5)
    }

    // One table, not two. There were two — this one and the kit's — and they
    // had drifted where it shows: z.ai was a bar chart on its store card and
    // the "unknown app" mark on its clock card, so one tile wore two faces
    // depending on which window was looking at it.
    @Test func theRowAndTheStoreCardReadTheSameTable() {
        for connectorId in [
            "weather", "claude", "anecdotes", ZaiUsageConnector.connectorId, VPNConnector.id,
            "a connector nobody has written",
        ] {
            #expect(
                TileRowIcon.symbol(forConnectorId: connectorId)
                    == TilePresentation.of(connectorId: connectorId).icon,
                "\(connectorId) wears two marks"
            )
        }
        #expect(TileRowIcon.symbol(forConnectorId: ZaiUsageConnector.connectorId) == "chart.bar")
    }

    // A connector the icon table does not know still gets a mark — the row
    // must not draw nothing.
    @Test func anUnknownConnectorStillGetsAMark() {
        #expect(TileRowIcon.symbol(forConnectorId: "slack") == "app.dashed")
    }
}
