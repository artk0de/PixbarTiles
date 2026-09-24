import SwiftUI

/// What the panel draws when no clock is configured — a state a fresh install
/// reaches and answers, not a clock created in the dark (D6).
///
/// The answer is the Clocks section, where adding lives; this panel opens no
/// surface of its own. One question, one row of answer: the window stays the
/// panel's window, and the settings' Clocks section does the adding.
struct NoClocksPanel: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No clocks yet")
                .font(.headline)
            Text("Add a clock to put tiles on it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Add clock…") { onAdd() }
                .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
