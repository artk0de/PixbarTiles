import Foundation

/// What a GitHub tile's read hands its faces: the repository as it is now (or
/// why there is nothing to show), what arrived since the last read, and the
/// tile's own settings the faces draw with.
public struct GitHubReading: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        /// No token saved: nothing was asked.
        case noToken
        /// Asked and not answered — an outage, a refused token, a repository
        /// that does not resolve — or a tile with no repository to ask about.
        case noData
        case state(GitHubRepoState)
    }

    public var content: Content
    public var events: GitHubEvents
    public var config: GitHubTileConfig

    public init(content: Content, events: GitHubEvents = GitHubEvents(), config: GitHubTileConfig) {
        self.content = content
        self.events = events
        self.config = config
    }
}

/// How a GitHub reading is drawn on each clock model.
///
/// The TC002 face is `GitHubFace` — the `ggen.py` port, with a celebration
/// interruption per kind of arrival. The AWTRIX side is still a PLACEHOLDER
/// until Task 10: the counts as plain text, with no celebration; the TC001
/// app and its jingled notification replace it.
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

    /// The AWTRIX closure is replaced by Task 10; see the type's note.
    public static let standard = GitHubFaces(
        awtrix: { reading, appName in
            let name = reading.config.shortName ?? reading.config.repo
            let text = switch reading.content {
            case .noToken: "\(name) no token"
            case .noData: "\(name) no data"
            case let .state(state): "\(name) \(state.stars)"
            }
            return AwtrixDelivery(
                text: text, color: "#FFD84A", surface: .app(appName),
                // Half an hour, as the z.ai app: the page clears itself off
                // the loop when the Mac stops feeding it.
                lifetime: 1_800
            )
        },
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
    private let faces: GitHubFaces

    /// A record with no GitHub config falls back to its instance, which is
    /// the repository the tile was keyed by; a record with neither has no
    /// repository and reads `.noData`.
    public init(
        tile: TileRecord, source: any GitHubReporting, snapshots: any GitHubSnapshotStoring,
        faces: GitHubFaces = .standard
    ) {
        self.tile = tile.key
        self.config = tile.config?.github ?? GitHubTileConfig(repo: tile.key.instance)
        self.source = source
        self.snapshots = snapshots
        self.faces = faces
    }

    /// Throws only a cancellation — a run being torn down is not an answer to
    /// draw. Every other way of having nothing to show is a reading, so the
    /// face can say which one it is.
    ///
    /// The snapshot moves only on an answer. No token and a failure leave it
    /// as it was, so an outage celebrates what it missed, once, at the first
    /// read that gets through.
    public func read() async throws -> GitHubReading {
        guard !config.repo.isEmpty else { return GitHubReading(content: .noData, config: config) }
        let state: GitHubRepoState?
        do {
            state = try await source.state(of: config.repo)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return GitHubReading(content: .noData, config: config)
        }
        guard let state else { return GitHubReading(content: .noToken, config: config) }
        let (events, snapshot) = GitHubEventDetector.detect(state, since: snapshots.snapshot(for: tile))
        snapshots.save(snapshot, for: tile)
        return GitHubReading(content: .state(state), events: events, config: config)
    }

    public var awtrixFace: AwtrixFace<GitHubReading> {
        AwtrixFace { [faces, tile] in faces.awtrix($0, tile.tileId) }
    }

    public var ulanziFace: UlanziFace<GitHubReading>? {
        UlanziFace { [faces] in faces.ulanzi($0) }
    }
}
