import Foundation
import PixbarKit

/// The secrets tiles read through — a z.ai tile's own key, the GitHub token
/// every GitHub tile shares — and the GitHub tiles themselves, which are
/// added and moved by repository name.
@MainActor
final class TileSecrets: ObservableObject {
    private let secrets: any SecretStoring
    /// Where the GitHub connector keeps each tile's snapshot and diagnosis.
    private let defaults: UserDefaults
    private let book: TileBook

    init(secrets: any SecretStoring, defaults: UserDefaults, book: TileBook) {
        self.secrets = secrets
        self.defaults = defaults
        self.book = book
    }

    // MARK: - The z.ai key

    /// What a paste did, as the detail surface says it.
    enum ZaiKeyOutcome: Equatable {
        case saved
        case removed
        /// The store refused, and the field says so — a paste the user
        /// believes was taken must not quietly never have been.
        case refused
    }

    /// The last paste's outcome, for the field to say it out loud.
    @Published private(set) var lastZaiKeyOutcome: ZaiKeyOutcome?

    /// The key a paste put in, taken out of the record's way: it goes to the
    /// secret store under the tile's own account, and the tile record
    /// remembers only the handle. A blank paste is the removal, so the one field is how
    /// a key is both given and taken back.
    @discardableResult
    func saveZaiKey(_ typed: String, for key: TileKey) -> ZaiKeyOutcome {
        let account = ZaiTileConfig.account(for: key)
        let pasted = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome: ZaiKeyOutcome
        do {
            if pasted.isEmpty {
                try secrets.remove(for: .tile(key))
                outcome = .removed
            } else {
                try secrets.save(pasted, for: .tile(key))
                outcome = .saved
            }
        } catch {
            outcome = .refused
        }
        lastZaiKeyOutcome = outcome

        // The policy stands; only the handle joins the record, derived the
        // same way the connector reads it back. A tile saved before any paste
        // still gets its config here — there is nothing to read first. The
        // usage face's settings the record already carries stay: a paste is
        // about the key, not about when the page shows its resets.
        if outcome != .refused, let policy = book.storedPolicy(of: key) {
            _ = book.saveTile(
                key: key, policy: policy,
                config: .zai(ZaiTileConfig(
                    keyAccount: account,
                    parameters: book.storedTile(key)?.config?.parameters ?? .standard
                ))
            )
        }
        return outcome
    }

    /// Whether a key stands behind this tile — as the field's presence line
    /// puts it, without ever saying what the key is.
    func hasZaiKey(for key: TileKey) -> Bool {
        secrets.secret(for: .tile(key)) != nil
    }

    // MARK: - The GitHub tiles

    /// What a token save did — the same three answers a z.ai paste gets.
    typealias TokenOutcome = ZaiKeyOutcome

    /// The last token save's outcome, for the field to say it out loud.
    @Published private(set) var lastGitHubTokenOutcome: TokenOutcome?

    /// The one token every GitHub tile reads through, filed under the
    /// connector's account and never a tile's. A blank save removes it.
    @discardableResult
    func saveGitHubToken(_ token: String) -> TokenOutcome {
        let account = SecretAccount.connector(GitHubConnector.connectorId)
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome: TokenOutcome
        do {
            if typed.isEmpty {
                try secrets.remove(for: account)
                outcome = .removed
            } else {
                try secrets.save(typed, for: account)
                outcome = .saved
            }
        } catch {
            outcome = .refused
        }
        lastGitHubTokenOutcome = outcome
        return outcome
    }

    /// Whether the shared token is stored — one answer for every GitHub tile.
    var hasGitHubToken: Bool {
        secrets.secret(for: .connector(GitHubConnector.connectorId)) != nil
    }

    /// Adds a GitHub tile for `owner/name`: the repository lowercased is the
    /// tile's instance, so one clock never carries a repository twice while
    /// another clock may carry it too. False for a malformed name or a
    /// duplicate.
    func addGitHubTile(repo typed: String, to clockId: UUID) -> Bool {
        guard let repo = GitHubRepoName.repo(from: typed),
            let instance = GitHubRepoName.instance(from: typed)
        else { return false }
        let outcome = book.addTile(
            GitHubConnector.connectorId, to: clockId, instance: instance,
            config: .github(GitHubTileConfig(repo: repo))
        )
        return outcome == .saved
    }

    /// Points a GitHub tile at another repository — the block's Repository
    /// field. A re-key, like `changeLampVPN`, because the repository is the
    /// key's instance: the tile keeps its place in the clock's order and its
    /// settings, the old repository's page leaves the clock, and the new one
    /// starts from a baseline, so nothing it already has is celebrated.
    func changeGitHubRepo(_ key: TileKey, to typed: String) -> TileBook.TileSaveOutcome {
        guard let record = book.storedTile(key), let policy = book.storedPolicy(of: key) else {
            return .refused("this tile is no longer on the clock")
        }
        guard let repo = GitHubRepoName.repo(from: typed), let instance = GitHubRepoName.instance(from: typed)
        else { return .refused("type the repository as owner/name") }
        var config = record.config?.github ?? GitHubTileConfig(repo: key.instance)
        config.repo = repo
        // Another spelling of the same repository is the same tile.
        guard instance != key.instance else { return book.saveTile(key: key, policy: policy, config: .github(config)) }
        let moved = TileKey(clockId: key.clockId, connectorId: key.connectorId, instance: instance)
        if book.tileRecords.contains(where: { $0.key == moved }) {
            return .refused("\(instance) is already on \(book.clocks().first { $0.id == key.clockId }?.name ?? "this clock")")
        }
        for stale in [key, moved] {
            defaults.removeObject(forKey: UserDefaultsGitHubSnapshots.key(for: stale))
            defaults.removeObject(forKey: UserDefaultsGitHubDiagnoses.key(for: stale))
        }
        return book.rekey(key, to: moved, config: .github(config))
    }

    /// What the tile's last read found wrong, for the clock's tile list —
    /// the failure, or the permission the token lacks. Written by the
    /// connector at every read.
    func gitHubDiagnosis(of key: TileKey) -> GitHubDiagnosis? {
        guard key.connectorId == GitHubConnector.connectorId else { return nil }
        return UserDefaultsGitHubDiagnoses(defaults: defaults).diagnosis(for: key)
    }
}
