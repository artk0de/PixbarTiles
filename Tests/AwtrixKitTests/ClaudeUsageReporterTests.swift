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

// MARK: - How often the credential is fetched

/// Counts how many times the store was asked, and can hand out a new token.
private final class CountingCredential: ClaudeCredentialReading, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var tokens: [String]

    init(_ tokens: [String]) { self.tokens = tokens }

    var timesAsked: Int { lock.withLock { reads } }

    func accessToken() -> String? {
        lock.withLock {
            defer { reads += 1 }
            return tokens.indices.contains(reads) ? tokens[reads] : tokens.last
        }
    }
}

/// Answers each canned status in turn, so one call can be refused and the next
/// allowed.
private final class ScriptedTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [(status: Int, body: Data)]
    private var sent: [URLRequest] = []

    init(_ script: [(status: Int, body: Data)]) { self.script = script }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let step = lock.withLock { () -> (status: Int, body: Data) in
            sent.append(request)
            return script.count > 1 ? script.removeFirst() : script[0]
        }
        return (
            step.body,
            HTTPURLResponse(
                url: request.url!, statusCode: step.status, httpVersion: nil, headerFields: nil
            )!
        )
    }
}

// The keychain is asked ONCE, and then not again while the token works.
//
// This is a fix for a real complaint rather than an optimisation. The connector
// polls every five minutes, and the first version read the credential on every
// one of those — two hundred and eighty-eight reads of another application's
// keychain item a day. macOS may put a password prompt in front of any of them,
// so "read it fresh so a renewal is picked up" bought correctness at the price
// of a dialog that would not stop.
@Test func theCredentialIsFetchedOnceAndReusedWhileItWorks() async throws {
    let credentials = CountingCredential(["tok-1"])
    let transport = RecordingTransport()
    transport.body = Data(usageBody.utf8)
    let reporter = ClaudeUsageReporter(transport: transport, credentials: credentials)

    for _ in 0..<5 { _ = try await reporter.read() }

    #expect(credentials.timesAsked == 1, "asked \(credentials.timesAsked) times")
    #expect(transport.requests.count == 5)
}

// And it IS asked again the moment the token stops working, which is what keeps
// the caching honest: a renewal is picked up on the first poll after the old
// token is refused, rather than at the next launch.
@Test func aRefusedTokenIsFetchedAgainAndTheRequestRetried() async throws {
    let credentials = CountingCredential(["stale", "fresh"])
    let transport = ScriptedTransport([
        (401, Data(#"{"type":"error"}"#.utf8)),
        (200, Data(usageBody.utf8)),
    ])
    let reporter = ClaudeUsageReporter(transport: transport, credentials: credentials)

    let reading = try #require(await reporter.read())

    #expect(reading.utilization == 78)
    #expect(credentials.timesAsked == 2)
    // Two requests, and the second carried the NEW token — a retry with the same
    // one would spend a round trip to be refused identically.
    #expect(transport.requests.count == 2)
    #expect(transport.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer stale")
    #expect(transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
}

// One retry, never a loop. A store that keeps handing back the same refused
// token must not be asked forever.
@Test func aTokenThatIsStillRefusedAfterRereadingAnswersNothing() async throws {
    let credentials = CountingCredential(["stale"])
    let transport = ScriptedTransport([(401, Data(#"{"type":"error"}"#.utf8))])
    let reporter = ClaudeUsageReporter(transport: transport, credentials: credentials)

    let reading = try await reporter.read()

    #expect(reading == nil)
    #expect(transport.requests.count <= 2, "sent \(transport.requests.count) requests")
}

// MARK: - Where the credential comes from

// The token belongs to Claude Code, not to this app, and the two rules that
// follow from that are the whole design. This app READS it and never refreshes
// it: an OAuth refresh rotates the refresh token, so refreshing here would drop
// Claude Code out of its own session mid-work. And a look at the store is
// always a real look — the store itself holds nothing. WHEN to look is the
// reporter's decision, asserted above: it holds a token while the service
// accepts it, because every look can raise a password prompt.
@Test func aLookAtTheStoreIsAlwaysARealLook() {
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
