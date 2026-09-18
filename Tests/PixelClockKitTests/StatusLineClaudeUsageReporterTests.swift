import Foundation
import Testing
@testable import PixelClockKit

// The weekly figure, read from what Claude Code's status line leaves behind.
//
// Claude Code hands its status-line command a JSON document on stdin after
// each reply, and this app's hook stores the ones that carry `rate_limits`.
// The shape is a documented contract — https://code.claude.com/docs/en/statusline
// — where `/api/oauth/usage`, which this replaces, never was.

/// The document as Claude Code's documentation gives it, trimmed to the fields
/// around `rate_limits` but not reshaped. `spend_limit` is left in: it rides in
/// the same object behind a gateway, and nothing here may mistake it for a
/// window this app reads.
let statusLineDocument = #"""
{
  "cwd": "/current/working/directory",
  "session_id": "abc123...",
  "model": { "id": "claude-opus-5", "display_name": "Opus" },
  "workspace": {
    "current_dir": "/current/working/directory",
    "project_dir": "/original/project/directory"
  },
  "version": "2.1.90",
  "cost": { "total_cost_usd": 0.01234, "total_duration_ms": 45000 },
  "context_window": { "used_percentage": 8, "remaining_percentage": 92 },
  "rate_limits": {
    "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
    "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 },
    "spend_limit": { "used_percentage": 62.8, "resets_at": 1740787200 }
  }
}
"""#

/// Before either window in `statusLineDocument` resets.
private let beforeEitherReset = Date(timeIntervalSince1970: 1_738_420_000)

/// When the documents below were written, unless a test says otherwise.
private let writtenAt = Date(timeIntervalSince1970: 1_738_419_000)

/// A folder of its own holding the document, with a modification time the test
/// chooses — `observedAt` is that time, so it has to be known.
private struct StatusDocumentFolder {
    let url: URL
    var document: URL { url.appendingPathComponent("claude-status.json") }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("status-document-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ json: String, modified: Date = writtenAt) throws {
        try Data(json.utf8).write(to: document)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: document.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

@Test func theWeeklyWindowIsTheFigureAndTheFiveHourOneRidesAlong() async throws {
    let folder = try StatusDocumentFolder()
    defer { folder.remove() }
    try folder.write(statusLineDocument)
    let reporter = StatusLineClaudeUsageReporter(
        document: folder.document, now: { beforeEitherReset }
    )

    let reading = try #require(await reporter.read())

    #expect(reading.utilization == 41)
    #expect(reading.resetsAt == Date(timeIntervalSince1970: 1_738_857_600))
    #expect(reading.fiveHour == ClaudeUsageWindow(
        utilization: 24, resetsAt: Date(timeIntervalSince1970: 1_738_425_600)
    ))
    // The file's own time, not the moment it was read: the settings line and
    // any later "updated 3 min ago" are about when Claude Code last spoke.
    #expect(reading.observedAt == writtenAt)
}

// Nearest, because a bar drawn at 78 with the number 79 beside it is the kind
// of disagreement nobody can explain. Claude Code sends fractions.
@Test func aFractionalPercentageIsRoundedToTheNearestWholeOne() async throws {
    let folder = try StatusDocumentFolder()
    defer { folder.remove() }
    let reporter = StatusLineClaudeUsageReporter(
        document: folder.document, now: { beforeEitherReset }
    )

    try folder.write(#"{"rate_limits":{"seven_day":{"used_percentage":78.4,"resets_at":1738857600}}}"#)
    let low = try #require(await reporter.read())
    try folder.write(#"{"rate_limits":{"seven_day":{"used_percentage":78.6,"resets_at":1738857600}}}"#)
    let high = try #require(await reporter.read())

    #expect(low.utilization == 78)
    #expect(high.utilization == 79)
}

// Nil, never zero: zero is a real figure meaning "nothing spent this week".
@Test func noDocumentIsNoReading() async throws {
    let folder = try StatusDocumentFolder()
    defer { folder.remove() }
    let reporter = StatusLineClaudeUsageReporter(
        document: folder.document, now: { beforeEitherReset }
    )

    #expect(try await reporter.read() == nil)
}

// A window is read only when both of its figures are there. Without
// `resets_at` there is no telling when the figure stops being true, and a
// window that can never expire would stand on the clock for ever.
@Test func aWindowNeedsBothItsFiguresAndANullIsAbsence() async throws {
    let folder = try StatusDocumentFolder()
    defer { folder.remove() }
    let reporter = StatusLineClaudeUsageReporter(
        document: folder.document, now: { beforeEitherReset }
    )

    for document in [
        #"{"rate_limits":{"seven_day":null}}"#,
        #"{"rate_limits":{"seven_day":{"used_percentage":41.2}}}"#,
        #"{"rate_limits":{"seven_day":{"resets_at":1738857600}}}"#,
        #"{"rate_limits":{"seven_day":{"used_percentage":"41","resets_at":1738857600}}}"#,
    ] {
        try folder.write(document)
        #expect(try await reporter.read() == nil, "\(document)")
    }
}
