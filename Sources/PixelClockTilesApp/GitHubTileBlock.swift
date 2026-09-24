import PixelClockKit
import SwiftUI

// The GitHub tile's own block: the repository it watches, what the face calls
// it, how long a new star holds the clock, and the one token every GitHub tile
// shares. The model does the storing — the block renders and reports.

/// What the `?` beside the token field says, and where its link goes.
///
/// The links are GitHub's own prefilled form for a fine-grained token — the
/// name, the description, a year's expiry and the resource owner
/// (`target_name`, the tile repository's owner) — one with no permissions for
/// public repositories and one with the reads a private repository needs.
/// GitHub documents `name`, `description`, `target_name`, `expires_in` and the
/// permission parameters; repository access cannot be preset by a link, so the
/// text says to pick it.
///
/// What it says was measured live on 2026-09-24 against GitHub's permission
/// table: with Public repositories the form shows no repository permissions
/// and none are needed; listing stargazers needs Contents: write, so a
/// read-only token never learns who starred — the `Starring` account
/// permission is about the user's own stars, not a repository's.
enum GitHubTokenHelp {
    enum Kind: CaseIterable {
        case publicRepos, privateRepos

        /// The link's words in the popover.
        var title: String {
            switch self {
            case .publicRepos: "Token for public repos"
            case .privateRepos: "Token for private repos"
            }
        }

        /// The repository permissions the form is prefilled with.
        fileprivate var permissions: String {
            switch self {
            case .publicRepos: ""
            case .privateRepos: "&metadata=read&pull_requests=read&statuses=read&checks=read&contents=read"
            }
        }
    }

    /// The prefilled form, aimed at `owner` when there is one.
    static func createURL(_ kind: Kind, owner: String?) -> URL {
        var text = "https://github.com/settings/personal-access-tokens/new?name=PixelClockTiles"
            + "&description=Read-only+stars,+forks,+PRs+and+CI+for+the+GitHub+tile&expires_in=366"
        if let owner {
            // Only unreserved characters pass: an owner must not be able to
            // end the parameter or start another.
            let encoded = owner.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["-", "_", ".", "~"]))
            text += "&target_name=\(encoded ?? "")"
        }
        return URL(string: text + kind.permissions)!
    }

    /// The owner of an `owner/name` repository, or nil while it is not one.
    static func owner(ofRepo repo: String) -> String? {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return String(parts[0])
    }

    static let text = """
        Public repositories: a fine-grained token with Repository access → \
        Public repositories. No permissions needed.

        Private repositories: Only select repositories, with Metadata: read, \
        Pull requests: read, Commit statuses: read, Checks: read (the CI \
        badge) and Contents: read (the default branch's commit and its author).

        Who starred is not visible to a read-only token (it needs Contents: \
        write); stars are counted instead.

        A link cannot preset the repository access: pick it on the page.
        """
}

/// The shape a repository is typed in, and the tile instance it becomes.
enum GitHubRepoName {
    /// Built per call: a `Regex` is not `Sendable`, so it cannot be a stored
    /// static under strict concurrency.
    private static var shape: Regex<Substring> { /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/ }

    /// The typed repository without the whitespace around it, a pasted
    /// GitHub URL reduced to its `owner/name`, or nil when it is not one.
    static func repo(from typed: String) -> String? {
        let reduced = normalised(typed)
        return reduced.wholeMatch(of: shape) == nil ? nil : reduced
    }

    /// What the field shows once a paste or a commit is read: a GitHub URL —
    /// `https://github.com/o/n`, `github.com/o/n/pull/12`, `…/o/n.git`,
    /// `git@github.com:o/n.git`, with or without `www.` — as `o/n`, the case
    /// kept (the instance lowercases it). Anything else comes back trimmed,
    /// for `repo(from:)` to refuse.
    static func normalised(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        var rest = Substring(trimmed)
        let ssh = "git@github.com:"
        if rest.lowercased().hasPrefix(ssh) {
            rest = rest.dropFirst(ssh.count)
        } else {
            for scheme in ["https://", "http://"] where rest.lowercased().hasPrefix(scheme) {
                rest = rest.dropFirst(scheme.count)
            }
            if rest.lowercased().hasPrefix("www.") { rest = rest.dropFirst(4) }
            guard rest.lowercased().hasPrefix("github.com/") else { return trimmed }
            rest = rest.dropFirst("github.com/".count)
        }
        // A query or a fragment is not part of the path.
        rest = rest.prefix { $0 != "?" && $0 != "#" }
        let segments = rest.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count >= 2 else { return trimmed }
        var name = segments[1]
        if name.lowercased().hasSuffix(".git") { name = name.dropLast(4) }
        return "\(segments[0])/\(name)"
    }

    /// The tile's instance: the repository lowercased, because GitHub reads
    /// `Owner/Name` and `owner/name` as one — and so must a clock's duplicate
    /// check.
    static func instance(from typed: String) -> String? {
        repo(from: typed)?.lowercased()
    }
}

/// The repository, the short name, the celebration, what the face shows and
/// what interrupts, and the shared token.
///
/// The token field is a SECURE field cleared once handled, as z.ai's is: what
/// stays on screen is a sentence about presence, and it is the same sentence
/// on every GitHub tile, because the token behind them is one.
struct GitHubTileBlock: View {
    let config: GitHubTileConfig
    /// Whether the shared token is stored.
    let hasToken: Bool
    /// What the last save did, when there is something to say.
    let outcome: AppModel.TokenOutcome?
    /// Writes the tile's own settings; the repository goes through `onRepo`.
    let onConfig: (GitHubTileConfig) -> Void
    /// Points the tile at another repository — a re-key the model may
    /// refuse, and says why in the window.
    let onRepo: (String) -> Void
    /// Hands the token to the model, which files it for every GitHub tile.
    let onSaveToken: (String) -> Void

    @State private var typedToken = ""
    @State private var typedRepo = ""
    @State private var shortName = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Section("Repository") {
            // Committed on Return, not per keystroke: every commit is a
            // re-key, and a half-typed name is another repository.
            TextField("Repository", text: $typedRepo, prompt: Text("owner/name"))
                .onSubmit(commitRepo)
            if typedRepo.isEmpty == false, GitHubRepoName.repo(from: typedRepo) == nil {
                Text("Type it as owner/name, or paste its GitHub URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Written as it is typed, like every other control here, so the
            // preview beside it follows the name.
            TextField("Short name", text: $shortName, prompt: Text("optional"))
            if let note = Self.scrollNote(repo: config.repo, shortName: shortName) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SteppedSlider(
                label: "Celebrate for",
                ladder: StepLadder(GitHubTileConfig.celebrationChoices.map(Double.init)),
                value: Double(config.celebrationSeconds),
                caption: { "\(Int($0)) s" },
                onCommit: { seconds in
                    var edited = config
                    edited.celebrationSeconds = Int(seconds)
                    onConfig(edited)
                }
            )
            // Where a star celebrates on a TC002: every page the app owns, or
            // only this tile's, as a fork or a PR. The TC001 shows every
            // celebration over whatever is up, so this changes nothing there.
            Toggle("Celebrate on all app pages", isOn: binding(\.celebrateOnAllPages))
        }
        .onAppear {
            shortName = config.shortName ?? ""
            typedRepo = config.repo
        }
        .onChange(of: config.repo) {
            shortName = config.shortName ?? ""
            typedRepo = config.repo
        }
        .onChange(of: shortName) { saveShortName() }
        // A pasted URL reads as the repository at once.
        .onChange(of: typedRepo) {
            let reduced = GitHubRepoName.normalised(typedRepo)
            if reduced != typedRepo.trimmingCharacters(in: .whitespacesAndNewlines),
                GitHubRepoName.repo(from: reduced) != nil {
                typedRepo = reduced
            }
        }
        Section("On the clock") {
            // The hero's metric — always shown, whatever its Show toggle.
            Picker("Main watch", selection: binding(\.mainWatch)) {
                ForEach(GitHubMainWatch.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            // Show: what the TC002 ticker carries beside the hero.
            LabeledContent("Show") {
                HStack {
                    Toggle("Forks", isOn: binding(\.showForks))
                    Toggle("PRs", isOn: binding(\.showPRs))
                    Toggle("CI", isOn: binding(\.showCI))
                }
            }
            // Notify: what interrupts the clock, on both models.
            LabeledContent("Notify") {
                HStack {
                    Toggle("Stars", isOn: binding(\.notifyStars))
                    Toggle("Forks", isOn: binding(\.notifyForks))
                    Toggle("PRs", isOn: binding(\.notifyPRs))
                    Toggle("CI failures", isOn: binding(\.notifyCI))
                }
            }
        }
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Token").font(.caption).foregroundStyle(.secondary)
                    GitHubTokenHelpMark(ink: PixelInk.secondary(dark: scheme == .dark), repo: config.repo)
                }
                Text(presenceLine)
                    .font(.caption)
                    .foregroundStyle(hasToken ? Color.primary : .secondary)
                HStack {
                    SecureField("github_pat_…", text: $typedToken)
                        .textFieldStyle(.roundedBorder)
                    Button("Save token") {
                        onSaveToken(typedToken)
                        // Handled is forgotten: a paste left in the field is
                        // the token on screen for no reason.
                        typedToken = ""
                    }
                    // Blank is how the token is taken back, so the button
                    // stays live once one is stored.
                    .disabled(hasToken == false
                        && typedToken.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if outcome == .refused {
                    Text("The secret store refused the token — try again.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var presenceLine: String {
        hasToken
            ? "Token saved — shared by every GitHub tile. Save a blank to remove it."
            : "No token yet — every GitHub tile reads through one."
    }

    /// One setting of the config, written through `onConfig` as it moves.
    private func binding<Value>(_ path: WritableKeyPath<GitHubTileConfig, Value>) -> Binding<Value> {
        Binding(
            get: { config[keyPath: path] },
            set: { value in
                var edited = config
                edited[keyPath: path] = value
                onConfig(edited)
            }
        )
    }

    private func commitRepo() {
        let reduced = GitHubRepoName.normalised(typedRepo)
        typedRepo = reduced
        guard reduced != config.repo else { return }
        onRepo(reduced)
    }

    private func saveShortName() {
        let trimmed = shortName.trimmingCharacters(in: .whitespaces)
        guard trimmed != (config.shortName ?? "") else { return }
        var edited = config
        edited.shortName = trimmed.isEmpty ? nil : trimmed
        onConfig(edited)
    }

    /// The sentence under the short-name field when the name the face would
    /// show is wider than the TC002's 34 px area — measured by the kit, in
    /// the face's own proportional font — or nil when it fits.
    static func scrollNote(repo: String, shortName: String?) -> String? {
        GitHubFace.nameScrolls(repo: repo, shortName: shortName)
            ? "Wider than the TC002's 34 px — the name will scroll."
            : nil
    }

    /// The offered lengths, plus a stored one the design does not offer — a
    /// picker whose selection matches no tag draws blank.
}

/// The pixel `?` beside the token field. Hovering shows the help in a
/// popover, because the help carries a link and `.help` cannot.
struct GitHubTokenHelpMark: View {
    let ink: UInt32
    /// The tile's repository, whose owner the forms are aimed at.
    let repo: String
    @State private var showing = false

    var body: some View {
        // The panel's own `?`, the one beside every control whose label cannot
        // say what it decides — this one's help just carries a link.
        PixelArt(map: PanelGlyph.question, palette: PanelGlyph.inkPalette(ink))
            .contentShape(Rectangle())
            .onHover { inside in if inside { showing = true } }
            .onTapGesture { showing.toggle() }
            .pointerStyle(.link)
            .accessibilityElement()
            .accessibilityLabel("How to make a token")
            .accessibilityAddTraits(.isButton)
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(GitHubTokenHelp.text)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(GitHubTokenHelp.Kind.allCases, id: \.self) { kind in
                        Link(
                            kind.title,
                            destination: GitHubTokenHelp.createURL(kind, owner: GitHubTokenHelp.owner(ofRepo: repo))
                        )
                    }
                }
                .padding(14)
                .frame(width: 320)
            }
    }
}

/// The sheet the store opens for a GitHub card: the repository first, because
/// it is the tile's identity and there is no tile without one.
struct GitHubRepoSheet: View {
    let refusal: String?
    let onAdd: (String) -> Void
    let onCancel: () -> Void

    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a GitHub tile").font(.headline)
            TextField("Repository", text: $typed, prompt: Text("owner/name"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
                // A pasted URL reads as the repository at once.
                .onChange(of: typed) {
                    let reduced = GitHubRepoName.normalised(typed)
                    if reduced != typed.trimmingCharacters(in: .whitespacesAndNewlines),
                        GitHubRepoName.repo(from: reduced) != nil {
                        typed = reduced
                    }
                }
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if typed.isEmpty == false, GitHubRepoName.repo(from: typed) == nil {
                Text("Type it as owner/name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(GitHubRepoName.repo(from: typed) == nil)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func add() {
        guard GitHubRepoName.repo(from: typed) != nil else { return }
        onAdd(typed)
    }
}
