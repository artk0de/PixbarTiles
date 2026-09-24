import SwiftUI

/// The steps a setting offers, as a slider travels them.
///
/// A UNIFORM ladder — 0 … 100 % in fives — slides over its values, with the
/// stride as the slider's step. Any other — 5 s, 10 s, 15 s, 30 s, 1 min … —
/// slides over its INDEX, so every step is an equal stretch of track rather
/// than the long end swallowing the whole bar.
struct StepLadder: Equatable {
    /// Sorted, without repeats, never empty.
    let steps: [Double]

    init(_ steps: [Double]) {
        let sorted = Array(Set(steps)).sorted()
        self.steps = sorted.isEmpty ? [0] : sorted
    }

    var isUniform: Bool {
        guard steps.count > 2 else { return true }
        let first = steps[1] - steps[0]
        return zip(steps.dropFirst(), steps).allSatisfy { $0 - $1 == first }
    }

    /// The slider's range.
    var track: ClosedRange<Double> {
        isUniform ? steps[0]...steps[steps.count - 1] : 0...Double(steps.count - 1)
    }

    /// The slider's step.
    var stride: Double {
        guard isUniform else { return 1 }
        return steps.count > 1 ? steps[1] - steps[0] : 1
    }

    /// The step a stored value shows as: the nearest, and on a tie the
    /// longer one — `RefreshScale.snapped`'s rule, so a value reads the same
    /// here as everywhere else it is snapped.
    func snapped(_ value: Double) -> Double {
        steps.reversed().min { abs($0 - value) < abs($1 - value) } ?? steps[0]
    }

    /// Where the thumb stands for a stored value.
    func position(for value: Double) -> Double {
        let step = snapped(value)
        return isUniform ? step : Double(steps.firstIndex(of: step) ?? 0)
    }

    /// The step under a thumb position — a mid-drag reading lands on a step,
    /// and a position off either end is that end.
    func value(at position: Double) -> Double {
        if isUniform { return snapped(position) }
        let index = Int(position.rounded()).clamped(to: 0...(steps.count - 1))
        return steps[index]
    }
}

/// What a slider may write, and when: the step under the thumb when a drag
/// ENDS, never one per step on the way — every write is a push to the clock.
/// A move with no drag around it (an arrow key, an accessibility increment)
/// has no release to wait for and is the write itself.
struct SlideCommit: Equatable {
    private var editing = false
    /// The thumb's position while a drag holds it; nil when the stored value
    /// is what the slider shows.
    private(set) var shown: Double?

    mutating func begin() { editing = true }

    /// A thumb move. The position to write, or nil while a drag is holding it.
    mutating func move(to position: Double) -> Double? {
        guard editing else { return position }
        shown = position
        return nil
    }

    /// The drag let go: the position to write, or nil when it never moved.
    mutating func end() -> Double? {
        editing = false
        defer { shown = nil }
        return shown
    }
}

/// A stepped setting as a slider: the name, the ladder's two ends, the thumb,
/// and the value under it — which follows the drag live while the write waits
/// for the release.
struct SteppedSlider: View {
    let label: String
    let ladder: StepLadder
    /// The stored value. One the ladder does not offer shows at its nearest
    /// step and is not rewritten until the user moves the thumb.
    let value: Double
    let caption: (Double) -> String
    let onCommit: (Double) -> Void

    @State private var slide = SlideCommit()

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                end(ladder.steps[0])
                Slider(
                    value: Binding(
                        get: { slide.shown ?? ladder.position(for: value) },
                        set: { position in
                            if let written = slide.move(to: position) { write(written) }
                        }
                    ),
                    in: ladder.track,
                    step: ladder.stride,
                    onEditingChanged: { editing in
                        if editing {
                            slide.begin()
                        } else if let written = slide.end() {
                            write(written)
                        }
                    }
                )
                .labelsHidden()
                end(ladder.steps[ladder.steps.count - 1])
                Text(caption(slide.shown.map(ladder.value(at:)) ?? ladder.snapped(value)))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
    }

    private func end(_ step: Double) -> some View {
        Text(caption(step))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    /// Only a change reaches the owner: a release on the value already stored
    /// writes nothing. An off-ladder value is left alone until a drag lands
    /// somewhere — then the step it landed on is written.
    private func write(_ position: Double) {
        let landed = ladder.value(at: position)
        guard landed != value else { return }
        onCommit(landed)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
