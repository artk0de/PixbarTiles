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

    /// The Focuses the "works in" boxes run over: every case but `.unknown`.
    nonisolated static let worksInBoxes: [MacFocus] = MacFocus.allCases.filter { $0 != .unknown }

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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Paused", isOn: Binding(
                get: { policy.isPaused },
                set: { policy.isPaused = $0 }
            ))
            HStack {
                Text("Refresh")
                Slider(value: Binding(
                    get: { Self.position(forSeconds: TimeInterval(policy.refreshSeconds)) },
                    set: { Self.set(secondsAtPosition: $0, in: &policy) }
                ), in: 0...Double(RefreshScale.steps.count - 1))
                Text(Self.refreshLabel(Self.seconds(
                    atPosition: Self.position(forSeconds: TimeInterval(policy.refreshSeconds))
                )))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Works in").font(.caption).foregroundStyle(.secondary)
                ForEach(Self.worksInBoxes, id: \.self) { focus in
                    Toggle(focus.displayName, isOn: worksIn(focus))
                }
                Picker("Any other Focus", selection: Binding(
                    get: { policy.focus.whenUnknown },
                    set: { policy.focus.whenUnknown = $0 }
                )) {
                    Text("Run").tag(FocusRule.WhenUnknown.run)
                    Text("Hold").tag(FocusRule.WhenUnknown.hold)
                }
            }
            Picker("Hours", selection: Binding(
                get: { Self.hoursKind(of: policy) },
                set: { Self.setHours($0, in: &policy) }
            )) {
                Text("Always").tag(Self.HoursKind.always)
                Text("Quiet").tag(Self.HoursKind.quiet)
                Text("Working").tag(Self.HoursKind.active)
            }
            if case let .quiet(window) = policy.window {
                hourPickers(window: window) { policy.window = .quiet($0) }
            } else if case let .active(window) = policy.window {
                hourPickers(window: window) { policy.window = .active($0) }
            }
        }
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

    /// Seconds as the slider's caption says them.
    private static func refreshLabel(_ seconds: TimeInterval) -> String {
        switch seconds {
        case 30: "30 s"
        case 60..<3600: "\(Int(seconds / 60)) min"
        default: "\(Int(seconds / 3600)) h"
        }
    }
}

/// The weather tile's block: the place the weather is read from.
///
/// The plain `LocationField` does the reading and the checking; the block only
/// puts a box and a save around it. The place search stays with the general
/// settings surface for now — what moves, moves at the switch-over.
struct WeatherTileBlock: View {
    let place: Coordinates
    let onSave: (String) -> Void

    @State private var typed: String

    init(place: Coordinates, onSave: @escaping (String) -> Void) {
        self.place = place
        self.onSave = onSave
        _typed = State(initialValue: LocationField.text(for: place))
    }

    private func save() {
        guard typed != LocationField.text(for: place) else { return }
        onSave(typed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Location").font(.caption).foregroundStyle(.secondary)
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

/// The Claude tile's own block: which figure the tile shows — the daily
/// limit, the weekly window, or the current session.
///
/// Values in, closures out, like every block here. On the TC001 the choice
/// picks one of the connector's three faces; on the TC002 the face draws all
/// three at once and the choice answers only the AWTRIX page.
struct ClaudeTileBlock: View {
    let metric: ClaudeDisplayMetric
    let onMetric: (ClaudeDisplayMetric) -> Void

    var body: some View {
        Picker("Show", selection: Binding(
            get: { metric }, set: { onMetric($0) }
        )) {
            ForEach(ClaudeDisplayMetric.allCases, id: \.self) { candidate in
                Text(candidate.displayName).tag(candidate)
            }
        }
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
