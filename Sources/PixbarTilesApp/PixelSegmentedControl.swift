import PixbarKit
import SwiftUI

/// The switcher's decisions that are not drawing, kept apart so they can be
/// pinned: where an arrow key moves the selection, and how wide a segment is.
enum PixelSegments {
    /// The index an arrow key lands on, or nil when it does not move. One
    /// segment per press, stopping at the ends as a segmented control does;
    /// a selection the options do not hold lands on the first one.
    static func step(from index: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return 0 }
        let landing = index + delta
        guard landing >= 0, landing < count, landing != index else { return nil }
        return landing
    }

    /// One width for every segment: the widest title in the clock's face,
    /// plus `padding` either side — so the selected field keeps its size as
    /// it moves.
    static func segmentWidth(titles: [String], pixel: CGFloat, padding: CGFloat) -> CGFloat {
        let widest = titles.map { PanelGlyph.text($0, in: PixelFont.standard).first?.count ?? 0 }.max() ?? 0
        return CGFloat(widest) * pixel + padding * 2
    }
}

/// The app's segmented control, in its pixel hand: titles set in the clock's
/// face, square blocks for the fields, a square border. Every window-level
/// tab switcher and every segmented option picker in a form wears it, so the
/// app has one.
///
/// The selected segment is a calm grey field with the title in the primary
/// ink — not the system accent blue, which beside the cards' shelf colours
/// read as a control from another app. Hover lifts a segment faintly, a
/// press a little more.
///
/// To assistive technology and the keyboard it IS a segmented control: the
/// accessibility representation is a real segmented `Picker` on the same
/// binding, and the left and right arrows move the selection while the
/// control has focus.
struct PixelSegmentedControl<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var pixel: CGFloat = 2

    /// The selected field's grey — the store's All shelf, the one neutral in
    /// the app's pixel palette.
    static var selectedTint: UInt32 { PanelGlyph.allShelvesTint }

    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    init(
        _ label: String, selection: Binding<Value>, options: [(value: Value, title: String)],
        pixel: CGFloat = 2
    ) {
        self.label = label
        _selection = selection
        self.options = options
        self.pixel = pixel
    }

    var body: some View {
        let dark = scheme == .dark
        let width = PixelSegments.segmentWidth(titles: options.map(\.title), pixel: pixel, padding: 12)
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 {
                    Rectangle()
                        .fill(Color(hex: PixelInk.secondary(dark: dark)).opacity(0.5))
                        .frame(width: 2)
                }
                Button { selection = option.value } label: {
                    PixelArt(
                        map: PanelGlyph.text(option.title, in: PixelFont.standard, lit: "G"),
                        palette: PanelGlyph.inkPalette(
                            option.value == selection
                                ? PixelInk.primary(dark: dark) : PixelInk.secondary(dark: dark)
                        ),
                        pixel: pixel
                    )
                    .frame(width: width, height: 7 * pixel + 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PixelSegmentStyle(selected: option.value == selection))
                .pointerStyle(.link)
            }
        }
        .overlay(
            Rectangle().strokeBorder(
                Color(hex: PixelInk.secondary(dark: dark)).opacity(0.5), lineWidth: 2
            )
        )
        .fixedSize()
        .focusable()
        .focused($focused)
        .onKeyPress(.leftArrow) { move(by: -1) }
        .onKeyPress(.rightArrow) { move(by: 1) }
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.title).tag(option.value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func move(by delta: Int) -> KeyPress.Result {
        let current = options.firstIndex { $0.value == selection }
        guard let landing = PixelSegments.step(from: current, by: delta, count: options.count) else {
            return .ignored
        }
        selection = options[landing].value
        return .handled
    }
}

/// One segment's field: the calm grey when selected, faint on hover, a
/// little stronger while pressed, and nothing at rest.
private struct PixelSegmentStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Field(selected: selected, pressed: configuration.isPressed) { configuration.label }
    }

    private struct Field<Label: View>: View {
        let selected: Bool
        let pressed: Bool
        @ViewBuilder let label: () -> Label
        @State private var hovering = false

        private var strength: (from: Double, to: Double)? {
            if selected { return (0.55, 0.3) }
            if pressed { return (0.4, 0.2) }
            if hovering { return (0.2, 0.08) }
            return nil
        }

        var body: some View {
            label()
                .background {
                    if let strength {
                        PixelGradient(
                            tint: PanelGlyph.allShelvesTint, from: strength.from, to: strength.to, pixel: 4
                        )
                    }
                }
                .onHover { hovering = $0 }
        }
    }
}

extension PixelSegmentedControl where Value: CaseIterable & Identifiable, Value.AllCases: RandomAccessCollection {
    /// Every case, each titled by `title`.
    init(
        _ label: String, selection: Binding<Value>, title: (Value) -> String, pixel: CGFloat = 2
    ) {
        self.init(label, selection: selection, options: Value.allCases.map { ($0, title($0)) }, pixel: pixel)
    }
}
