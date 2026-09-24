import AppKit
import PixelClockKit
import SwiftUI

// The one surface where a tile's whole behaviour is visible at once: the
// shared policy editor on top, the connector's own block under it. Nothing
// here decides when a tile runs — the kit types from phase 4a carry the rules,
// and the editor only edits `TilePolicy` values through its binding.

// `TileDetail` stood here: a tile's whole behaviour on one surface, opened
// inside the panel's own window with a Back chevron at the top. It has been
// superseded by `TileSettingsWindow` — a real window, with the same policy
// editor, the same per-connector blocks, and a live preview of the face
// beside them — and nothing in the app has built one since. The blocks below
// are what it was made of, and they all moved across.

/// The policy editor every tile shares: when it runs, and why it would not.
///
/// The stored seconds are snapped when read and written only when the slider
/// moves — the `TileSettingsStore` rule, held here at the slider's binding so
/// a value the scale cannot show displays its nearest step without being
/// quietly rewritten. The "works in" boxes run over the Focuses the app can
/// name; an unnamed Focus is decided by the picker beside them, so it is
/// never a sixth box.
struct TilePolicyEditor: View {
    @Binding var policy: TilePolicy
    /// The refresh intervals this tile's connector offers. The connector's
    /// own, never the general scale by assumption: a tile stored at a step only
    /// its connector has would otherwise be SHOWN the nearest general one and
    /// rewritten to it the moment the control was touched.
    var refreshSteps: [TimeInterval] = RefreshScale.steps
    /// False when the connector's own block carries the refresh under a name
    /// of its own — "Fetch weather every" beside the weather's "Change every".
    /// One stored value gets one control, wherever the reader looks for it.
    var showsRefresh = true

    /// Whether the words behind the question mark are up.
    @State private var showingFocusHint = false

    /// The ink the question mark is drawn in — the panel's secondary, like
    /// every other mark in this app that is chrome rather than content.
    @Environment(\.colorScheme) private var scheme
    private var hintInk: UInt32 { PixelInk.secondary(dark: scheme == .dark) }

    /// The Focuses the "works in" boxes run over: every case but `.unknown`.
    nonisolated static let worksInBoxes: [MacFocus] = MacFocus.allCases.filter { $0 != .unknown }

    /// The four modes macOS ships, two by two, in the order its own Focus list
    /// puts them.
    ///
    /// "No Focus" is not among them and is drawn under the square instead: it
    /// is the ABSENCE of a mode, and a fifth box inside a square of four reads
    /// as a fifth mode. `.unknown` is not a box at all — the picker beside
    /// them is what decides it.
    nonisolated static let focusGrid: [[MacFocus]] = [
        [.work, .personal],
        [.doNotDisturb, .sleep],
    ]

    /// The glyph a mode is known by. macOS's own, so a reader recognises the
    /// square before reading a word of it.
    nonisolated static func symbol(_ focus: MacFocus) -> String {
        switch focus {
        case .work: "briefcase.fill"
        case .personal: "person.fill"
        case .doNotDisturb: "moon.fill"
        case .sleep: "bed.double.fill"
        case .noFocus: "circle.dashed"
        case .unknown: "questionmark.circle"
        }
    }

    /// What "any other Focus" means, which its own label cannot say.
    ///
    /// The picker was the one control on this surface nobody could act on:
    /// "Any other Focus — Run / Hold" says what the switch does and nothing
    /// about which Focuses it decides.
    nonisolated static let anyOtherFocusHint = """
        macOS names only its four built-in modes. Anything else — a Focus you \
        made yourself, or one this Mac will not disclose — arrives here as \
        "other". Run shows the tile through it; Hold keeps the tile off until \
        the Focus ends.
        """

    /// The box's state: ticked means the tile WORKS there, so the answer is
    /// read against `silencedIn`.
    nonisolated static func isChecked(_ focus: MacFocus, in policy: TilePolicy) -> Bool {
        !policy.focus.silencedIn.contains(focus)
    }

    /// Writes a box's state. Unticking ADDS the Focus to `silencedIn` — the
    /// polarity the round-trip tests pin, and the one that makes "works in"
    /// read the way it says.
    nonisolated static func set(focus: MacFocus, checked: Bool, in policy: inout TilePolicy) {
        if checked {
            policy.focus.silencedIn.remove(focus)
        } else {
            policy.focus.silencedIn.insert(focus)
        }
    }

    /// Switching the hours keeps the window: `.quiet` over `.active` is the
    /// same stretch of day read the other way round, not a new one.
    nonisolated static func setHours(_ kind: HoursKind, in policy: inout TilePolicy) {
        switch kind {
        case .always:
            policy.window = .always
        case .quiet:
            policy.window = .quiet(existingWindow(of: policy))
        case .active:
            policy.window = .active(existingWindow(of: policy))
        }
    }

    /// The slider's position for stored seconds: the step the value reads as.
    nonisolated static func position(forSeconds seconds: TimeInterval) -> Double {
        Double(RefreshScale.steps.firstIndex(of: RefreshScale.snapped(seconds)) ?? 0)
    }

    /// The seconds a slider position stands for.
    nonisolated static func seconds(atPosition position: Double) -> TimeInterval {
        let index = min(Int(position), RefreshScale.steps.count - 1)
        return RefreshScale.steps[max(index, 0)]
    }

    /// Writes the seconds a slider move landed on. This — and nothing in the
    /// reading path — is where the stored value changes.
    nonisolated static func set(secondsAtPosition position: Double, in policy: inout TilePolicy) {
        policy.refreshSeconds = Int(seconds(atPosition: position))
    }

    /// Whether a ladder is shown as a menu rather than as the slider.
    ///
    /// A dozen named choices — ten seconds, a minute, four hours — read as a
    /// menu, where each one is a word rather than a place to drag to. The
    /// general scale's twenty-seven five-minute steps are a continuum and read
    /// as a slider; a menu of twenty-seven would be a list to scroll.
    nonisolated static func picks(from ladder: [TimeInterval]) -> Bool {
        ladder.count <= 12
    }

    /// The step a stored value SHOWS as, read on the tile's own ladder.
    ///
    /// Read on the general one a ten-second tile would show thirty seconds —
    /// the number the schedule stopped using the moment the ladder became the
    /// connector's.
    nonisolated static func shownRefresh(
        of policy: TilePolicy, on ladder: [TimeInterval]
    ) -> TimeInterval {
        RefreshScale.snapped(TimeInterval(policy.refreshSeconds), on: ladder)
    }

    /// Writes a picked step. The step itself, never a reading of it: a value
    /// read back through a scale that cannot show it would be quietly
    /// rewritten one save later.
    nonisolated static func set(refresh seconds: TimeInterval, in policy: inout TilePolicy) {
        policy.refreshSeconds = Int(seconds)
    }

    private func worksIn(_ focus: MacFocus) -> Binding<Bool> {
        Binding(
            get: { Self.isChecked(focus, in: policy) },
            set: { checked in
                var edited = policy
                Self.set(focus: focus, checked: checked, in: &edited)
                policy = edited
            }
        )
    }

    /// Three blocks, because these are three questions and they used to be one
    /// undifferentiated column: whether the tile runs at all, which Focuses it
    /// runs through, and which hours.
    var body: some View {
        Section {
            Toggle("Paused", isOn: Binding(
                get: { policy.isPaused },
                set: { policy.isPaused = $0 }
            ))
            if showsRefresh {
                TileRefreshControl(
                    label: "Refresh every", ladder: refreshSteps, policy: $policy
                )
            }
        }
        Section("Works in") {
            // A square of four, then the absence of a mode under it. As five
            // switches in a column the four modes macOS actually ships did not
            // read as a set at all, and "No Focus" read as a fifth one.
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(Array(Self.focusGrid.enumerated()), id: \.offset) { row in
                    GridRow {
                        ForEach(row.element, id: \.self) { focus in
                            focusBox(focus)
                        }
                    }
                }
            }
            focusBox(.noFocus)
            HStack(spacing: 4) {
                Picker("Any other Focus", selection: Binding(
                    get: { policy.focus.whenUnknown },
                    set: { policy.focus.whenUnknown = $0 }
                )) {
                    Text("Run").tag(FocusRule.WhenUnknown.run)
                    Text("Hold").tag(FocusRule.WhenUnknown.hold)
                }
                hintMark
            }
        }
        Section("Hours") {
            PixelSegmentedControl(
                "Hours",
                selection: Binding(
                    get: { Self.hoursKind(of: policy) },
                    set: { Self.setHours($0, in: &policy) }
                ),
                options: [
                    (Self.HoursKind.always, "Always"),
                    (Self.HoursKind.quiet, "Quiet"),
                    (Self.HoursKind.active, "Working"),
                ]
            )
            if case let .quiet(window) = policy.window {
                hourPickers(window: window) { policy.window = .quiet($0) }
            } else if case let .active(window) = policy.window {
                hourPickers(window: window) { policy.window = .active($0) }
            }
        }
    }

    /// The question mark beside "Any other Focus", and what it answers.
    ///
    /// A BUTTON with a popover, not a bare image with `.help`. That was the
    /// first attempt and the hint never appeared: a plain `Image` inside a
    /// form row is not a hit-testable control, so there is nothing for the
    /// tooltip to hang off and nothing to hover. A button is hit-testable, it
    /// shows the tooltip, and a click opens the same words for anybody whose
    /// pointer never rests long enough for a tooltip at all.
    ///
    /// Drawn in the app's own vocabulary rather than SF's: it sits three rows
    /// under a square of Focus boxes and two above a pixel gear.
    private var hintMark: some View {
        Button { showingFocusHint.toggle() } label: {
            PixelArt(map: PanelGlyph.question, palette: PanelGlyph.inkPalette(hintInk))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(Self.anyOtherFocusHint)
        .accessibilityLabel("What is any other Focus?")
        .popover(isPresented: $showingFocusHint, arrowEdge: .bottom) {
            Text(Self.anyOtherFocusHint)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280)
                .padding(12)
        }
    }

    /// One mode's box: its glyph, its name, and whether the tile works there.
    ///
    /// A button rather than a switch. Two switches side by side in a column
    /// this narrow leave "Do Not Disturb" no room to be read, and what a
    /// reader wants from a square of four is which ones are LIT.
    private func focusBox(_ focus: MacFocus) -> some View {
        Toggle(isOn: worksIn(focus)) {
            Label(focus.displayName, systemImage: Self.symbol(focus))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.button)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func hourPickers(
        window: HourWindow, onChange: @escaping (HourWindow) -> Void
    ) -> some View {
        HStack {
            Picker("From", selection: Binding(
                get: { window.startHour },
                set: { onChange(HourWindow(startHour: $0, endHour: window.endHour)) }
            )) {
                ForEach(0..<24, id: \.self) { Text(Self.clockFace($0)).tag($0) }
            }
            Picker("To", selection: Binding(
                get: { window.endHour },
                set: { onChange(HourWindow(startHour: window.startHour, endHour: $0)) }
            )) {
                ForEach(0..<24, id: \.self) { Text(Self.clockFace($0)).tag($0) }
            }
        }
    }

    enum HoursKind {
        case always, quiet, active
    }

    private static func hoursKind(of policy: TilePolicy) -> HoursKind {
        switch policy.window {
        case .always: .always
        case .quiet: .quiet
        case .active: .active
        }
    }

    /// The window to keep when the kind switches onto one that carries hours.
    /// `.always` carries no window, so the editor starts from a whole-day
    /// quiet stretch rather than an empty one — an empty window restricts
    /// nothing, and would read as the picker doing nothing.
    nonisolated private static func existingWindow(of policy: TilePolicy) -> HourWindow {
        switch policy.window {
        case let .quiet(window), let .active(window): window
        case .always: HourWindow(startHour: 23, endHour: 8)
        }
    }

    private static func clockFace(_ hour: Int) -> String {
        HourWindow.clockFace(hour)
    }

}

/// How often a tile runs, on the ladder its connector offers.
///
/// A slider over the connector's ladder when it is a dozen named choices, and
/// over the general scale's steps otherwise — see
/// `TilePolicyEditor.picks(from:)`. The label is the caller's because the same
/// stored value is "Refresh" on the shared editor and "Fetch weather every"
/// beside the weather's own "Change every", which is a different setting
/// entirely and sits two rows above it.
struct TileRefreshControl: View {
    let label: String
    let ladder: [TimeInterval]
    @Binding var policy: TilePolicy

    /// A slider over the ladder's steps either way — the connector's own
    /// ladder when it is a short list of named choices, the general scale
    /// otherwise — written when the drag lets go.
    var body: some View {
        SteppedSlider(
            label: label,
            ladder: StepLadder(TilePolicyEditor.picks(from: ladder) ? ladder : RefreshScale.steps),
            value: TimeInterval(policy.refreshSeconds),
            caption: RefreshScale.label,
            onCommit: { TilePolicyEditor.set(refresh: $0, in: &policy) }
        )
    }
}

/// The weather tile's block: where the weather is read from, said in words
/// first and in numbers under them.
///
/// The search came back here. It was written, measured and tested against the
/// live geocoder — `PlaceSearchModel`, and the note it carries about districts
/// and about a city being one point is measured behaviour — and then the
/// surface that hosted it went away at the switch-over to this window. What
/// was left was a box wanting two decimal numbers, on a tile whose whole
/// subject is a place. The comment that stood here said the search "stays with
/// the general settings surface for now"; there is no general settings surface
/// any more.
struct WeatherTileBlock: View {
    /// Where the clock is, as `TileSettingsModel.placeHeadline` says it — off
    /// the draft, so this line cannot disagree with the reading under it.
    let headline: String
    let place: Coordinates
    let onSave: (String) -> Void
    let onChoose: (PlaceCandidate) -> Void

    /// One per opening of the window, which is what its own documentation asks
    /// for: nothing here outlives the surface.
    @StateObject private var places = PlaceSearchModel()
    @State private var typed: String
    @State private var name = ""

    init(
        headline: String,
        place: Coordinates,
        onSave: @escaping (String) -> Void,
        onChoose: @escaping (PlaceCandidate) -> Void
    ) {
        self.headline = headline
        self.place = place
        self.onSave = onSave
        self.onChoose = onChoose
        _typed = State(initialValue: LocationField.text(for: place))
    }

    private func save() {
        guard typed != LocationField.text(for: place) else { return }
        onSave(typed)
    }

    private func take(_ candidate: PlaceCandidate) {
        // Through the search model's own `choose`, so the box below follows
        // the row and the list clears exactly as its tests say it does — and
        // then the name goes to the draft, which the box cannot carry.
        places.choose(candidate, into: $typed)
        onChoose(candidate)
        // Emptying the box fires `onChange`, and `suggest("")` closes the
        // dropdown rather than opening one for a blank name — so the row that
        // was just picked does not reappear under the field.
        name = ""
    }

    /// What the name in the box could mean, under the box.
    ///
    /// Drawn in the list's own material with a border around it, so it reads
    /// as a thing that dropped DOWN from the field rather than as three more
    /// rows of the form. It is laid out in the flow rather than in a popover:
    /// a popover on macOS takes key focus, and a suggestion list that steals
    /// the caret from the field feeding it is a list nobody can type past.
    @ViewBuilder
    private var dropdown: some View {
        if places.candidates.isEmpty == false || places.note != nil {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(places.candidates) { candidate in
                    Button { take(candidate) } label: {
                        HStack(spacing: 6) {
                            Text(candidate.name)
                            // What separates the homonyms: "Москва, Россия"
                            // against "Айдахо, США".
                            Text(candidate.label).font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                }
                if let note = places.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
            }
            .background(.quaternary.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(.headline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            // No Find button. A name box beside a button is a search somebody
            // has to know to press, and what everybody expects of a place
            // field is that it offers places while they type. The request is
            // debounced in `PlaceSearchModel.suggest`, so a word typed at
            // speed costs one request rather than one per letter.
            HStack(spacing: 6) {
                TextField("City or town", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, typed in places.suggest(typed) }
                if places.isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            dropdown
            Text(PlaceSearchModel.findsSettlementsNotAddresses)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The numbers under the words, for the pair somebody already has
            // — and the only way to reach a place the geocoder cannot name.
            HStack {
                TextField("55.7558, 37.6173", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    // A pair of coordinates typed out and then Return is what
                    // a person does with a box like this one.
                    .onSubmit { save() }
                Button("Save") { save() }
                    .disabled(typed == LocationField.text(for: place))
            }
        }
    }
}

/// The anecdote tile's block: the way back into what has played.
///
/// A button, and only a button — opening the existing `HistoryMenu` surface
/// is the switch-over's work; the closure here is the seam it will be wired
/// through.
struct AnecdoteTileBlock: View {
    let onHistory: () -> Void

    var body: some View {
        Button("History…", action: onHistory)
    }
}

/// The coding-subscription block, on the Claude tile and the z.ai tile alike:
/// which face the panel draws, which windows it shows, how long each stands,
/// and from what percentage a window names its reset.
///
/// Values in, closures out: the block hands back the whole config with one
/// field moved, and whoever owns the record keeps what else it says.
struct CodeUsageBlock: View {
    let config: CodeUsage.Parameters
    let onChange: (CodeUsage.Parameters) -> Void

    /// Two groups, because the settings answer two questions.
    ///
    /// What the panel DRAWS — the face, the windows it rotates through, and
    /// how long each stands — and, separately, what it says about a RESET:
    /// from what percentage, and spelled which way round. The second pair is
    /// the same in either layout, which is what makes it its own block rather
    /// than a tail on the first.
    ///
    /// The dwell stays with the layout, where it belongs: it is that layout's
    /// tempo, and its name changes with the layout because what it is spent on
    /// does.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("On the TC002").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Layout") {
                    PixelSegmentedControl(
                        "Layout",
                        selection: Binding(
                            get: { config.layout },
                            set: { chosen in change { $0.layout = chosen } }
                        ),
                        title: \.displayName
                    )
                }
                // Only the Circle shows one window at a time, so only the
                // Circle has a choice to make. Compact has a row for each and
                // no reason to leave one empty.
                if config.layout == .circle { windowChoice }
                SteppedSlider(
                    label: config.layout.dwellLabel,
                    ladder: StepLadder(CodeUsage.Parameters.resetEverySteps),
                    value: config.resetEvery,
                    caption: Self.everyCaption,
                    onCommit: { chosen in change { $0.resetEvery = chosen } }
                )
                // A Circle showing one window has nothing to change to.
                .disabled(config.dwellIsAdjustable == false)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Reset").font(.caption).foregroundStyle(.secondary)
                SteppedSlider(
                    label: "Show reset after",
                    ladder: StepLadder(CodeUsage.Parameters.resetAfterSteps.map(Double.init)),
                    value: Double(config.resetAfter),
                    caption: { Self.afterCaption(Int($0)) },
                    onCommit: { chosen in change { $0.resetAfter = Int(chosen) } }
                )
                // The options ARE the spellings, on a date that tells them
                // apart — naming the orders instead ("Day first") makes the
                // reader picture the result rather than read it.
                Picker("Date", selection: Binding(
                    get: { config.dateOrder },
                    set: { chosen in change { $0.dateOrder = chosen } }
                )) {
                    ForEach(CodeUsage.DateOrder.allCases) { Text($0.displayName).tag($0) }
                }
            }
        }
    }

    /// Which windows the Circle rotates through: a checkbox each, in the order
    /// the panel shows them.
    ///
    /// The one still checked is disabled rather than hidden — a box that
    /// vanishes when it is the last reads as a bug, where one that will not
    /// come up reads as the rule it is.
    private var windowChoice: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Show").font(.caption).foregroundStyle(.secondary)
            ForEach(CodeUsage.WindowKind.allCases) { kind in
                Toggle(kind.displayName, isOn: Binding(
                    get: { config.windows.contains(kind) },
                    set: { _ in
                        change { $0.windows = Self.windows(config.windows, toggling: kind) }
                    }
                ))
                .disabled(config.windows == [kind])
            }
        }
    }

    /// Hands back the whole config with one field moved, so a setting the
    /// block does not show is a setting the block cannot lose.
    private func change(_ move: (inout CodeUsage.Parameters) -> Void) {
        var edited = config
        move(&edited)
        onChange(edited)
    }

    /// The selection after a box is clicked, with the last one held.
    ///
    /// A tile showing no window has nothing to draw, and a panel drawing
    /// nothing reads as broken rather than as a choice. Unchecking the only
    /// checked box therefore does nothing at all.
    nonisolated static func windows(
        _ current: [CodeUsage.WindowKind], toggling kind: CodeUsage.WindowKind
    ) -> [CodeUsage.WindowKind] {
        guard current.contains(kind) else {
            return CodeUsage.WindowKind.allCases.filter { current.contains($0) || $0 == kind }
        }
        let left = current.filter { $0 != kind }
        return left.isEmpty ? current : left
    }

    /// Seconds as the picker says them: `10 s` under a minute, `2 min` from.
    nonisolated static func everyCaption(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min"
    }

    nonisolated static func afterCaption(_ percent: Int) -> String {
        "\(percent)%"
    }
}

/// The VPN tile's block: which VPN to watch, which lamp to say it with, in
/// which colour, and what "down" looks like.
///
/// Values in, closures out — the block renders and reports, and whoever owns
/// the settings decides what a choice means.
struct VPNTileBlock: View {
    enum DownBehaviour: String, CaseIterable {
        case off
        case blink
    }

    let presets: [String]
    let preset: String
    let slots: [String]
    let slot: String
    let colour: Color
    let downBehaviour: DownBehaviour
    let onPreset: (String) -> Void
    let onSlot: (String) -> Void
    let onColour: (Color) -> Void
    let onDownBehaviour: (DownBehaviour) -> Void

    init(
        presets: [String], preset: String,
        slots: [String], slot: String,
        colour: Color, downBehaviour: DownBehaviour,
        onPreset: @escaping (String) -> Void = { _ in },
        onSlot: @escaping (String) -> Void = { _ in },
        onColour: @escaping (Color) -> Void = { _ in },
        onDownBehaviour: @escaping (DownBehaviour) -> Void = { _ in }
    ) {
        self.presets = presets
        self.preset = preset
        self.slots = slots
        self.slot = slot
        self.colour = colour
        self.downBehaviour = downBehaviour
        self.onPreset = onPreset
        self.onSlot = onSlot
        self.onColour = onColour
        self.onDownBehaviour = onDownBehaviour
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Preset", selection: Binding(
                get: { preset }, set: { onPreset($0) }
            )) {
                ForEach(presets, id: \.self) { Text($0).tag($0) }
            }
            Picker("Lamp", selection: Binding(
                get: { slot }, set: { onSlot($0) }
            )) {
                ForEach(slots, id: \.self) { Text($0).tag($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Colour").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(VPNTilePalette.palette, id: \.name) { entry in
                        Button { onColour(entry.colour) } label: {
                            Circle()
                                .fill(entry.colour)
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(entry.name)
                    }
                    ColorPicker("Custom", selection: Binding(
                        get: { colour }, set: { onColour($0) }
                    ))
                    .labelsHidden()
                }
            }
            Picker("When down", selection: Binding(
                get: { downBehaviour }, set: { onDownBehaviour($0) }
            )) {
                Text("Off").tag(DownBehaviour.off)
                Text("Blink").tag(DownBehaviour.blink)
            }
        }
    }
}

/// The lamp palette, the spec's saturated eight in code with names.
///
/// Saturated on purpose: at brightness 2–3 the LEDs wash pastels towards
/// white, so a pastel picked in the picker reads as almost nothing on the
/// clock.
enum VPNTilePalette {
    struct Entry {
        let name: String
        let hex: String
        let colour: Color
    }

    static let palette: [Entry] = [
        ("Electric Lime", "#A3FF12"),
        ("Cyber Cyan", "#00F0FF"),
        ("Hot Magenta", "#FF2BD6"),
        ("Ultraviolet", "#8B5CF6"),
        ("Neon Mint", "#3DFFB0"),
        ("Sunset Orange", "#FF6B1A"),
        ("Solar Yellow", "#FFE600"),
        ("Alarm Red", "#FF1744"),
    ].map { Entry(name: $0.0, hex: $0.1, colour: Color(hex: $0.1)) }

    /// What a lamp blinks when its tunnel drops, unless the user picks
    /// otherwise: the palette's own red, so the down colour is from the same
    /// eight as the up one.
    static let alarm = "#FF1744"
}

extension Color {
    /// A colour from `#RRGGBB`, as the spec's palette table writes them.
    init(hex: String) {
        let value = hex.dropFirst()
        var rgb: UInt64 = 0
        Scanner(string: String(value)).scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    /// Back to `#RRGGBB`, which is the only colour the config stores and the
    /// only one the firmware is told.
    ///
    /// Through sRGB on purpose: a `ColorPicker` hands back whatever space the
    /// system picker was in, and asking a display-P3 colour for its red
    /// component without converting first is how a picked colour and a lit
    /// lamp stop matching.
    var hexString: String {
        let srgb = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let byte = { (channel: CGFloat) in Int((channel * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X",
            byte(srgb.redComponent), byte(srgb.greenComponent), byte(srgb.blueComponent)
        )
    }
}
