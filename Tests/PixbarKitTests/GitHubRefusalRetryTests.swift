// Tests/PixbarKitTests/GitHubRefusalRetryTests.swift
import Foundation
import Testing
@testable import PixbarKit

// A `FORBIDDEN` on a non-null field propagates null up to `repository`: the
// live answer for a read-only fine-grained token on artk0de/TeaRAGs-MCP
// (2026-09-24) is `{"data":{"repository":null},"errors":[FORBIDDEN on
// repository.stargazers]}` — no data beside the error at all. The client
// asks again without the refused part, and remembers the refusal per token.

/// Answers requests in order, one scripted answer each, and records them.
private final class ScriptedTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Data]
    private var recorded: [URLRequest] = []

    init(_ script: [Data]) {
        self.script = script
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    /// The GraphQL text each request carried, in order.
    var queries: [String] {
        requests.compactMap { request in
            guard let body = request.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            return json["query"] as? String
        }
    }

    func append(_ answer: Data) {
        lock.withLock { script.append(answer) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer = lock.withLock { () -> Data? in
            recorded.append(request)
            return script.isEmpty ? nil : script.removeFirst()
        }
        guard let answer else { throw URLError(.cannotConnectToHost) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (answer, response)
    }
}

/// The token the API reads, changeable between reads.
private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    init(_ value: String) { self.value = value }
    var token: String { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

/// The live answer, verbatim: the refusal nulls the whole repository.
private let liveStargazersRefusal = Data("""
{"data":{"repository":null},"errors":[{"type":"FORBIDDEN","path":["repository","stargazers"],\
"extensions":{"saml_failure":false},"locations":[{"line":7,"column":5}],\
"message":"Resource not accessible by personal access token"}]}
""".utf8)

/// A null repository refused on the given path.
private func refusal(_ path: [String]) -> Data {
    let pathJSON = "[" + path.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    return Data(#"""
    {"data":{"repository":null},"errors":[{"type":"FORBIDDEN","path":\#(pathJSON),"message":"Resource not accessible by personal access token"}]}
    """#.utf8)
}

/// The reduced query's answer: everything but `stargazers`.
private let reducedAnswer = Data("""
{"data":{"repository":{"nameWithOwner":"artk0de/TeaRAGs-MCP","stargazerCount":12,"forkCount":3,
 "pullRequests":{"totalCount":1},"forks":{"nodes":[]},
 "openPRs":{"nodes":[{"number":7,"author":{"login":"dave"}}]},"defaultBranchRef":null}}}
""".utf8)

/// The full query's answer, for a token that may list stargazers.
private let fullAnswer = Data("""
{"data":{"repository":{"nameWithOwner":"artk0de/TeaRAGs-MCP","stargazerCount":12,"forkCount":3,
 "pullRequests":{"totalCount":1},"stargazers":{"edges":[{"starredAt":"2026-09-20T10:00:00Z","node":{"login":"alice"}}]},
 "forks":{"nodes":[]},"openPRs":{"nodes":[{"number":7,"author":{"login":"dave"}}]},"defaultBranchRef":null}}}
""".utf8)

private let repo = "artk0de/TeaRAGs-MCP"

@Suite struct GitHubRefusalRetryTests {
    @Test func theLiveStargazersRefusalIsAskedAgainWithoutStargazers() async throws {
        let transport = ScriptedTransport([liveStargazersRefusal, reducedAnswer])
        let api = GitHubAPI(transport: transport, token: { "t" })

        let state = try #require(try await api.state(of: repo))

        #expect(state.stars == 12)
        #expect(state.forks == 3)
        #expect(state.openPRs == 1)
        #expect(state.openPRNumbers == [OpenPR(number: 7, author: "dave")])
        #expect(state.stargazers.isEmpty)
        #expect(state.withheld == [.stargazers])
        #expect(state.stargazersRefused)

        let queries = transport.queries
        #expect(queries.count == 2)
        #expect(queries[0].contains("stargazers("))
        #expect(!queries[1].contains("stargazers("))
        #expect(queries[1].contains("stargazerCount"))
        #expect(queries[1].contains("openPRs:"))
        #expect(queries[1].contains("forks("))
        #expect(queries[1].contains("defaultBranchRef"))
    }

    /// The tile reads the state, quietly — never `no repo`.
    @Test func theConnectorReadsTheStateAndSaysItQuietly() async throws {
        let transport = ScriptedTransport([liveStargazersRefusal, reducedAnswer])
        let tile = TileRecord(
            key: TileKey(clockId: UUID(), connectorId: GitHubConnector.connectorId, instance: repo),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 60),
            config: .github(GitHubTileConfig(repo: repo))
        )
        let connector = GitHubConnector(
            tile: tile, source: GitHubAPI(transport: transport, token: { "t" }), snapshots: NoSnapshots()
        )

        let reading = try await connector.read()

        guard case let .state(state) = reading.content else {
            Issue.record("expected a state, read \(reading.content)")
            return
        }
        #expect(state.stars == 12)
        #expect(reading.diagnosis == GitHubDiagnosis(
            message: "Star authors are hidden until the token gets Contents: write", severity: .partial
        ))
    }

    /// A later poll sends the reduced query straight away: one request, not two.
    @Test func theRefusalIsRememberedForTheToken() async throws {
        let transport = ScriptedTransport([liveStargazersRefusal, reducedAnswer, reducedAnswer])
        let api = GitHubAPI(transport: transport, token: { "t" })

        _ = try await api.state(of: repo)
        let second = try #require(try await api.state(of: repo))

        let queries = transport.queries
        #expect(queries.count == 3)
        #expect(!queries[2].contains("stargazers("))
        #expect(second.withheld == [.stargazers])
    }

    /// A new token may list stargazers: the full query is tried once again.
    @Test func aNewTokenTriesTheFullQueryAgain() async throws {
        let token = TokenBox("read-only")
        let transport = ScriptedTransport([liveStargazersRefusal, reducedAnswer, fullAnswer])
        let api = GitHubAPI(transport: transport, token: { token.token })

        _ = try await api.state(of: repo)
        token.token = "contents-write"
        let state = try #require(try await api.state(of: repo))

        let queries = transport.queries
        #expect(queries.count == 3)
        #expect(queries[2].contains("stargazers("))
        #expect(state.withheld.isEmpty)
        #expect(state.stargazers.map(\.login) == ["alice"])
    }

    /// The memory is the API's own; the app shares one between the reads of
    /// every tile, so a rebuilt connector does not ask twice again.
    @Test func aSharedMemoryOutlivesTheAPI() async throws {
        let refusals = GitHubRefusals()
        let transport = ScriptedTransport([liveStargazersRefusal, reducedAnswer, reducedAnswer])

        _ = try await GitHubAPI(transport: transport, token: { "t" }, refusals: refusals).state(of: repo)
        _ = try await GitHubAPI(transport: transport, token: { "t" }, refusals: refusals).state(of: repo)

        #expect(transport.queries.count == 3)
        #expect(!transport.queries[2].contains("stargazers("))
    }

    /// Every other part the mapper names is dropped the same way.
    @Test func anyNestedRefusalIsAskedAgainWithoutThatPart() async throws {
        let cases: [([String], GitHubWithheld, [String])] = [
            (["repository", "openPRs"], .pullRequests, ["openPRs:", "pullRequests("]),
            (["repository", "pullRequests"], .pullRequests, ["openPRs:", "pullRequests("]),
            (["repository", "forks"], .metadata, ["forks(", "forkCount"]),
            (["repository", "defaultBranchRef", "target", "statusCheckRollup"], .checks, ["statusCheckRollup"]),
            // Only the commit's author: the CI lamp itself still reads.
            (["repository", "defaultBranchRef", "target", "author"], .contents, ["author { user"]),
        ]
        for (path, part, dropped) in cases {
            let transport = ScriptedTransport([refusal(path), reducedAnswer])
            let api = GitHubAPI(transport: transport, token: { "t" })

            let state = try #require(try await api.state(of: repo), "\(path)")

            #expect(state.withheld == [part], "\(path)")
            #expect(state.stars == 12, "\(path)")
            let queries = transport.queries
            #expect(queries.count == 2, "\(path)")
            for selection in dropped {
                #expect(queries[0].contains(selection), "\(path) \(selection)")
                #expect(!queries[1].contains(selection), "\(path) \(selection)")
            }
            #expect(queries[1].contains("stargazers("), "\(path)")
        }
    }

    /// Two refusals in turn: each retry drops one more part, and both are named.
    @Test func refusalsAccumulate() async throws {
        let transport = ScriptedTransport([
            liveStargazersRefusal, refusal(["repository", "openPRs"]), reducedAnswer,
        ])
        let api = GitHubAPI(transport: transport, token: { "t" })

        let state = try #require(try await api.state(of: repo))

        #expect(state.withheld == [.stargazers, .pullRequests])
        let last = try #require(transport.queries.last)
        #expect(!last.contains("stargazers("))
        #expect(!last.contains("openPRs:"))
    }

    /// A refusal the reduced query cannot avoid is not asked forever, and is
    /// not a missing repository either.
    @Test func aRefusalThatRepeatsIsAFailureNotNoRepo() async throws {
        let transport = ScriptedTransport([liveStargazersRefusal, liveStargazersRefusal])
        let api = GitHubAPI(transport: transport, token: { "t" })

        do {
            _ = try await api.state(of: repo)
            Issue.record("expected a failure")
        } catch {
            #expect(GitHubConnector.content(failing: error) == .noData)
        }
        #expect(transport.queries.count == 2)
    }

    /// A refused path no selection covers cannot be dropped: a failure, not
    /// `no repo`, and no second request.
    @Test func anUnknownRefusedPathIsAFailureNotNoRepo() async throws {
        let transport = ScriptedTransport([refusal(["repository", "watchers"])])
        let api = GitHubAPI(transport: transport, token: { "t" })

        do {
            _ = try await api.state(of: repo)
            Issue.record("expected a failure")
        } catch {
            #expect(GitHubConnector.content(failing: error) == .noData)
        }
        #expect(transport.queries.count == 1)
    }

    /// Only `NOT_FOUND`, the repository itself withheld, or a null repository
    /// with no refusal reads `no repo`.
    @Test func onlyAMissingRepositoryReadsNoRepo() async throws {
        let answers = [
            Data(#"{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","path":["repository"],"message":"Could not resolve"}]}"#.utf8),
            refusal(["repository"]),
            Data(#"{"data":{"repository":null}}"#.utf8),
        ]
        for answer in answers {
            let transport = ScriptedTransport([answer])
            do {
                _ = try await GitHubAPI(transport: transport, token: { "t" }).state(of: repo)
                Issue.record("expected a failure")
            } catch {
                #expect(GitHubConnector.content(failing: error) == .noRepo, "\(String(decoding: answer, as: UTF8.self))")
            }
            #expect(transport.queries.count == 1)
        }
    }
}

// MARK: - Severity

/// A diagnosis is blocking (the tile does not work) or partial (it works
/// without a withheld part) — explicit, where it was a quiet flag.
@Suite struct GitHubDiagnosisSeverityTests {
    private let config = GitHubTileConfig(repo: "a/x")

    @Test func everyFailureIsBlocking() {
        for content in [GitHubReading.Content.badToken, .noRepo, .noData] {
            #expect(GitHubReading(content: content, config: config).diagnosis?.severity == .blocking, "\(content)")
        }
    }

    /// Every withheld part is partial, the stargazers too — no longer
    /// quiet — and each sentence names what is hidden and what unlocks it.
    @Test func everyWithheldPartIsPartialAndSaysWhatUnlocksIt() {
        var state = GitHubRepoState(nameWithOwner: "a/x", stars: 1, forks: 0, openPRs: 0)
        state.withheld = [.stargazers, .pullRequests]
        let diagnosis = GitHubReading(content: .state(state), config: config).diagnosis
        #expect(diagnosis == GitHubDiagnosis(
            message: "Star authors are hidden until the token gets Contents: write\n"
                + "Open PRs are hidden until the token gets Pull requests: read",
            severity: .partial
        ))
    }

    @Test func aDiagnosisRoundTrips() throws {
        let diagnosis = GitHubDiagnosis(message: "m", severity: .partial)
        let data = try JSONEncoder().encode(diagnosis)
        #expect(try JSONDecoder().decode(GitHubDiagnosis.self, from: data) == diagnosis)
    }

    /// A diagnosis stored before the severity: quiet was the stargazers
    /// case, which is partial; anything else was said as a problem.
    @Test func theOldStoredShapeStillDecodes() throws {
        let quiet = Data(#"{"message":"q","isQuiet":true}"#.utf8)
        let loud = Data(#"{"message":"l","isQuiet":false}"#.utf8)
        #expect(try JSONDecoder().decode(GitHubDiagnosis.self, from: quiet)
            == GitHubDiagnosis(message: "q", severity: .partial))
        #expect(try JSONDecoder().decode(GitHubDiagnosis.self, from: loud)
            == GitHubDiagnosis(message: "l", severity: .blocking))
    }
}

private struct NoSnapshots: GitHubSnapshotStoring {
    func snapshot(for tile: TileKey) -> GitHubSnapshot? { nil }
    func save(_ snapshot: GitHubSnapshot, for tile: TileKey) {}
}
