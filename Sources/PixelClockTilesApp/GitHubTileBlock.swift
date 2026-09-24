import PixelClockKit
import SwiftUI

// The GitHub tile's own block: the repository it watches, what the face calls
// it, how long a new star holds the clock, and the one token every GitHub tile
// shares. The model does the storing — the block renders and reports.

/// What the `?` beside the token field says, and where its link goes.
///
/// The link is GitHub's own prefilled form for a fine-grained token: the name,
/// the description, a year's expiry and the read permissions the tile needs.
/// Repository access cannot be preset by a link, so the text says to pick it.
enum GitHubTokenHelp {
    static let createURL = URL(
        string: "https://github.com/settings/personal-access-tokens/new?name=PixelClockTiles&description=Read-only+stars,+forks,+PRs+and+CI+for+the+GitHub+tile&expires_in=366&metadata=read&pull_requests=read&statuses=read&checks=read"
    )!

    static let text = """
        Public repositories: a fine-grained token with Repository access → \
        Public repositories. No permissions needed.

        Private repositories: Only select repositories, with Metadata: read, \
        Pull requests: read, Commit statuses: read and Checks: read — the last \
        two feed the CI badge.

        A link cannot preset the repository access: pick it on the page.
        """
}

/// The shape a repository is typed in, and the tile instance it becomes.
enum GitHubRepoName {
    /// Built per call: a `Regex` is not `Sendable`, so it cannot be a stored
    /// static under strict concurrency.
    private static var shape: Regex<Substring> { /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/ }

    /// The typed repository without the whitespace around it, or nil when it
    /// is not `owner/name`.
    static func repo(from typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.wholeMatch(of: shape) == nil ? nil : trimmed
    }

    /// The tile's instance: the repository lowercased, because GitHub reads
    /// `Owner/Name` and `owner/name` as one — and so must a clock's duplicate
    /// check.
    static func instance(from typed: String) -> String? {
        repo(from: typed)?.lowercased()
    }
}

/// The repository, the short name, the celebration, and the shared token.
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
    /// Writes the tile's own settings; the repository is not the block's to
    /// change.
    let onConfig: (GitHubTileConfig) -> Void
    /// Hands the token to the model, which files it for every GitHub tile.
    let onSaveToken: (String) -> Void

    @State private var typedToken = ""
    @State private var shortName = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Section("Repository") {
            // Read-only: the repository is the tile's identity — its key —
            // and another one is another tile.
            LabeledContent("Repository", value: config.repo)
            // Written as it is typed, like every other control here, so the
            // preview beside it follows the name.
            TextField("Short name", text: $shortName, prompt: Text("optional"))
            if let note = Self.scrollNote(repo: config.repo, shortName: shortName) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Celebrate for", selection: Binding(
                get: { config.celebrationSeconds },
                set: { seconds in
                    var edited = config
                    edited.celebrationSeconds = seconds
                    onConfig(edited)
                }
            )) {
                ForEach(Self.celebrationChoices(config), id: \.self) {
                    Text("\($0) s").tag($0)
                }
            }
        }
        .onAppear { shortName = config.shortName ?? "" }
        .onChange(of: config.repo) { shortName = config.shortName ?? "" }
        .onChange(of: shortName) { saveShortName() }
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Token").font(.caption).foregroundStyle(.secondary)
                    GitHubTokenHelpMark(ink: PixelInk.secondary(dark: scheme == .dark))
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
    private static func celebrationChoices(_ config: GitHubTileConfig) -> [Int] {
        let offered = GitHubTileConfig.celebrationChoices
        return offered.contains(config.celebrationSeconds)
            ? offered : (offered + [config.celebrationSeconds]).sorted()
    }
}

/// The pixel `?` beside the token field. Hovering shows the help in a
/// popover, because the help carries a link and `.help` cannot.
struct GitHubTokenHelpMark: View {
    let ink: UInt32
    @State private var showing = false

    var body: some View {
        PixelArt(map: PanelGlyph.question, palette: PanelGlyph.questionPalette(ink), pixel: 2)
            .contentShape(Rectangle())
            .onHover { inside in if inside { showing = true } }
            .onTapGesture { showing.toggle() }
            .accessibilityElement()
            .accessibilityLabel("How to make a token")
            .accessibilityAddTraits(.isButton)
            .popover(isPresented: $showing, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(GitHubTokenHelp.text)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Create a token", destination: GitHubTokenHelp.createURL)
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
