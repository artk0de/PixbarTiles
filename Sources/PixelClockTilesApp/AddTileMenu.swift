import SwiftUI

/// The Add tile menu's rows: one entry per tile a connector can put on the
/// selected clock, refused ones visibly so.
///
/// The reason is drawn BESIDE the entry rather than in a tooltip, because a
/// tooltip on a disabled control never fires — the refusal the user is being
/// shown has to be readable where they are already looking. The menu renders
/// reasons and does not compute them: `AddTileMenuItem` carries its
/// `Availability` whole from the model.
struct AddTileMenu: View {
    let items: [AddTileMenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    Button(item.title) { item.onAdd() }
                        .buttonStyle(.borderless)
                        .disabled(isUnavailable(item))
                    if case let .unavailable(reason) = item.availability {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func isUnavailable(_ item: AddTileMenuItem) -> Bool {
        if case .unavailable = item.availability { return true }
        return false
    }
}
