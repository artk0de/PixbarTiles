import SwiftUI

/// Renaming something, in the row the thing is named in.
///
/// One of these and not two. The clocks list and a clock's own General tab
/// both grew a text field with a Save and a Cancel beside it, written twice
/// and drifting apart in the ways that only show when a hand is on the
/// keyboard: neither took focus when it appeared, so the first keystroke
/// after pressing the pencil went nowhere; neither answered Return; and one
/// of them would happily save an empty name.
///
/// Values in, closures out. Which store the new name goes to is the caller's
/// question — this view knows what is typed and when the typing is done.
struct InlineRenameField: View {
    /// What the thing is called now: the field starts there, the placeholder
    /// says it, and a name equal to it is not a rename.
    let current: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var typed: String = ""
    /// Focus on appear, which is the whole difference between a field that is
    /// ready and one that has to be clicked before it can be typed in.
    @FocusState private var focused: Bool

    /// What a save would send: the typed name without the whitespace nobody
    /// meant to type.
    nonisolated static func newName(from typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether there is a rename to save.
    ///
    /// Blank is not a name, whitespace is blank, and the name it already has
    /// is not a change. A rule and not a `!isEmpty` in the view, because it
    /// is the same rule for the button and for Return, and two copies of it
    /// is how Return comes to accept what the button refuses.
    nonisolated static func canSave(_ typed: String, current: String) -> Bool {
        let name = newName(from: typed)
        return !name.isEmpty && name != current
    }

    private var canSave: Bool { Self.canSave(typed, current: current) }

    var body: some View {
        HStack(spacing: 8) {
            TextField(current, text: $typed)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                // Return is the save, because a one-field form has one
                // answer and reaching for the mouse to give it is the
                // friction this closes.
                .onSubmit { save() }
            Button("Save") { save() }
                .controlSize(.small)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { onCancel() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }
        .onAppear {
            typed = current
            focused = true
        }
    }

    private func save() {
        guard canSave else { return }
        onSave(Self.newName(from: typed))
    }
}

/// A removal asked about where it was asked for.
///
/// Inline and not a `.confirmationDialog`, deliberately: these rows sit in a
/// settings form and on a card in a grid, and a modal sheet over either one
/// covers the very thing being named. The question is in the row, the two
/// answers beside it, and Escape is one of them.
///
/// One of these and not two, for the reason the rename field is one: the
/// clocks list asked its question out loud and the tile card drew a bare
/// Remove and Cancel with nothing saying what was about to go.
struct InlineConfirmRow: View {
    let question: String
    /// What the destructive answer is called — "Remove", and nothing else so
    /// far, but a row that hard-codes its own verb cannot be reused by the
    /// next surface that needs one.
    let confirmTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    init(
        question: String, confirmTitle: String = "Remove",
        onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void
    ) {
        self.question = question
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(question)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            // Both say "clicked, not dragged". The row is drawn INSIDE cards
            // that carry a drag affordance of their own, and a pointer style
            // resolves innermost-first — without these the card's open hand
            // would sit over two buttons.
            Button(confirmTitle, role: .destructive) { onConfirm() }
                .controlSize(.small)
                .pointerStyle(.default)
            Button("Cancel", role: .cancel) { onCancel() }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                .pointerStyle(.default)
        }
    }
}
