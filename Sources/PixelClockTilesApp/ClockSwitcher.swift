import SwiftUI

/// One segment per configured clock — the panel's answer to more than one of
/// them being on the tree.
///
/// Hidden with fewer than two clocks: a lone clock needs no switch, and an
/// empty control on the panel would be a question with one answer. The model
/// glyph (TC001 against TC002) is text, not an asset — the panel ships no
/// image assets and gains none here.
struct ClockSwitcher: View {
    struct Entry: Identifiable {
        let id: UUID
        let name: String
        let model: String
    }

    let clocks: [Entry]
    @Binding var selection: UUID

    var body: some View {
        if clocks.count >= 2 {
            Picker("Clock", selection: $selection) {
                ForEach(clocks) { clock in
                    Text("\(clock.name) · \(clock.model)").tag(clock.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}
