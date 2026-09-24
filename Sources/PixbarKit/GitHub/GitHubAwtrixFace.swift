import Foundation

/// The buzzer's jingle for each kind of arrival — the Super Mario Bros sounds
/// the spec names, as the widely circulated RTTTL transcriptions, cut to at
/// most twelve notes so a celebration stays a jingle.
///
/// RTTTL because the TC001's buzzer plays nothing else (an uploaded `.mp3`
/// never reaches the sound path — docs/HANDOFF.md, "Hardware"). The kit has no
/// RTTTL parser; `GitHubAwtrixFaceTests` holds the shape.
public enum GitHubJingle {
    /// The coin: B5 then a held E6.
    public static let star = "coin:d=8,o=6,b=180:b5,4e6"
    /// The 1-up.
    public static let fork = "oneup:d=16,o=6,b=150:e,g,e7,c7,d7,g7"
    /// The power-up's first two arpeggios (the whole of it is eighteen notes).
    public static let pr = "powerup:d=16,o=5,b=200:g,c6,e6,g6,c7,g6,g#,c6,d#6,g#6,c7,g#6"
    /// A failing default branch: the game-over motif, falling C-G-E then the
    /// three wavering triplets, twelve notes.
    public static let ciFailure = "gameover:d=8,o=5,b=120:4c6,4g,4e,a,b,a,g#,a#,g#,g,f,2g"
}

/// The TC001 GitHub face (spec "The faces — F2 / TC001").
///
/// The TC001 has what the TC002 lacks — a notification surface and a buzzer —
/// so its face is two plain things rather than one animated page: the star
/// count as an app in the clock's own loop, and each kind of arrival as a
/// notification over whatever is on screen, carrying its jingle.
///
/// No `★` in the text, although the spec writes `★1234`: the firmware's font
/// (AwtrixFont, TomThumb 3×5 plus Latin-1 and Cyrillic) has no such glyph, and
/// its UTF-8 decoder (`utf8ascii`) drops the three bytes without a trace, so
/// `★1234` draws as `1234` anyway. The count reads as stars the way the
/// Claude app's figure reads as Claude's: by the icon beside it and the gold
/// it is drawn in — the TC002 hero's gold. A celebration names its kind in a
/// word instead (`stars`, `fork`, `PR`), as the TC002 ticker does.
public enum GitHubAwtrixFace {
    /// The bundled art: ggen's `mark` octicon at half scale, drawn by
    /// `Scripts/make_github_icon.py`. Not named `github`: an icon already on
    /// the flash under the same name is used as it is, and a user's own
    /// `github.gif` is the likeliest file to be there.
    public static let icon = "GitHubMark"

    static let starColour = "#FFD84A"
    static let forkColour = "#58A6FF"
    static let prColour = "#3FB950"
    /// GitHub's failed-check red, the TC002 badge's.
    static let ciFailColour = "#F85149"
    /// GitHub's pending amber, the TC002 lamp's.
    static let ciPendingColour = "#D29922"
    /// The TC002 labels' grey: `no token` / `no data` are a state, not a
    /// figure, and must not look like one.
    static let quietColour = "#606060"

    /// The app, and one notification per kind of arrival — stars, forks, PRs,
    /// in the TC002's order, then a newly failing default branch. Each holds
    /// for the tile's celebration length; the firmware scrolls a line that
    /// does not fit, as it does for every other notification this app sends.
    public static func draw(_ reading: GitHubReading, appName: String) -> AwtrixDelivery {
        let (text, colour) = switch reading.content {
        case .noToken: ("no token", quietColour)
        // The TC002's label words: which failure it is, not one for all.
        case .badToken, .noRepo, .noData: (reading.content.problem?.label ?? "no data", quietColour)
        case let .state(state): mainLine(state, reading.config.mainWatch)
        }
        let seconds = reading.config.celebrationSeconds
        func notification(_ line: String, jingle: String, colour: String) -> Interruption<AwtrixScene> {
            Interruption(
                scene: AwtrixScene(
                    text: line, icon: .bundled(icon), jingle: jingle, duration: seconds,
                    color: colour, surface: .notification
                ),
                // A notification covers whatever app is on screen, which is
                // what `everyPage` means; the session ignores scope here.
                scope: .everyPage, duration: TimeInterval(seconds)
            )
        }
        var interruptions = GitHubFace.interruptionOrder.compactMap { kind, _ -> Interruption<AwtrixScene>? in
            guard let line = celebration(kind, in: reading.events) else { return nil }
            return notification(line, jingle: jingle(kind), colour: ink(kind))
        }
        // A failing default branch rings last, as the TC002 shows it last.
        // No lamp here: the app is one text line (spec, "TC001").
        if let failure = reading.events.ciFailure {
            interruptions.append(notification(ciLine(failure), jingle: GitHubJingle.ciFailure, colour: ciFailColour))
        }
        return AwtrixDelivery(
            text: text, icon: .bundled(icon), color: colour, surface: .app(appName),
            // Half an hour, as the z.ai app: the page clears itself off the
            // loop when the Mac stops feeding it.
            lifetime: 1_800,
            interruptions: interruptions
        )
    }

    /// The app's one line: the Main watch's metric — a count in its colour,
    /// or the CI in words (the firmware's font has capitals, so `CI` is
    /// spelled as the user wrote it).
    static func mainLine(_ state: GitHubRepoState, _ watch: GitHubMainWatch) -> (String, String) {
        switch watch {
        case .stars: return (GitHubFace.compact(state.stars), starColour)
        case .prs: return (GitHubFace.compact(state.openPRs), prColour)
        case .forks: return (GitHubFace.compact(state.forks), forkColour)
        case .ci:
            switch state.ci?.state {
            case .success?: return ("CI passed", prColour)
            case .pending?: return ("CI processed", ciPendingColour)
            case .failure?: return ("CI failed", ciFailColour)
            case GitHubCI.State.none?, nil: return ("no CI", quietColour)
            }
        }
    }

    /// `stars +2 @alice +1 more`: what happened, how many, and who — the
    /// first login only, the rest counted, because a notification scrolls and
    /// every login is seconds of scroll. One new PR is named by its number
    /// (`PR #42 @dave`). Nil when nothing of `kind` arrived.
    static func celebration(_ kind: GitHubEventKind, in events: GitHubEvents) -> String? {
        let arrival = GitHubFace.arrivals(kind, in: events)
        guard arrival.count > 0 else { return nil }
        let head: String
        if kind == .pr, arrival.prNumbers.count == 1 {
            head = "PR #\(arrival.prNumbers[0])"
        } else {
            let noun = switch kind {
            case .star: arrival.count == 1 ? "star" : "stars"
            case .fork: arrival.count == 1 ? "fork" : "forks"
            case .pr: arrival.count == 1 ? "PR" : "PRs"
            }
            head = "\(noun) +\(arrival.count)"
        }
        guard let first = arrival.who.first else { return head }
        let rest = arrival.who.count - 1
        return rest > 0 ? "\(head) @\(first) +\(rest) more" : "\(head) @\(first)"
    }

    /// `CI fail main @dave`; the author is left out when the commit is
    /// linked to no account.
    static func ciLine(_ failure: GitHubCIFailure) -> String {
        let head = "CI fail \(failure.branch)"
        guard let author = failure.author else { return head }
        return "\(head) @\(author)"
    }

    static func jingle(_ kind: GitHubEventKind) -> String {
        switch kind {
        case .star: GitHubJingle.star
        case .fork: GitHubJingle.fork
        case .pr: GitHubJingle.pr
        }
    }

    static func ink(_ kind: GitHubEventKind) -> String {
        switch kind {
        case .star: starColour
        case .fork: forkColour
        case .pr: prColour
        }
    }
}
