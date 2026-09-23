// Sources/PixelClockKit/GitHub/GitHubAPI.swift
import Foundation

/// One stargazer as the repository lists it: who, and when they starred.
public struct Stargazer: Sendable, Equatable, Codable {
    public var login: String
    public var starredAt: Date

    public init(login: String, starredAt: Date) {
        self.login = login
        self.starredAt = starredAt
    }
}

/// One fork, named by the account that owns it.
public struct ForkEvent: Sendable, Equatable, Codable {
    public var login: String
    public var createdAt: Date

    public init(login: String, createdAt: Date) {
        self.login = login
        self.createdAt = createdAt
    }
}

/// One open pull request: its number is its identity, the author is what a
/// celebration names.
public struct OpenPR: Sendable, Equatable, Codable, Hashable {
    public var number: Int
    public var author: String

    public init(number: Int, author: String) {
        self.number = number
        self.author = author
    }
}

/// The default branch's CI as its head commit's check rollup reports it.
///
/// The commit is the identity: a failure is news once per failing head
/// (`GitHubSnapshot.lastFailedOid`), not once per read that finds it red.
public struct GitHubCI: Sendable, Equatable {
    /// GitHub's rollup folded into what the lamp draws: `FAILURE` and `ERROR`
    /// are both a failure, `PENDING` and `EXPECTED` both still running, and a
    /// commit no check ran on is `none` — drawn like success, as nothing.
    public enum State: String, Sendable, Equatable {
        case success, failure, pending, none
    }

    public var state: State
    /// The default branch's name — what the celebration calls it.
    public var branch: String
    public var headOid: String
    /// The head commit author's login; nil when the commit's email is linked
    /// to no GitHub account.
    public var author: String?

    public init(state: State, branch: String, headOid: String, author: String?) {
        self.state = state
        self.branch = branch
        self.headOid = headOid
        self.author = author
    }
}

/// A repository as one read found it: the three counts the face shows, and the
/// newest few stargazers, forks and open PRs the event detector compares
/// against the last snapshot.
///
/// The lists are the query's `last: 20` windows, oldest → newest the way the
/// connections page them, so they are NOT the whole history — the counts are
/// the totals, the lists are only the tail.
public struct GitHubRepoState: Sendable, Equatable {
    public var nameWithOwner: String
    public var stars: Int
    public var forks: Int
    public var openPRs: Int
    public var stargazers: [Stargazer]
    public var forkEvents: [ForkEvent]
    public var openPRNumbers: [OpenPR]
    /// The default branch's CI; nil when the repository has no default
    /// branch (an empty one) to ask about.
    public var ci: GitHubCI?

    public init(
        nameWithOwner: String, stars: Int, forks: Int, openPRs: Int,
        stargazers: [Stargazer] = [], forkEvents: [ForkEvent] = [], openPRNumbers: [OpenPR] = [],
        ci: GitHubCI? = nil
    ) {
        self.nameWithOwner = nameWithOwner
        self.stars = stars
        self.forks = forks
        self.openPRs = openPRs
        self.stargazers = stargazers
        self.forkEvents = forkEvents
        self.openPRNumbers = openPRNumbers
        self.ci = ci
    }
}

/// Where a repository's state comes from.
///
/// A protocol rather than the API itself, the seam `ZaiUsageReporting` is: the
/// connector and the faces are tested against a state and never reach the
/// network.
public protocol GitHubReporting: Sendable {
    /// The repository's state, or nil when there is no token to ask with.
    func state(of repo: String) async throws -> GitHubRepoState?
}

/// GitHub's GraphQL endpoint, asked once per read.
///
/// GraphQL rather than REST because REST cannot answer the question: without a
/// token it allows 60 requests an hour per IP, `open_issues_count` mixes PRs
/// with issues, and it has no stargazer logins. One query here carries the
/// counts and the three tails, well inside the 5 000 points an hour a
/// fine-grained PAT gets.
public struct GitHubAPI: GitHubReporting {
    public static let endpoint = URL(string: "https://api.github.com/graphql")!

    /// The spec's query, verbatim. `stargazers` pages oldest → newest by
    /// `starredAt`, so `last: 20` is the newest twenty; the forks are ordered
    /// explicitly for the same reason, and `openPRs` is an alias because the
    /// unaliased `pullRequests` already carries the count. The default
    /// branch's head commit carries the CI: its checks' rollup, its oid (a
    /// failure's identity) and its author's account.
    static let query = """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        nameWithOwner
        stargazerCount
        forkCount
        pullRequests(states: OPEN) { totalCount }
        stargazers(last: 20) { edges { starredAt node { login } } }
        forks(last: 20, orderBy: {field: CREATED_AT, direction: ASC}) { nodes { createdAt owner { login } } }
        openPRs: pullRequests(states: OPEN, last: 20) { nodes { number author { login } } }
        defaultBranchRef { name target { ... on Commit { oid author { user { login } } statusCheckRollup { state } } } }
      }
    }
    """

    public enum Failure: Error, Equatable, Sendable {
        /// The endpoint answered, and the answer was no — 401 for a refused
        /// or expired token, 403 / 502 for a rate limit or an outage.
        case status(Int)
        /// A 200 carrying an `errors` array: the first message, as GitHub
        /// words it ("Could not resolve to a Repository …").
        case graphQL(String)
        /// A repo that is not `owner/name`, refused before the wire.
        case badRepo(String)
    }

    private let transport: any Transport
    /// Read on every read rather than held, like the z.ai key: a token pasted
    /// into the settings takes effect at the next poll, and the value never
    /// sits in a long-lived struct.
    private let token: @Sendable () -> String?

    public init(transport: any Transport, token: @escaping @Sendable () -> String?) {
        self.transport = transport
        self.token = token
    }

    public func state(of repo: String) async throws -> GitHubRepoState? {
        // No token, no traffic: the tile shows `no token` until one is pasted.
        guard let token = token(), !token.isEmpty else { return nil }

        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw Failure.badRepo(repo)
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // GitHub refuses a request without a User-Agent.
        request.setValue("PixelClockTiles", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": Self.query,
            "variables": ["owner": String(parts[0]), "name": String(parts[1])],
        ])

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw Failure.status(response.statusCode)
        }
        return try Self.decode(data, repo: repo)
    }

    // MARK: - The answer

    static func decode(_ data: Data, repo: String) throws -> GitHubRepoState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Not an ISO 8601 date: \(text)"
                )
            }
            return date
        }
        let envelope = try decoder.decode(Envelope.self, from: data)

        // GraphQL reports a missing repository as a 200 with `errors` — the
        // status line says nothing, the body says everything.
        if let first = envelope.errors?.first {
            throw Failure.graphQL(first.message)
        }
        // No errors and no repository is not a shape GitHub documents; it is
        // still a repo that did not resolve.
        guard let repository = envelope.data?.repository else {
            throw Failure.badRepo(repo)
        }

        return GitHubRepoState(
            nameWithOwner: repository.nameWithOwner,
            stars: repository.stargazerCount,
            forks: repository.forkCount,
            openPRs: repository.pullRequests.totalCount,
            stargazers: repository.stargazers.edges.map {
                Stargazer(login: $0.node.login, starredAt: $0.starredAt)
            },
            forkEvents: repository.forks.nodes.map {
                ForkEvent(login: $0.owner.login, createdAt: $0.createdAt)
            },
            // A deleted account's PR has a null author; GitHub's own UI
            // calls it "ghost".
            openPRNumbers: repository.openPRs.nodes.map {
                OpenPR(number: $0.number, author: $0.author?.login ?? "ghost")
            },
            ci: repository.defaultBranchRef.flatMap(Self.ci)
        )
    }

    /// The branch's head as the lamp reads it. A target that is not a commit
    /// (the inline fragment matched nothing) has no oid and is no CI.
    private static func ci(_ ref: Repository.BranchRef) -> GitHubCI? {
        guard let target = ref.target, let oid = target.oid else { return nil }
        let state: GitHubCI.State = switch target.statusCheckRollup?.state {
        case "SUCCESS": .success
        case "FAILURE", "ERROR": .failure
        case "PENDING", "EXPECTED": .pending
        default: .none
        }
        return GitHubCI(state: state, branch: ref.name, headOid: oid, author: target.author?.user?.login)
    }

    /// GitHub's `DateTime` is whole-second ISO 8601; the fractional form is
    /// accepted too rather than failing a whole read over a format drift.
    private static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private struct Envelope: Decodable {
        struct Payload: Decodable { let repository: Repository? }
        struct Message: Decodable { let message: String }
        let data: Payload?
        let errors: [Message]?
    }

    private struct Login: Decodable { let login: String }

    private struct Repository: Decodable {
        struct Count: Decodable { let totalCount: Int }
        struct StarEdge: Decodable { let starredAt: Date; let node: Login }
        struct Stars: Decodable { let edges: [StarEdge] }
        struct ForkNode: Decodable { let createdAt: Date; let owner: Login }
        struct Forks: Decodable { let nodes: [ForkNode] }
        struct PRNode: Decodable { let number: Int; let author: Login? }
        struct PRs: Decodable { let nodes: [PRNode] }
        struct BranchRef: Decodable {
            struct Author: Decodable { let user: Login? }
            struct Rollup: Decodable { let state: String }
            /// Every field optional: a non-commit target decodes as `{}`.
            struct Target: Decodable {
                let oid: String?
                let author: Author?
                let statusCheckRollup: Rollup?
            }

            let name: String
            let target: Target?
        }

        let nameWithOwner: String
        let stargazerCount: Int
        let forkCount: Int
        let pullRequests: Count
        let stargazers: Stars
        let forks: Forks
        let openPRs: PRs
        /// Null for an empty repository; absent from an answer recorded
        /// before the query asked for it.
        let defaultBranchRef: BranchRef?
    }
}
