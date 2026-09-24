import Foundation

/// Which kind of arrival a celebration names — ggen's `kind`.
public enum GitHubEventKind: String, Sendable, CaseIterable {
    case star, fork, pr
}

/// The TC002 GitHub face (spec "The faces — F2 / TC002").
///
/// The design was signed off in the browser and on the clock as the frames
/// the `tc002-face-mockup` skill's `github/ggen.py` computes;
/// `GitHubFaceOracleTests` holds this type to them pixel for pixel and delay
/// for delay. Every constant is ggen's, and a change of design starts THERE.
///
/// Two timelines, each ONE 52×16 GIF, because what must stay in step lives in
/// one GIF:
///
/// - **ambient**: the star count as the hero (rows 0–8) and a ticker line
///   (rows 11–15) rotating the repository's name, its forks and its open PRs,
///   each line bringing its own icon (Hybrid);
/// - **celebration**: an interruption's scene — the event's icon, `+N` as the
///   hero, and a ticker naming who.
///
/// The icons are drawn in `GitHubGlyphs.swift`, the timelines in
/// `GitHubFaceTimeline.swift`. The pieces ggen takes from `wgen.py` — the
/// glyph tables, a line's runs, `compose`, the ticker's timing — are the
/// weather face's own Swift, reused rather than copied.
public enum GitHubFace {
    public typealias Frame = WeatherFace.Frame

    /// The ambient page's dwell per ticker state. Fixed: 10 s is what the user
    /// signed off in the mockup and on the clock (2026-09-23), and the spec
    /// gives the tile no setting for it.
    public static let ambientDwellMilliseconds = 10_000

    // MARK: - Colours (GitHub's own: star gold, fork blue, open-PR green)

    /// Gold as the panel shows it: GitHub's #E3B341 read orange on the LEDs,
    /// whose red channel dominates; #FFD84A was picked on the clock.
    static let starInk = WeatherFace.rgb(0xFF_D8_4A)
    static let forkInk = WeatherFace.rgb(0x58_A6_FF)
    static let prInk = WeatherFace.rgb(0x3F_B9_50)
    static let whiteInk = WeatherFace.rgb(0xE8_E8_E8)
    /// The person glyph before a login: grey, so it cannot be taken for an
    /// event's own colour.
    static let personInk = WeatherFace.rgb(0x90_90_90)
    static let markInk = WeatherFace.rgb(0xB8_B8_B8)
    static let shineInk = WeatherFace.rgb(0xFF_FF_FF)
    /// The default branch's CI, in GitHub's own check colours. Success has
    /// none: the lamp is absent then, like a repo without checks.
    static let ciFailInk = WeatherFace.rgb(0xF8_51_49)
    static let ciPendingInk = WeatherFace.rgb(0xD2_99_22)

    static let areaWidth = WeatherFace.areaWidth
    static let height = WeatherFace.height

    // MARK: - The timelines

    /// The ambient page: the repository as `state` has it, `no token` when
    /// there is no token to ask with, and, when there is no state, why —
    /// `problem`'s label, `no data` when none is given. The tile's Show
    /// toggles decide which counts the ticker carries and whether the CI
    /// badge is drawn; a part GitHub withheld from the token is hidden the
    /// same way, rather than drawn as a zero.
    public static func timeline(
        ambient state: GitHubRepoState?, noToken: Bool, config: GitHubTileConfig,
        dwellMilliseconds: Int = ambientDwellMilliseconds, problem: GitHubProblem? = nil
    ) -> [Frame] {
        let withheld = state?.withheld ?? []
        let show = Shown(
            forks: config.showForks && !withheld.contains(.metadata),
            prs: config.showPRs && !withheld.contains(.pullRequests),
            ci: config.showCI && !withheld.contains(.checks)
        )
        return ambient(
            state, shortName: config.shortName, hasToken: !noToken, problem: problem, show: show,
            main: config.mainWatch, changeMilliseconds: dwellMilliseconds
        )
    }

    /// What the ambient ticker carries beside the name and the hero — ggen's
    /// `Config.show_*`.
    struct Shown {
        var forks = true
        var prs = true
        var ci = true
    }

    /// A celebration of `count` arrivals of `kind`. `who` are the logins,
    /// newest first; for PRs, `prNumbers` are theirs, in the same order.
    public static func celebration(
        kind: GitHubEventKind, count: Int, who: [String], prNumbers: [Int], celebrateMilliseconds: Int
    ) -> [Frame] {
        celebrate(kind, count: count, who: who, prNumbers: prNumbers, celebrateMilliseconds: celebrateMilliseconds)
    }

    /// The celebration of one kind of what `events` holds, for the tile's
    /// length. The count is the burst's — it may pass the logins the page
    /// could name (`+25`, naming three).
    public static func celebration(kind: GitHubEventKind, events: GitHubEvents, config: GitHubTileConfig) -> [Frame] {
        let arrival = arrivals(kind, in: events)
        return celebration(
            kind: kind, count: arrival.count, who: arrival.who, prNumbers: arrival.prNumbers,
            celebrateMilliseconds: config.celebrationSeconds * 1000
        )
    }

    /// The default branch failing: the failed-check icon, `ci` as the hero,
    /// then `<branch> fail`, then the head commit's author when the commit
    /// names one.
    public static func ciCelebration(branch: String, author: String?, celebrateMilliseconds: Int) -> [Frame] {
        celebrateCI(branch: branch, author: author, celebrateMilliseconds: celebrateMilliseconds)
    }

    static func arrivals(_ kind: GitHubEventKind, in events: GitHubEvents)
        -> (count: Int, who: [String], prNumbers: [Int])
    {
        switch kind {
        case .star: (max(events.newStarCount, events.newStars.count), events.newStars, [])
        case .fork: (max(events.newForkCount, events.newForks.count), events.newForks, [])
        case .pr: (events.newPRs.count, events.newPRs.map(\.author), events.newPRs.map(\.number))
        }
    }

    // MARK: - The delivery

    /// Which pages each kind interrupts: a star reaches every page the app
    /// owns, a fork or a PR only the tile's own — in this order.
    static let interruptionOrder: [(GitHubEventKind, Interruption<UlanziScene>.Scope)] = [
        (.star, .everyPage), (.fork, .ownPage), (.pr, .ownPage),
    ]

    /// The ambient page, plus one interruption per kind of arrival the read
    /// found. An interruption holds its pages for the tile's celebration
    /// length or its timeline, whichever is longer: a marquee always finishes
    /// its pass.
    public static func delivery(for reading: GitHubReading) -> UlanziDelivery {
        let ambient: [Frame] = switch reading.content {
        case .noToken: timeline(ambient: nil, noToken: true, config: reading.config)
        case .badToken, .noRepo, .noData:
            timeline(ambient: nil, noToken: false, config: reading.config, problem: reading.content.problem)
        case let .state(state): timeline(ambient: state, noToken: false, config: reading.config)
        }
        func interruption(_ frames: [Frame], _ scope: Interruption<UlanziScene>.Scope) -> Interruption<UlanziScene> {
            let length = TimeInterval(frames.reduce(0) { $0 + $1.milliseconds }) / 1000
            return Interruption(
                scene: scene(frames), scope: scope,
                duration: max(TimeInterval(reading.config.celebrationSeconds), length)
            )
        }
        var interruptions = interruptionOrder.compactMap { kind, scope -> Interruption<UlanziScene>? in
            guard arrivals(kind, in: reading.events).count > 0 else { return nil }
            return interruption(celebration(kind: kind, events: reading.events, config: reading.config), scope)
        }
        // A failing default branch last, on the tile's own page only, like a
        // fork or a PR.
        if let failure = reading.events.ciFailure {
            let frames = ciCelebration(
                branch: failure.branch, author: failure.author,
                celebrateMilliseconds: reading.config.celebrationSeconds * 1000
            )
            interruptions.append(interruption(frames, .ownPage))
        }
        return UlanziDelivery(scene: scene(ambient), interruptions: interruptions)
    }

    /// A timeline as the one page the TC002 plays by itself: a full-frame
    /// 52×16 GIF at the panel's origin. Should the GIF fail to encode — it
    /// cannot for these frames: a handful of colours, one size — the page
    /// falls back to the first frame as the plain bitmap (as
    /// `UsageFace.delivery` does).
    static func scene(_ frames: [Frame]) -> UlanziScene {
        guard let gif = try? WeatherFace.gif(frames) else {
            return UlanziScene(frames: [UlanziFrame(duration: 5, draw: [frames[0].canvas.drawCommands()])])
        }
        let image = UlanziImage(
            base64: gif.base64EncodedString(),
            isAnimated: frames.count > 1,
            frameCount: frames.count,
            pixelSize: (width: PixelCanvas.width, height: PixelCanvas.height),
            position: (x: 0, y: 0)
        )
        return UlanziScene(frames: [UlanziFrame(duration: 5, image: [image])])
    }

    // MARK: - Reading

    /// The hero's number: exact below 10 000 — four big digits are all that
    /// fit beside the big star — then whole thousands, then millions.
    static func compact(_ n: Int) -> String {
        if n < 10_000 { return "\(n)" }
        if n < 1_000_000 { return "\(floorDiv(n, 1000))k" }
        return "\(floorDiv(n, 1_000_000))m"
    }

    /// What the ticker calls the repository: the short name when one is set
    /// (an empty one is not), otherwise the name without its owner —
    /// lowercased, because the font draws lowercase. A name wider than the
    /// area edge-marquees.
    static func displayName(_ repo: String, shortName: String?) -> String {
        let name = shortName.flatMap { $0.isEmpty ? nil : $0 } ?? repo.components(separatedBy: "/").last!
        return name.lowercased()
    }

    /// Whether the ticker's name line edge-marquees on the TC002: the same
    /// measure `lineState` takes, the proportional face against the 34 px
    /// area. The settings say it beside the short-name field.
    public static func nameScrolls(repo: String, shortName: String?) -> Bool {
        WeatherFace.partsWidth([part(displayName(repo, shortName: shortName), whiteInk)]) > areaWidth
    }

    // MARK: - The right area

    /// Rows 0–8 of the right area: `text` in the 5×9 face, after its mark —
    /// the big star when `star` — and a 2 px gap.
    static func hero(_ text: String, _ ink: Pixel, star: Bool = false, mark: Character? = nil) -> PixelCanvas {
        var area = PixelCanvas(width: areaWidth, height: height)
        var x = 0
        if let mark = star ? "★" : mark {
            area.drawText(String(mark), at: .zero, ink: ink, font: PixelFont.big)
            x = PixelFont.big.advance(for: mark) + 1
        }
        area.drawText(text, at: PixelPoint(x: x, y: 0), ink: ink, font: PixelFont.big)
        return area
    }

    /// The marks followed by 1 px instead of a value's 2 (tc002-tile-screen).
    static let marks: Set<String> = ["☺"]

    /// One run of a ticker line; a grey word label gets 3 px after it, a mark
    /// 1 px, a value 2 px — ggen's `gap_after`.
    static func part(_ text: String, _ ink: Pixel) -> WeatherFace.Part {
        WeatherFace.Part(text: text, ink: ink, gap: marks.contains(text) ? 1 : nil)
    }

    /// A 5 px line, 34 px wide.
    static func lineArea(_ parts: [WeatherFace.Part]) -> PixelCanvas {
        WeatherFace.line(parts)
    }
}
