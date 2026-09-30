import AppKit
import PixbarKit
import SwiftUI

/// When the next run is due, or what is holding it.
///
/// A time and a reason are the same slot because they answer the same question,
/// and only one of them is ever true. Naming an hour while something is holding
/// the schedule is the failure worth avoiding: the user plans around it.
enum NextRunLine {
    static func text(for next: NextRun?) -> String? {
        switch next {
        case nil: nil
        case let .due(date): "next \(date.formatted(date: .omitted, time: .shortened))"
        case let .held(reason): reason
        }
    }
}

struct MenuPanel: View {
    @ObservedObject var model: AppModel
    /// The panel's own projection — every clock a section of statistics.
    /// Observed through `@Observable` tracking, so a plain `let`: what the
    /// body reads is what redraws it.
    let panel: PanelModel
    /// The Settings window's facade: the general gear aims it before the
    /// window opens.
    let settings: SettingsModel
    /// Opens the app's Settings window — the system action, so the window
    /// macOS already knows how to make key and restorable is the one made.
    @Environment(\.openSettings) private var openTheSettings
    /// Opens one of the app's plain windows — the store, or a clock's own
    /// settings.
    @Environment(\.openWindow) private var openWindow
    /// Closes the pinned panel's window when the pin comes out.
    @Environment(\.dismissWindow) private var dismissWindow
    /// Where the width is read at launch and written when a drag ends.
    ///
    /// Handed in rather than reached for, so a test can put a width in the
    /// defaults and see the panel drawn at it. Reaching for `.standard` inside
    /// the view would leave the one thing worth proving — that the stored number
    /// reaches the layout — testable only by writing into the preferences of
    /// whoever is running the suite.
    private let defaults: UserDefaults

    /// Written out rather than left to the memberwise one, only so `defaults`
    /// can be private and still be handed in.
    /// No `store` and no `discovery` among these any more. Both were stored,
    /// both were required of every caller, and neither was ever READ: the
    /// panel became statistics-only, and the two surfaces that consumed them
    /// — the tile rows and the Clocks section — moved to windows of their
    /// own and took their own facades with them. A parameter every call site
    /// must supply and nothing ever asks for is a shape that outlives its
    /// reason, and the next reader has to prove the negative to be sure.
    /// Whether the panel is pinned to a window of its own.
    ///
    /// Handed in by the scene, which needs the same answer to decide what to
    /// draw — nil builds one over this panel's own `defaults`, so a test that
    /// brings its own store gets an isolated pin and no test reads the pin of
    /// whoever is running the suite.
    let pin: PanelPin

    init(
        model: AppModel,
        panel: PanelModel,
        settings: SettingsModel,
        pin: PanelPin? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.model = model
        self.panel = panel
        self.settings = settings
        self.defaults = defaults
        self.pin = pin ?? PanelPin(defaults: defaults)
    }

    /// The system action plus the activation that makes the opened window
    /// KEY. An accessory app's click goes to the panel, and macOS does not
    /// hand the key to a window whose app was not asking — without the
    /// explicit activate, every window opened from here appeared behind the
    /// user's attention and stayed there.
    ///
    /// The popover steps aside after: the click that asked came from inside
    /// it, so it is the key window until the opened one takes over.
    private func openAndFocus(_ open: () -> Void) {
        let panelWindow = NSApp.keyWindow
        open()
        WindowFocus.activate()
        WindowFocus.stepAside(panelWindow, pinned: pin.isPinned)
    }

    /// The History is the panel's one swap: it is read here, where a
    /// clickaway returns to the panel.
    var body: some View {
        if model.historyIsOpen {
            HistoryMenu(model: model, defaults: defaults)
        } else {
            panelView
        }
    }

    /// Every clock on the tree, as the requirement says the panel: its own
    /// statistics — the dot, the connection, the battery — and nothing else.
    /// Above them, one general gear; below, quit.
    @ViewBuilder
    private var panelView: some View {
        Group {
            if panel.hasNoClocks {
                // A launch that stored no clock: the state the user answers, not
                // a clock created in the dark (D6).
                NoClocksPanel(onAdd: {
                    settings.tab = .clocks
                    openAndFocus { openTheSettings() }
                })
                .padding(14)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    // One container for the cards: glass that shares a
                    // container is sampled once, and the cards themselves are
                    // CONTENT — a fill on the glass, not glass on glass.
                    GlassEffectContainer(spacing: 8) {
                        VStack(spacing: 8) {
                            ForEach(panel.sections, id: \.clock.id) { section in
                                ClockSectionView(
                                    section: section,
                                    onClockSettings: {
                                        settings.showClockWindow(section.clock.id)
                                        openAndFocus { openWindow(id: "clock-settings") }
                                    },
                                    onRecheck: { await model.recheckClock(section.clock.id) }
                                )
                            }
                        }
                    }
                    lastRow
                }
                .padding(14)
            }
        }
        .panelWidth(from: defaults)
        // No material here. The SCENE lays it on (`App.swift`), and this view
        // laid an identical `glassEffect` on top of that one — two layers of
        // the same glass over one surface, each site's comment claiming to be
        // the only one. The History swaps into this same window and carries
        // none, so the stack depth changed as the user moved between them.
        // On the group rather than on `body`, and that is the point: the
        // History is drawn by the same view, and a panel that asked for a
        // reading every time somebody came back from the History would spend
        // a request on a surface that shows none of it. The model coalesces
        // repeats, so a SwiftUI rebuild handing out a second appearance costs
        // nothing.
        .onAppear { model.refreshOnPanelOpen() }
    }

    @Environment(\.colorScheme) private var colorScheme

    /// The app's mark and name, and how many of the clocks are answering —
    /// the one fact about all of them together.
    private var header: some View {
        HStack(spacing: 8) {
            pinButton
            PixelArt(
                map: PanelMark.map,
                palette: PanelGlyph.devicePalette(
                    dark: colorScheme == .dark,
                    live: panel.sections.contains { $0.dot == .green }
                ),
                pixel: 1
            )
            Wordmark()
            Spacer()
            Text(panel.onlineSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        // The header is the grab bar, as it is on any window: dragging it
        // moves the panel, and moving the panel is what pins it (the delegate
        // hears the move). SoundSource's own pin flips the same way.
        .gesture(WindowDragGesture())
        // Diagnostic only: says whether the header receives the drag at all.
        // A gesture that does nothing and a gesture never delivered look the
        // same from outside. Simultaneous, so it takes nothing from the drag.
        .simultaneousGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    AppLog.panel.info(
                        "header drag \(value.translation.width, privacy: .public)×\(value.translation.height, privacy: .public)"
                    )
                }
        )
    }

    /// The pin, at the corner SoundSource puts its own.
    ///
    /// Pinning opens the panel as a window of its own and lets this popover
    /// go; unpinning closes that window. The panel cannot simply REFUSE to
    /// close — macOS dismisses a `MenuBarExtra(.window)` when it stops being
    /// key, and the app only ever hears about it afterwards.
    private var pinButton: some View {
        Button {
            if pin.isPinned == false {
                // Pinned where the popover is: the panel only becomes free to
                // move, it does not jump to wherever the scene last left a
                // window. The popover is the key window while its pin is
                // clicked.
                if let frame = NSApp.keyWindow?.frame {
                    pin.pinInPlace(frame: frame)
                } else {
                    pin.set(true)
                }
                // Not `openAndFocus`: activating the app raises every window
                // it has. The pinned window focuses itself, alone, as it
                // appears.
                openWindow(id: PinnedPanelWindow.id)
            } else {
                pin.set(false)
                dismissWindow(id: PinnedPanelWindow.id)
                WindowFocus.closePinned(among: NSApp.windows)
            }
        } label: {
            PixelArt(
                map: PanelGlyph.pin,
                palette: PanelGlyph.pinPalette(
                    pinned: pin.isPinned, ink: PixelInk.secondary(dark: colorScheme == .dark)
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pin.isPinned ? "Unpin the panel" : "Pin the panel to its own window")
        .help(
            pin.isPinned
                ? "Unpin — close the window and go back to the menu bar"
                : "Pin — keep the panel in a window of its own"
        )
    }

    /// Settings at one corner, Quit at the other, each with its pixel mark —
    /// the general surface named in words rather than a third gear. Glass
    /// buttons: controls are what the glass layer is for. Quit is instant, so
    /// it needs no state of its own: the panel is gone before the button
    /// could redraw.
    private var lastRow: some View {
        let ink = PanelGlyph.inkPalette(PixelInk.primary(dark: colorScheme == .dark))
        return HStack {
            Button {
                openAndFocus { openTheSettings() }
            } label: {
                Label {
                    Text("Settings")
                } icon: {
                    PixelArt(map: PanelGlyph.gear, palette: ink, pixel: 1.5)
                }
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label {
                    Text("Quit")
                } icon: {
                    PixelArt(map: PanelGlyph.power, palette: ink, pixel: 1.5)
                }
            }
        }
        .buttonStyle(.glass)
        .labelStyle(.titleAndIcon)
    }
}

/// One clock's card: the device drawn in the app's pixel hand, its name said
/// the way a person says it, the connection as a lit lamp, its own gear, and
/// the charge as cells, a figure and what happens next.
///
/// The card is CONTENT on the panel's glass: a quiet fill rather than a second
/// pane of glass, which would sample the first and wash both out.
private struct ClockSectionView: View {
    let section: PanelModel.ClockSection
    /// Where the gear goes: straight into the clock's settings window — a
    /// menu interposed in front of a window the click already named is a
    /// question asked twice.
    let onClockSettings: () -> Void
    /// The refresh: asks this clock now and answers how it found it.
    let onRecheck: () async -> AppModel.ClockReachability

    /// A refresh under way: the badge says Checking… and the button rests.
    @State private var checking = false
    /// What the last refresh found, said for a few seconds (`ClockRecheckNote`).
    @State private var note: String?

    /// How long a refresh's note stays up.
    private static let noteSeconds = 5

    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PixelArt(
                map: PanelGlyph.map(for: section.clock.model),
                palette: PanelGlyph.devicePalette(
                    for: section.clock.model, dark: dark, live: section.isLive
                ),
                pixel: 2
            )
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(section.clock.name).font(.headline)
                        Text(section.clock.model.spokenName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    StatusBadge(
                        dot: checking ? .yellow : section.dot,
                        words: checking ? DeviceStatusLine.title(for: .unknown) : section.statusLine,
                        blinking: checking
                    )
                }
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                if let reading = section.battery {
                    BatteryRow(reading: reading, live: section.isLive, dark: dark)
                }
            }
            // One element for VoiceOver: the card's facts in one sentence,
            // with the gear left out as its own control.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spoken(section))
        }
        .padding(.leading, 12)
        .padding(.vertical, 12)
        // The refresh and gear's own column, so the badge never slides
        // under them.
        .padding(.trailing, 62)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: .rect(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 0) {
                Button(action: recheck) {
                    PixelArt(
                        map: PanelGlyph.recheckArrow,
                        palette: PanelGlyph.inkPalette(PixelInk.secondary(dark: dark)),
                        pixel: 1.5
                    )
                    .opacity(checking ? 0.4 : 1)
                    .padding(6)
                    .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .disabled(checking)
                .help("Check \(section.clock.name) now")
                .accessibilityLabel("Check \(section.clock.name) now")
                Button(action: onClockSettings) {
                    PixelArt(
                        map: PanelGlyph.gear,
                        palette: PanelGlyph.inkPalette(PixelInk.secondary(dark: dark)),
                        pixel: 1.5
                    )
                    .padding(6)
                    .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .help("\(section.clock.name) settings")
                .accessibilityLabel("\(section.clock.name) settings")
            }
            .padding(6)
        }
    }

    /// Asks the clock now; a clock that stays silent gets a note saying why
    /// it may be, for a few seconds. The battery read is the last one seen —
    /// a silent clock's charge is the one it had before it went quiet.
    private func recheck() {
        checking = true
        Task { @MainActor in
            let answer = await onRecheck()
            checking = false
            let said = ClockRecheckNote.text(reachable: answer == .reachable, lastBattery: section.battery)
            withAnimation { note = said }
            guard said != nil else { return }
            try? await Task.sleep(for: .seconds(Self.noteSeconds))
            if note == said { withAnimation { note = nil } }
        }
    }

    /// The card as one sentence: who, what, whether it answers, and the charge.
    static func spoken(_ section: PanelModel.ClockSection) -> String {
        var parts = [section.clock.name, section.clock.model.spokenName, section.statusLine]
        if let reading = section.battery {
            var charge = "battery \(reading.shownPercent) percent"
            if let caption = BatteryLine.caption(for: reading, live: section.isLive) {
                charge += ", \(caption)"
            }
            parts.append(charge)
        }
        return parts.joined(separator: ", ")
    }
}

/// The connection as a lamp and its word, on a capsule tinted by the lamp.
private struct StatusBadge: View {
    let dot: PanelModel.ClockDot
    let words: String
    /// A refresh under way: the lamp blinks (`CheckingBlink`).
    var blinking = false

    var body: some View {
        HStack(spacing: 5) {
            if blinking {
                TimelineView(.periodic(from: .now, by: CheckingBlink.halfBeat)) { context in
                    lamp.opacity(
                        CheckingBlink.isLit(elapsed: context.date.timeIntervalSinceReferenceDate) ? 1 : 0.15
                    )
                }
            } else {
                lamp
            }
            Text(words)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Self.tint(dot).opacity(0.16), in: .capsule)
    }

    private var lamp: some View {
        PixelArt(map: PanelGlyph.led, palette: PanelGlyph.ledPalette(for: dot), pixel: 2)
    }

    private static func tint(_ dot: PanelModel.ClockDot) -> Color {
        let palette = PanelGlyph.ledPalette(for: dot)
        return Color(hex: (palette["L"] ?? nil) ?? PanelGlyph.unknownTint)
    }
}

/// The charge: the bolt while it fills, the cells, the figure, and — at the
/// far end — what happens next.
private struct BatteryRow: View {
    let reading: BatteryReading
    let live: Bool
    let dark: Bool

    var body: some View {
        HStack(spacing: 6) {
            if PanelGlyph.showsBolt(for: reading, live: live) {
                PixelArt(map: PanelGlyph.bolt, palette: PanelGlyph.boltPalette, pixel: 2)
            }
            PixelArt(
                map: PanelGlyph.battery,
                palette: PanelGlyph.batteryPalette(
                    for: reading, ink: PixelInk.secondary(dark: dark), live: live
                ),
                pixel: 2
            )
            Text("\(reading.shownPercent)%")
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(reading.shownPercent)))
            Spacer(minLength: 4)
            if let caption = BatteryLine.caption(for: reading, live: live) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(live ? BatteryLine.colour(for: reading) : .secondary)
                    .lineLimit(1)
            }
        }
        .opacity(live ? 1 : 0.7)
    }
}

/// The model a clock record names, as a person says it — the panel's header,
/// the Clocks tab's rows and the store's cards all say it this way.
extension ClockModel {
    var spokenName: String {
        switch self {
        case .awtrix3: "AWTRIX 3"
        // The vendor's own name for it. The bare "TC002" this used to be is
        // what the clock puts in its UDP announcement — the device talking on
        // the wire, not the app talking to a reader — and that string stays
        // where it is.
        case .ulanziTC002: "TC-002 Pixbar"
        }
    }
}
