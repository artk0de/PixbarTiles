import PixelClockKit
import SwiftUI

// The z.ai tile's own block: where the tile's API key is given to the app.
// The model does the storing — the block renders, reports, and forgets what
// it was shown.

/// The paste field, and the presence line beside it.
///
/// The key is asked for in a SECURE field and cleared the moment it is
/// handled, so nothing it left on screen outlives the paste: what the surface
/// says afterwards is a sentence about PRESENCE — "saved" or "no key" — and
/// never the key itself, which is why the field starts empty and stays empty
/// once a key stands behind the tile.
struct ZaiTileBlock: View {
    /// Whether a key stands behind this tile already.
    let hasKey: Bool
    /// What the last paste did, when there is something to say.
    let outcome: AppModel.ZaiKeyOutcome?
    /// Hands the paste to the model, which stores it and remembers the handle.
    let onSaveKey: (String) -> Void

    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API key").font(.caption).foregroundStyle(.secondary)
            Text(presenceLine)
                .font(.caption)
                .foregroundStyle(hasKey ? Color.primary : .secondary)
            HStack {
                SecureField("sk-…", text: $typed)
                    .textFieldStyle(.roundedBorder)
                Button("Save key") {
                    onSaveKey(typed)
                    // Handled is forgotten: a paste left standing in the
                    // field is the key on screen for no reason.
                    typed = ""
                }
                .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let outcome, outcome == .refused {
                Text("The key store refused the paste — try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var presenceLine: String {
        hasKey ? "Key saved — shown nowhere." : "No key yet — paste one from z.ai."
    }
}
