import Foundation

/// What a GitHub tile's read hands its faces: the repository as it is now (or
/// why there is nothing to show), what arrived since the last read, and the
/// tile's own settings the faces draw with.
public struct GitHubReading: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        /// No token saved: nothing was asked.
        case noToken
        /// GitHub answered 401: a wrong, revoked or expired token.
        case badToken
        /// The repository is not there, or the token cannot see it — a typo,
        /// or a private repository outside the token's access.
        case noRepo
        /// Asked and not answered — an outage, a rate limit, anything else —
        /// or a tile with no repository to ask about.
        case noData
        case state(GitHubRepoState)

        /// Why there is no reading, as the face's label slot says it; nil
        /// for a state and for no token (which has its own page).
        public var problem: GitHubProblem? {
            switch self {
            case .badToken: .token
            case .noRepo: .repo
            case .noData: .data
            case .noToken, .state: nil
            }
        }
    }

    public var content: Content
    public var events: GitHubEvents
    public var config: GitHubTileConfig

    public init(content: Content, events: GitHubEvents = GitHubEvents(), config: GitHubTileConfig) {
        self.content = content
        self.events = events
        self.config = config
    }

    /// What is wrong with this read, when anything is: the failure, or the
    /// parts GitHub withheld from the token, each by the permission it wants.
    /// One answer for the tile list, the settings preview and the face.
    public var diagnosis: GitHubDiagnosis? {
        if let problem = content.problem {
            return GitHubDiagnosis(message: problem.sentence, isQuiet: false)
        }
        guard case let .state(state) = content, !state.withheld.isEmpty else { return nil }
        return GitHubDiagnosis(
            message: state.withheld.map(\.sentence).joined(separator: "\n"),
            isQuiet: state.withheld.allSatisfy(\.isQuiet)
        )
    }

    /// The settings preview's sentence under the picture.
    public var previewNote: String? { diagnosis?.message }
}

/// Why a GitHub tile has no reading — ggen's `PROBLEMS`.
public enum GitHubProblem: String, Sendable, CaseIterable {
    case token, repo, data

    /// What the face's label slot says — the TC002 and the TC001 alike.
    public var label: String {
        switch self {
        case .token: "bad token"
        case .repo: "no repo"
        case .data: "no data"
        }
    }

    /// The sentence the tile list and the settings preview say.
    public var sentence: String {
        switch self {
        case .token: "GitHub refused the token (401) — paste a new one"
        case .repo: "Repository not found, or the token can't see it (Repository access)"
        case .data: "GitHub could not be reached"
        }
    }
}

/// What a read found wrong, in one sentence, and whether it is only worth a
/// quiet word — the tile works as designed without what is missing.
public struct GitHubDiagnosis: Codable, Sendable, Equatable {
    public var message: String
    public var isQuiet: Bool

    public init(message: String, isQuiet: Bool) {
        self.message = message
        self.isQuiet = isQuiet
    }
}

/// Where each tile's last diagnosis is kept for the tile list to say.
public protocol GitHubDiagnosisStoring: Sendable {
    func diagnosis(for tile: TileKey) -> GitHubDiagnosis?
    func save(_ diagnosis: GitHubDiagnosis?, for tile: TileKey)
}

/// One JSON-encoded diagnosis per tile in `UserDefaults`, beside the
/// snapshots: the connector writes it at every read, the app's tile list
/// reads it.
public struct UserDefaultsGitHubDiagnoses: GitHubDiagnosisStoring, @unchecked Sendable {
    public static func key(for tile: TileKey) -> String {
        "githubDiagnosis.\(tile.tileId).\(tile.clockId.uuidString)"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func diagnosis(for tile: TileKey) -> GitHubDiagnosis? {
        guard let data = defaults.data(forKey: Self.key(for: tile)) else { return nil }
        return try? JSONDecoder().decode(GitHubDiagnosis.self, from: data)
    }

    public func save(_ diagnosis: GitHubDiagnosis?, for tile: TileKey) {
        guard let diagnosis, let data = try? JSONEncoder().encode(diagnosis) else {
            defaults.removeObject(forKey: Self.key(for: tile))
            return
        }
        defaults.set(data, forKey: Self.key(for: tile))
    }
}

/// How a GitHub reading is drawn on each clock model.
///
/// The TC002 face is `GitHubFace` — the `ggen.py` port, with a celebration
/// interruption per kind of arrival. The AWTRIX face is `GitHubAwtrixFace`:
/// an app in the loop, and a notification with a jingle per kind of arrival.
public struct GitHubFaces: Sendable {
    /// The reading and the tile's wire name, which is the AWTRIX app's name.
    public var awtrix: @Sendable (GitHubReading, String) -> AwtrixDelivery
    public var ulanzi: @Sendable (GitHubReading) -> UlanziDelivery

    public init(
        awtrix: @escaping @Sendable (GitHubReading, String) -> AwtrixDelivery,
        ulanzi: @escaping @Sendable (GitHubReading) -> UlanziDelivery
    ) {
        self.awtrix = awtrix
        self.ulanzi = ulanzi
    }

    public static let standard = GitHubFaces(
        awtrix: { GitHubAwtrixFace.draw($0, appName: $1) },
        ulanzi: { GitHubFace.delivery(for: $0) }
    )
}

/// One repository's stars, forks and open PRs, and what arrived since the
/// tile last looked.
///
/// One connector per tile: the factory builds it from the tile's own record,
/// so two repositories on one clock are two connectors, each with its own
/// snapshot, sharing the one token the source reads.
public struct GitHubConnector: Connector {
    public static let connectorId = "github"

    public let id = GitHubConnector.connectorId
    public let displayName = "GitHub"
    /// A minute. One GraphQL query costs a point of the 5 000 an hour a
    /// fine-grained token gets, so even a clockful of repositories stays far
    /// inside it; the tile's policy may slow it.
    public let defaultInterval: TimeInterval = 60
    /// Silent, in the sense this flag carries here: it is "the voice in the
    /// room", and it decides the whole tile's Focus and microphone holds, its
    /// quiet window, and whether a second clock may carry it. The TC001's
    /// buzzer jingle rides on a celebration notification on that one clock;
    /// nothing plays on the Mac, so the tile does not occupy the voice and may
    /// sit on several clocks (the spec's "Sound on the TC001" decision).
    /// Holding it would also freeze its numbers on the matrix through the
    /// night, the failure the weather tile was taken out of the rules for.
    public let isAudible = false
    /// Not ambient: a celebration is something to witness and a row's "Run
    /// now" something to fire, which is the case `isAmbient` names GitHub
    /// stars as its example of.
    public let isAmbient = false
    /// One tile per repository.
    public let instancing = Instancing.perKey

    /// The tile this connector runs — the snapshot's key and the page's name.
    public let tile: TileKey
    public let config: GitHubTileConfig

    private let source: any GitHubReporting
    private let snapshots: any GitHubSnapshotStoring
    private let diagnoses: (any GitHubDiagnosisStoring)?
    private let faces: GitHubFaces

    /// A record with no GitHub config falls back to its instance, which is
    /// the repository the tile was keyed by; a record with neither has no
    /// repository and reads `.noData`.
    public init(
        tile: TileRecord, source: any GitHubReporting, snapshots: any GitHubSnapshotStoring,
        diagnoses: (any GitHubDiagnosisStoring)? = nil, faces: GitHubFaces = .standard
    ) {
        self.tile = tile.key
        self.config = tile.config?.github ?? GitHubTileConfig(repo: tile.key.instance)
        self.source = source
        self.snapshots = snapshots
        self.diagnoses = diagnoses
        self.faces = faces
    }

    /// Throws only a cancellation — a run being torn down is not an answer to
    /// draw. Every other way of having nothing to show is a reading, so the
    /// face can say which one it is.
    ///
    /// The snapshot moves only on an answer. No token and a failure leave it
    /// as it was, so an outage celebrates what it missed, once, at the first
    /// read that gets through. The events the tile's Notify toggles turn off
    /// are dropped AFTER the snapshot moved: a toggle turned back on replays
    /// nothing.
    public func read() async throws -> GitHubReading {
        let reading = try await readState()
        diagnoses?.save(reading.diagnosis, for: tile)
        return reading
    }

    private func readState() async throws -> GitHubReading {
        guard !config.repo.isEmpty else { return GitHubReading(content: .noData, config: config) }
        let state: GitHubRepoState?
        do {
            state = try await source.state(of: config.repo)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return GitHubReading(content: Self.content(failing: error), config: config)
        }
        guard let state else { return GitHubReading(content: .noToken, config: config) }
        let (events, snapshot) = GitHubEventDetector.detect(state, since: snapshots.snapshot(for: tile))
        snapshots.save(snapshot, for: tile)
        return GitHubReading(content: .state(state), events: events.notifying(config), config: config)
    }

    /// A failed read, by name: 401 is the token, a repository GitHub will
    /// not show is the repo, and everything else — network, rate limit,
    /// outage — is no data.
    static func content(failing error: any Error) -> GitHubReading.Content {
        switch error as? GitHubAPI.Failure {
        case .status(401): .badToken
        case .notFound, .badRepo: .noRepo
        default: .noData
        }
    }

    public var awtrixFace: AwtrixFace<GitHubReading> {
        AwtrixFace { [faces, tile] in faces.awtrix($0, tile.tileId) }
    }

    public var ulanziFace: UlanziFace<GitHubReading>? {
        UlanziFace { [faces] in faces.ulanzi($0) }
    }
}
