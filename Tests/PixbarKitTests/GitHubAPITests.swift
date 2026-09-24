// Tests/PixbarKitTests/GitHubAPITests.swift
import Foundation
import Testing
@testable import PixbarKit

// The client is one POST over the injected transport. It never reaches the
// network here: a recording transport answers with a canned body, and the
// request itself is what the tests pin.

/// Answers every request with one canned body, and records what was asked.
/// A private copy of `ZaiUsageConnectorTests`' routing transport, keyed by the
/// last path component the same way — the GraphQL endpoint has one route,
/// "graphql".
private final class RoutingTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var answers: [String: (status: Int, body: Data)] = [:]

    init(answers: [String: (status: Int, body: Data)]) {
        self.answers = answers
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // One acquisition, released before the response is built — never held
        // across a suspension point.
        let answer = lock.withLock { () -> (status: Int, body: Data)? in
            recorded.append(request)
            return answers[request.url?.lastPathComponent ?? ""]
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: answer?.status ?? 404,
            httpVersion: nil, headerFields: nil
        )!
        return (answer?.body ?? Data(), response)
    }
}

/// A repository answer as the GraphQL endpoint spells it: the aliased
/// `openPRs` connection beside the counted `pullRequests` one.
private let recordedBody = Data("""
{"data":{"repository":{
  "nameWithOwner":"artk0de/tea-rags",
  "stargazerCount":1234,
  "forkCount":45,
  "pullRequests":{"totalCount":3},
  "stargazers":{"edges":[
    {"starredAt":"2026-09-20T10:00:00Z","node":{"login":"alice"}},
    {"starredAt":"2026-09-21T11:30:00Z","node":{"login":"bob"}}
  ]},
  "forks":{"nodes":[
    {"createdAt":"2026-09-22T08:15:00Z","owner":{"login":"carol"}}
  ]},
  "openPRs":{"nodes":[
    {"number":42,"author":{"login":"dave"}}
  ]}
}}}
""".utf8)

@Suite struct GitHubAPITests {
    private func makeAPI(_ transport: RoutingTransport, token: String? = "t") -> GitHubAPI {
        GitHubAPI(transport: transport, token: { token })
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    @Test func noTokenAsksNothing() async throws {
        let transport = RoutingTransport(answers: ["graphql": (200, recordedBody)])

        let state = try await makeAPI(transport, token: nil).state(of: "artk0de/tea-rags")

        #expect(state == nil)
        #expect(transport.requests.isEmpty)
    }

    @Test func theRequestCarriesTheQueryAndTheBearer() async throws {
        let transport = RoutingTransport(answers: ["graphql": (200, recordedBody)])

        _ = try await makeAPI(transport).state(of: "artk0de/tea-rags")

        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url == GitHubAPI.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "PixelClockTiles")

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let variables = try #require(json["variables"] as? [String: Any])
        #expect(variables["owner"] as? String == "artk0de")
        #expect(variables["name"] as? String == "tea-rags")
        let query = try #require(json["query"] as? String)
        #expect(query.contains("stargazerCount"))
    }

    @Test func aRecordedAnswerDecodes() async throws {
        let transport = RoutingTransport(answers: ["graphql": (200, recordedBody)])

        let state = try #require(try await makeAPI(transport).state(of: "artk0de/tea-rags"))

        #expect(state.nameWithOwner == "artk0de/tea-rags")
        #expect(state.stars == 1234)
        #expect(state.forks == 45)
        #expect(state.openPRs == 3)
        #expect(state.stargazers == [
            Stargazer(login: "alice", starredAt: date("2026-09-20T10:00:00Z")),
            Stargazer(login: "bob", starredAt: date("2026-09-21T11:30:00Z")),
        ])
        #expect(state.forkEvents == [
            ForkEvent(login: "carol", createdAt: date("2026-09-22T08:15:00Z")),
        ])
        #expect(state.openPRNumbers == [OpenPR(number: 42, author: "dave")])
    }

    @Test func aGraphQLErrorThrows() async throws {
        let body = Data(#"{"errors":[{"message":"Could not resolve to a Repository"}]}"#.utf8)
        let transport = RoutingTransport(answers: ["graphql": (200, body)])

        await #expect(throws: GitHubAPI.Failure.graphQL("Could not resolve to a Repository")) {
            _ = try await makeAPI(transport).state(of: "artk0de/nope")
        }
    }

    @Test func aRefusedTokenThrowsTheStatus() async throws {
        let body = Data(#"{"message":"Bad credentials"}"#.utf8)
        let transport = RoutingTransport(answers: ["graphql": (401, body)])

        await #expect(throws: GitHubAPI.Failure.status(401)) {
            _ = try await makeAPI(transport).state(of: "artk0de/tea-rags")
        }
    }

    @Test func aRepoWithoutASlashIsRefusedBeforeTheWire() async throws {
        let transport = RoutingTransport(answers: ["graphql": (200, recordedBody)])

        await #expect(throws: GitHubAPI.Failure.badRepo("tea-rags")) {
            _ = try await makeAPI(transport).state(of: "tea-rags")
        }
        #expect(transport.requests.isEmpty)
    }
}

/// A repository answer carrying the default branch's head commit, with the
/// rollup's `state` spelled as GitHub spells it — or no rollup when nil.
private func ciBody(rollup: String?, author: String? = "dave", ref: Bool = true) -> Data {
    let rollupJSON = rollup.map { #"{"state":"\#($0)"}"# } ?? "null"
    let authorJSON = author.map { #"{"user":{"login":"\#($0)"}}"# } ?? #"{"user":null}"#
    let refJSON = ref
        ? #"{"name":"main","target":{"oid":"abc123","author":\#(authorJSON),"statusCheckRollup":\#(rollupJSON)}}"#
        : "null"
    return Data("""
    {"data":{"repository":{
      "nameWithOwner":"artk0de/tea-rags","stargazerCount":1,"forkCount":0,
      "pullRequests":{"totalCount":0},"stargazers":{"edges":[]},"forks":{"nodes":[]},
      "openPRs":{"nodes":[]},
      "defaultBranchRef":\(refJSON)
    }}}
    """.utf8)
}

@Suite struct GitHubAPICITests {
    private func decoded(_ body: Data) throws -> GitHubRepoState {
        try GitHubAPI.decode(body, repo: "artk0de/tea-rags")
    }

    @Test func theQueryAsksForTheDefaultBranchsRollup() {
        #expect(GitHubAPI.query.contains("defaultBranchRef"))
        #expect(GitHubAPI.query.contains("statusCheckRollup { state }"))
        #expect(GitHubAPI.query.contains("oid"))
    }

    @Test func theRollupStatesMapToTheLampsStates() throws {
        let cases: [(String, GitHubCI.State)] = [
            ("SUCCESS", .success), ("FAILURE", .failure), ("ERROR", .failure),
            ("PENDING", .pending), ("EXPECTED", .pending),
        ]
        for (rollup, expected) in cases {
            let ci = try #require(try decoded(ciBody(rollup: rollup)).ci, "\(rollup)")
            #expect(ci.state == expected, "\(rollup)")
        }
    }

    @Test func theHeadCommitIsNamed() throws {
        let ci = try #require(try decoded(ciBody(rollup: "FAILURE")).ci)
        #expect(ci == GitHubCI(state: .failure, branch: "main", headOid: "abc123", author: "dave"))
    }

    @Test func aCommitWithoutALinkedAccountHasNoAuthor() throws {
        let ci = try #require(try decoded(ciBody(rollup: "FAILURE", author: nil)).ci)
        #expect(ci.author == nil)
    }

    @Test func noRollupIsNone() throws {
        let ci = try #require(try decoded(ciBody(rollup: nil)).ci)
        #expect(ci.state == .none)
    }

    @Test func noDefaultBranchIsNoCI() throws {
        #expect(try decoded(ciBody(rollup: nil, ref: false)).ci == nil)
    }

    /// An answer without the branch — an empty repository has none — decodes.
    @Test func anAnswerWithoutTheBranchStillDecodes() throws {
        #expect(try decoded(recordedBody).ci == nil)
    }
}
