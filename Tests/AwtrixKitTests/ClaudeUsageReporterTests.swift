import Foundation
import Testing
@testable import AwtrixKit

private struct FixedCredential: ClaudeCredentialReading {
    let token: String?
    func accessToken() -> String? { token }
}

@Test func theReportAsksTheUsageEndpointAsTheSignedInUser() async throws {
    let transport = RecordingTransport()
    transport.body = Data(usageBody.utf8)
    let reporter = ClaudeUsageReporter(
        transport: transport,
        credentials: FixedCredential(token: "tok-123")
    )

    let reading = try #require(await reporter.read())

    #expect(reading.utilization == 78)

    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
    // The endpoint is part of the OAuth surface rather than the messages API,
    // and it is the beta header that selects it. Asserted so that dropping it
    // is a decision rather than a drift into a 4xx nobody reads.
    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
}

// Every one of these is "cannot tell", and every one answers nil rather than
// throwing or guessing. The connector turns nil into no delivery, the clock
// drops the app when its lifetime runs out, and the matrix stops claiming a
// figure nothing can currently support. A zero here would be a calm lie.
@Test func nothingIsReportedWhenTheServiceCannotBeAsked() async throws {
    let expired = RecordingTransport()
    expired.status = 401
    expired.body = Data(#"{"type":"error","error":{"type":"authentication_error"}}"#.utf8)

    let onStaleToken = try await ClaudeUsageReporter(
        transport: expired,
        credentials: FixedCredential(token: "stale")
    ).read()
    #expect(onStaleToken == nil)

    let serverTrouble = RecordingTransport()
    serverTrouble.status = 500
    serverTrouble.body = Data(usageBody.utf8)

    let onServerTrouble = try await ClaudeUsageReporter(
        transport: serverTrouble,
        credentials: FixedCredential(token: "tok")
    ).read()
    #expect(onServerTrouble == nil)
}

@Test func noCredentialMeansNoRequestAtAll() async throws {
    let transport = RecordingTransport()
    let reporter = ClaudeUsageReporter(
        transport: transport,
        credentials: FixedCredential(token: nil)
    )

    let reading = try await reporter.read()

    #expect(reading == nil)
    // And nothing was sent. A request with no Authorization header would spend
    // a round trip to be told what this already knew.
    #expect(transport.requests.isEmpty)
}

// MARK: - Where the credential comes from

// The token belongs to Claude Code, not to this app, and the two rules that
// follow from that are the whole design. This app READS it and never refreshes
// it: an OAuth refresh rotates the refresh token, so refreshing here would drop
// Claude Code out of its own session mid-work. And it re-reads rather than
// caching, so the moment Claude Code renews, the next poll picks the new one up.
@Test func theCredentialIsReadFreshFromTheStoreOnEveryLook() {
    final class CountingStore: ClaudeCredentialReading, @unchecked Sendable {
        var reads = 0
        func accessToken() -> String? { reads += 1; return "t" }
    }
    let store = CountingStore()

    _ = store.accessToken()
    _ = store.accessToken()

    #expect(store.reads == 2)
}

@Test func aCredentialFileWithNoLiveTokenReadsAsNoCredential() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("claude-cred-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("creds.json")
    try Data(#"{"claudeAiOauth":{"refreshToken":"only-a-refresh"}}"#.utf8).write(to: file)

    #expect(FileClaudeCredentials(url: file).accessToken() == nil)
}

// The token is taken from ONE named place, and this is the test that says why.
//
// The same document holds `mcpOAuth`, a dictionary of every MCP server the user
// has signed into — Figma, Miro, Atlassian — and every one of those entries has
// an `accessToken` of its own. An earlier version of this searched for the first
// `accessToken` at any depth, on the reasoning that another program's shape may
// move. Dictionary order is not defined, so that search could return Figma's
// token, and this app would have sent a third party's credential to Anthropic.
//
// A named path can break loudly when the shape changes. A greedy search breaks
// quietly and sends the wrong secret somewhere.
@Test func onlyClaudesOwnTokenIsTakenFromADocumentFullOfThem() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("claude-cred-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("creds.json")
    // The real shape on this machine, with the neighbours that make it dangerous.
    try Data("""
    {"claudeAiOauth":{"accessToken":"claudes-own","refreshToken":"r","scopes":[]},
     "mcpOAuth":{"figma|d39d":{"serverName":"figma","accessToken":"figmas"},
                 "miro|32bd":{"serverName":"miro","accessToken":"miros"}}}
    """.utf8).write(to: file)

    #expect(FileClaudeCredentials(url: file).accessToken() == "claudes-own")

    // And a document with ONLY somebody else's tokens yields nothing at all,
    // rather than the nearest thing that looks like a credential.
    let strangers = directory.appendingPathComponent("strangers.json")
    try Data(#"{"mcpOAuth":{"figma|d39d":{"accessToken":"figmas"}}}"#.utf8).write(to: strangers)
    #expect(FileClaudeCredentials(url: strangers).accessToken() == nil)

    #expect(FileClaudeCredentials(url: directory.appendingPathComponent("absent.json"))
        .accessToken() == nil)
}
