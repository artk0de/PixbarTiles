import Foundation

// The TC002 GitHub face in time: ports of `ggen.py`'s `area_frame`, `rest`,
// `ticker_segments`, `lace`, `line_state`, `ambient`, `edge_marquee` and
// `celebration`, in that order. The ticker's timing (1 row per 60 ms step,
// 5 rows + 1 blank, the icon 3 rows a step) is wgen's, read off the weather
// face's constants.

extension GitHubFace {
    typealias Cel = WeatherFace.Cel

    /// An icon loop with an identity: ggen compares loops with `is`, and two
    /// states sharing one loop neither slide the icon nor restart its phase.
    struct Loop {
        let id: Int
        let cels: [Cel]
    }

    /// One state of the ticker: its icon, and its line as one still dwell or
    /// an edge marquee's steps.
    struct TickerState {
        let icon: Loop
        let lines: [(line: PixelCanvas, milliseconds: Int)]
    }

    /// A stretch of the timeline: a looping icon (its phase runs on) or one
    /// 16×16 slide step, beside a 34×16 area.
    struct Segment {
        enum Icon {
            case loop(Loop)
            case still(PixelCanvas)
        }

        let icon: Icon
        let area: PixelCanvas
        let milliseconds: Int
    }

    // MARK: - The right area

    /// `source`'s row `sourceY` onto `canvas`'s row `y`, across `width`.
    private static func copyRow(_ source: PixelCanvas, _ sourceY: Int, into canvas: inout PixelCanvas, row y: Int) {
        for x in 0..<min(source.width, canvas.width) {
            canvas[x, y] = source[x, sourceY]
        }
    }

    /// The right 34×16: the hero fixed on rows 0–8, the ticker line on rows
    /// 11–15 shifted up `step` rows towards `next` (5 rows + 1 blank pitch).
    static func areaFrame(_ top: PixelCanvas, _ current: PixelCanvas, _ next: PixelCanvas?, _ step: Int)
        -> PixelCanvas
    {
        var canvas = PixelCanvas(width: areaWidth, height: height)
        for y in 0..<9 {
            copyRow(top, y, into: &canvas, row: y)
        }
        for row in 0..<5 {
            let source = row + step
            if source < 5 {
                copyRow(current, source, into: &canvas, row: 11 + row)
            } else if let next, (6..<11).contains(source) {
                copyRow(next, source - 6, into: &canvas, row: 11 + row)
            }
        }
        return canvas
    }

    /// The frame an icon rests on — its longest, the first of equals — which
    /// is what a slide carries away.
    static func rest(_ loop: [Cel]) -> PixelCanvas {
        var best = loop[0]
        for cel in loop.dropFirst() where cel.milliseconds > best.milliseconds {
            best = cel
        }
        return best.canvas
    }

    /// Each state holds, then its line slides up 1 row a step while, when the
    /// next state brings a different icon, the icon slides up 3 rows a step
    /// over the SAME steps (Hybrid): both land together.
    static func tickerSegments(_ top: PixelCanvas, _ states: [TickerState]) -> [Segment] {
        var segments: [Segment] = []
        let count = states.count
        for (index, state) in states.enumerated() {
            for (line, milliseconds) in state.lines {
                segments.append(Segment(
                    icon: .loop(state.icon), area: areaFrame(top, line, nil, 0), milliseconds: milliseconds
                ))
            }
            if count == 1 { break }
            let incoming = states[(index + 1) % count]
            let current = state.lines[state.lines.count - 1].line, next = incoming.lines[0].line
            for step in 1..<WeatherFace.slideSteps {
                let area = areaFrame(top, current, next, step)
                if incoming.icon.id == state.icon.id {
                    segments.append(Segment(
                        icon: .loop(state.icon), area: area, milliseconds: WeatherFace.stepMilliseconds
                    ))
                    continue
                }
                let last = rest(state.icon.cels), first = rest(incoming.icon.cels)
                let shift = WeatherFace.iconStep * step
                var icon = PixelCanvas(width: 16, height: 16)
                for y in 0..<16 {
                    let source = y + shift
                    if source < 16 {
                        copyRow(last, source, into: &icon, row: y)
                    } else if (18..<34).contains(source) {
                        copyRow(first, source - 18, into: &icon, row: y)
                    }
                }
                segments.append(Segment(icon: .still(icon), area: area, milliseconds: WeatherFace.stepMilliseconds))
            }
        }
        return segments
    }

    /// The segments as ONE 52×16 timeline. A loop's phase runs on across
    /// consecutive segments that share it, so an icon keeps animating through
    /// a marquee's 100 ms steps instead of restarting on each. A sliver under
    /// 20 ms joins the frame before it.
    static func lace(_ segments: [Segment]) -> [Frame] {
        var out: [Frame] = []
        func emit(_ canvas: PixelCanvas, _ milliseconds: Int) {
            if milliseconds < 20, let last = out.last {
                out[out.count - 1] = Frame(canvas: last.canvas, milliseconds: last.milliseconds + milliseconds)
            } else {
                out.append(Frame(canvas: canvas, milliseconds: milliseconds))
            }
        }
        var phaseOf: Int?, elapsed = 0
        for segment in segments {
            switch segment.icon {
            case let .still(icon):
                emit(WeatherFace.compose(icon, segment.area), segment.milliseconds)
                phaseOf = nil
            case let .loop(loop):
                if loop.id != phaseOf {
                    phaseOf = loop.id
                    elapsed = 0
                }
                let total = WeatherFace.loopMilliseconds(loop.cels)
                var left = segment.milliseconds
                while left > 0 {
                    let position = elapsed % total
                    var start = 0, cel = loop.cels[loop.cels.count - 1]
                    for candidate in loop.cels {
                        if position < start + candidate.milliseconds {
                            cel = candidate
                            break
                        }
                        start += candidate.milliseconds
                    }
                    let span = min(start + cel.milliseconds - position, left)
                    emit(WeatherFace.compose(cel.canvas, segment.area), span)
                    elapsed += span
                    left -= span
                }
            }
        }
        return out
    }

    // MARK: - Ambient

    /// A ticker line as its states: one still dwell, or an edge marquee when
    /// it is wider than the area.
    static func lineState(_ parts: [WeatherFace.Part], _ dwell: Int) -> [(line: PixelCanvas, milliseconds: Int)] {
        if WeatherFace.partsWidth(parts) <= areaWidth {
            return [(lineArea(parts), dwell)]
        }
        return edgeMarquee(parts, dwell)
    }

    /// Hybrid: the stars hold the hero; each ticker line brings its own icon
    /// — the mark with the name, the fork glyph with the forks, the PR glyph
    /// with the open PRs — so a count is named by its icon, not a word.
    /// A hidden count (Show) leaves the rotation; with forks and PRs both
    /// hidden the name holds the line alone. A read with no state says why in
    /// the label slot: `no data` with its own icon, `bad token` and `no repo`
    /// with the dim mark.
    ///
    /// The Main watch picks the hero: the stars (as shipped), or the forks or
    /// the open PRs with their own mark — the stars then join the ticker, and
    /// the hero's own count leaves it whatever its Show toggle says — or the
    /// CI in words, with no lamp beside it.
    static func ambient(
        _ state: GitHubRepoState?, shortName: String?, hasToken: Bool, problem: GitHubProblem? = nil,
        show: Shown = Shown(), main: GitHubMainWatch = .stars, changeMilliseconds: Int
    ) -> [Frame] {
        let blank = PixelCanvas(width: areaWidth, height: height)
        guard hasToken else {
            return lace(tickerSegments(blank, [TickerState(
                icon: Loop(id: 0, cels: octocat(dim: true)),
                lines: [(lineArea([part("no token", WeatherFace.dim)]), 1000)]
            )]))
        }
        guard let state, problem == nil else {
            let problem = problem ?? .data
            return lace(tickerSegments(blank, [TickerState(
                icon: Loop(id: 0, cels: problem == .data ? WeatherIcon.nodata.frames : octocat(dim: true)),
                lines: [(lineArea([part(problem.label, WeatherFace.dim)]), 1000)]
            )]))
        }
        var states = [
            TickerState(
                icon: Loop(id: 0, cels: octocat()),
                lines: lineState(
                    [part(displayName(state.nameWithOwner, shortName: shortName), whiteInk)], changeMilliseconds
                )
            ),
        ]
        if main != .stars {
            states.append(TickerState(icon: Loop(id: 3, cels: starIcon().loop),
                                      lines: lineState([part("\(state.stars)", starInk)], changeMilliseconds)))
        }
        if show.forks, main != .forks {
            states.append(TickerState(icon: Loop(id: 1, cels: forkIcon()),
                                      lines: lineState([part("\(state.forks)", forkInk)], changeMilliseconds)))
        }
        if show.prs, main != .prs {
            states.append(TickerState(icon: Loop(id: 2, cels: prIcon()),
                                      lines: lineState([part("\(state.openPRs)", prInk)], changeMilliseconds)))
        }
        let top: PixelCanvas
        switch main {
        case .ci:
            let (text, ink) = ciHero(state.ci?.state)
            let parts = [part(text, ink)]
            guard WeatherFace.partsWidth(parts) > areaWidth else {
                var still = PixelCanvas(width: areaWidth, height: height)
                WeatherFace.drawRuns(parts, on: &still, x: 0, y: ciHeroY)
                return lace(tickerSegments(still, states))
            }
            return withHero(
                lace(tickerSegments(PixelCanvas(width: areaWidth, height: height), states)),
                edgeMarquee(parts, 0)
            )
        case .stars: top = hero(compact(state.stars), starInk, star: true)
        case .forks: top = hero(compact(state.forks), forkInk, mark: "⑂")
        case .prs: top = hero(compact(state.openPRs), prInk, mark: "⎇")
        }
        let frames = lace(tickerSegments(top, states))
        guard show.ci, let loop = lampLoop(state.ci?.state) else { return frames }
        return withLamp(frames, loop)
    }

    // MARK: - The CI hero

    /// The row the CI hero's 5 px line sits on: centred on the hero's 9.
    static let ciHeroY = 2

    /// The default branch's checks in words, in GitHub's check colours — the
    /// pending state called "processed" (the user's word) — and a repo
    /// without checks saying so, dim.
    static func ciHero(_ state: GitHubCI.State?) -> (text: String, ink: Pixel) {
        switch state {
        case .success?: ("ci passed", prInk)
        case .pending?: ("ci processed", ciPendingInk)
        case .failure?: ("ci failed", ciFailInk)
        case GitHubCI.State.none?, nil: ("no ci", WeatherFace.dim)
        }
    }

    /// An edge-marqueeing hero line painted over a whole timeline, looping,
    /// its phase running on across every frame — `withLamp`'s cut: a frame
    /// that spans a step of the marquee is cut there.
    static func withHero(_ frames: [Frame], _ loop: [(line: PixelCanvas, milliseconds: Int)]) -> [Frame] {
        let total = loop.reduce(0) { $0 + $1.milliseconds }
        var out: [Frame] = [], elapsed = 0
        for frame in frames {
            var left = frame.milliseconds
            while left > 0 {
                let position = elapsed % total
                var start = 0, step = loop[loop.count - 1]
                for candidate in loop {
                    if position < start + candidate.milliseconds {
                        step = candidate
                        break
                    }
                    start += candidate.milliseconds
                }
                let span = min(start + step.milliseconds - position, left)
                var canvas = frame.canvas
                for y in 0..<5 {
                    for x in 0..<areaWidth {
                        canvas[WeatherFace.areaX + x, ciHeroY + y] = step.line[x, y]
                    }
                }
                out.append(Frame(canvas: canvas, milliseconds: span))
                elapsed += span
                left -= span
            }
        }
        return out
    }

    // MARK: - The CI lamp

    /// The default branch's checks as a 3×3 badge on the icon's bottom-right
    /// corner — a status dot on an avatar, picked in the browser over a column
    /// beside the hero (it touched a fourth digit) and one in the gutter. It
    /// shows only while something needs a look: success draws nothing, like a
    /// repo without checks. Colour alone does not read on the dim panel, so
    /// the two states differ in motion too.
    static let lampCells = (13..<16).flatMap { y in (13..<16).map { x in PixelPoint(x: x, y: y) } }
    static let lampMilliseconds = 500

    /// One cel of the lamp: the cells it paints, over whatever is under them.
    typealias LampCel = (cells: [(PixelPoint, Pixel)], milliseconds: Int)

    /// Failure blinks 500/500 ms; pending fills from a ring to a full square
    /// and back. Nil when there is nothing to show.
    static func lampLoop(_ state: GitHubCI.State?) -> [LampCel]? {
        switch state {
        case .failure:
            return [(lampCells.map { ($0, ciFailInk) }, lampMilliseconds), ([], lampMilliseconds)]
        case .pending:
            let ring = lampCells.filter { $0 != PixelPoint(x: 14, y: 14) }
            return [
                (ring.map { ($0, ciPendingInk) }, lampMilliseconds),
                (lampCells.map { ($0, ciPendingInk) }, lampMilliseconds),
            ]
        // `GitHubCI.State.none` spelled out: a bare `.none` is Optional's nil.
        case .success?, GitHubCI.State.none?, nil:
            return nil
        }
    }

    /// Paints the lamp over a whole timeline, its phase running on across
    /// every frame (one GIF, tc002-ticker-motion): a frame that spans a lamp
    /// change is cut there. No sliver merging, as in ggen's `with_lamp`.
    static func withLamp(_ frames: [Frame], _ loop: [LampCel]) -> [Frame] {
        let total = loop.reduce(0) { $0 + $1.milliseconds }
        var out: [Frame] = [], elapsed = 0
        for frame in frames {
            var left = frame.milliseconds
            while left > 0 {
                let position = elapsed % total
                var start = 0, cel = loop[loop.count - 1]
                for candidate in loop {
                    if position < start + candidate.milliseconds {
                        cel = candidate
                        break
                    }
                    start += candidate.milliseconds
                }
                let span = min(start + cel.milliseconds - position, left)
                var canvas = frame.canvas
                for (point, ink) in cel.cells {
                    canvas[point.x, point.y] = ink
                }
                out.append(Frame(canvas: canvas, milliseconds: span))
                elapsed += span
                left -= span
            }
        }
        return out
    }

    // MARK: - Celebration

    /// At most this many logins are named; the rest are `+K more`.
    static let maxLogins = 3

    /// A value wider than 34 px scrolls only its overflow: 1 s at the start,
    /// 1 px per 100 ms, 1.5 s at the end (tc002-ticker-motion), and the last
    /// step holds out the dwell when the pass is shorter.
    static func edgeMarquee(_ parts: [WeatherFace.Part], _ dwell: Int) -> [(line: PixelCanvas, milliseconds: Int)] {
        let fullWidth = WeatherFace.partsWidth(parts) + 1
        var full = PixelCanvas(width: fullWidth, height: 5)
        WeatherFace.drawRuns(parts, on: &full, x: 0, y: 0)
        let over = fullWidth - 1 - areaWidth
        var out: [(line: PixelCanvas, milliseconds: Int)] = []
        for offset in 0...over {
            var area = PixelCanvas(width: areaWidth, height: 5)
            for y in 0..<5 {
                for x in 0..<areaWidth where offset + x < fullWidth {
                    area[x, y] = full[offset + x, y]
                }
            }
            out.append((area, offset == 0 ? 1000 : (offset == over ? 1500 : 100)))
        }
        let spent = out.reduce(0) { $0 + $1.milliseconds }
        if spent < dwell {
            out[out.count - 1].milliseconds += dwell - spent
        }
        return out
    }

    /// The icon pops in, `+N` holds the hero rows, and the ticker names the
    /// event and then who — at most three logins, the rest as `+K more`.
    static func celebrate(
        _ kind: GitHubEventKind, count: Int, who: [String], prNumbers: [Int], celebrateMilliseconds: Int
    ) -> [Frame] {
        let (ink, pop, loop): (Pixel, [Cel], [Cel]) = switch kind {
        case .star: { let star = starIcon(); return (starInk, star.pop, star.loop) }()
        case .fork: (forkInk, [], forkIcon())
        case .pr: (prInk, [], prIcon())
        }
        let top = hero("+\(count)", ink)
        let nouns = switch kind {
        case .star: ("star", "stars")
        case .fork: ("fork", "forks")
        case .pr: ("pr", "prs")
        }
        var label = [part(count != 1 ? nouns.1 : nouns.0, WeatherFace.label)]
        if kind == .pr, prNumbers.count == 1 {
            label = [part("pr", WeatherFace.label), part("#\(prNumbers[0])", prInk)]
        }
        var lines = [label]
        for (index, login) in who.prefix(maxLogins).enumerated() {
            if kind == .pr, prNumbers.count > 1, index < prNumbers.count {
                // The number already says whose line this is; the person
                // mark would cost the px that push a short login past 34.
                lines.append([part("#\(prNumbers[index])", prInk), part(login.lowercased(), whiteInk)])
            } else {
                lines.append([part("☺", personInk), part(login.lowercased(), whiteInk)])
            }
        }
        if who.count > maxLogins {
            lines.append([part("+\(who.count - maxLogins)", ink), part("more", WeatherFace.label)])
        }
        return celebrationTimeline(top, lines, pop: pop, loop: loop, celebrateMilliseconds: celebrateMilliseconds)
    }

    /// The default branch failing: `ci` holds the hero, the ticker says
    /// `<branch> fail` (`main failed` is 36 px) and then who pushed the commit.
    static func celebrateCI(branch: String, author: String?, celebrateMilliseconds: Int) -> [Frame] {
        var lines = [[part(branch, whiteInk), part("fail", ciFailInk)]]
        if let author {
            lines.append([part("☺", personInk), part(author.lowercased(), whiteInk)])
        }
        return celebrationTimeline(
            hero("ci", ciFailInk), lines, pop: [], loop: ciIcon(), celebrateMilliseconds: celebrateMilliseconds
        )
    }

    /// ggen's `_celebration_timeline`: the lines share the celebration's
    /// length, the icon's loop runs across all of them, the pop plays first.
    static func celebrationTimeline(
        _ top: PixelCanvas, _ lines: [[WeatherFace.Part]], pop: [Cel], loop: [Cel], celebrateMilliseconds: Int
    ) -> [Frame] {
        let slides = (lines.count - 1) * (WeatherFace.slideSteps - 1) * WeatherFace.stepMilliseconds
        let dwell = max(1200, floorDiv(celebrateMilliseconds - slides, lines.count))
        // One icon for the whole celebration: every state shares the loop, so
        // it never slides and its phase runs on across lines and marquee
        // steps. The last line does not slide back to the first — the
        // celebration ends there and the page's own frame returns.
        let shared = Loop(id: 0, cels: loop)
        let states = lines.map { TickerState(icon: shared, lines: lineState($0, dwell)) }
        var segments = tickerSegments(top, states)
        if states.count > 1 {
            segments.removeLast(WeatherFace.slideSteps - 1)
        }
        // The pop plays over the first dwell's opening, then the loop takes over.
        let popMilliseconds = WeatherFace.loopMilliseconds(pop)
        let first = segments[0]
        segments[0] = Segment(icon: first.icon, area: first.area,
                              milliseconds: max(20, first.milliseconds - popMilliseconds))
        return pop.map { Frame(canvas: WeatherFace.compose($0.canvas, first.area), milliseconds: $0.milliseconds) }
            + lace(segments)
    }
}
