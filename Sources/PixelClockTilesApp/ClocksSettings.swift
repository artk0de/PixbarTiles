import PixelClockKit
import SwiftUI

/// One configured clock, as the Clocks section lists it.
struct ClockListEntry: Identifiable {
    let id: UUID
    let name: String
    let model: String
    let address: String
    let status: String
}

// `DiscoveredClock` — a clock the discovery has seen advertising itself, not
// yet configured — moved to the kit next to the discovery that publishes it
// (`ClockDiscovery.found`); the list here is what that type's rows render.

/// What an Add answered, as the Clocks section says it.
///
/// The wording lives here rather than at the two buttons, because the two add
/// paths must not grow two vocabularies: an addition is said with the clock's
/// own name — the row's name, or the address a clock was typed at — and a
/// refusal is said in its own words, verbatim, since the model already wrote
/// them for exactly this reader.
enum ClockAddOutcomeLine {
    static func title(
        for outcome: AppModel.ClockSaveOutcome, added name: String
    ) -> String {
        switch outcome {
        case .added: "Added \(name)."
        case let .refused(reason): reason
        }
    }
}

/// The Clocks section of the general settings: the clocks on the tree, the
/// two ways to add one, and nothing from `AppModel` — the list comes in fed
/// (`discovered`, both models) and the dual probe runs behind Add-by-address.
///
/// Removal confirms inline and says what custody will do, because it is
/// irreversible from this surface: every tile on the clock goes through its
/// session's teardown, and the settings on it go with it.
struct ClocksSettings: View {
    let entries: [ClockListEntry]
    let discovered: [DiscoveredClock]
    /// What the last Add answered, or nil while nothing stands to be said.
    /// The twice-added clock is the case this exists for: the store stayed
    /// empty twice and nothing ever said why.
    let outcome: String?
    /// Where a dragged row landed: the source clock moves to the destination
    /// row's place. The order IS the store's — the one the panel's sections
    /// follow — so the row keeps its drag on its reading parts, exactly as a
    /// tile's row does.
    let onMove: (UUID, UUID) -> Void
    let onRename: (UUID, String) -> Void
    let onRemove: (UUID) -> Void
    let onAddDiscovered: (DiscoveredClock) -> Void
    let onAddByAddress: (String) -> Void

    /// The whole question, clock named.
    nonisolated static func removalQuestion(for clockName: String) -> String {
        "Remove \(clockName)? Every tile on it goes with it."
    }

    /// The confirmation state, entered directly — how the tests reach the
    /// question without driving the button.
    init(
        entries: [ClockListEntry], discovered: [DiscoveredClock],
        confirming: Bool = false,
        outcome: String? = nil,
        onMove: @escaping (UUID, UUID) -> Void = { _, _ in },
        onRename: @escaping (UUID, String) -> Void,
        onRemove: @escaping (UUID) -> Void,
        onAddDiscovered: @escaping (DiscoveredClock) -> Void,
        onAddByAddress: @escaping (String) -> Void
    ) {
        self.entries = entries
        self.discovered = discovered
        self.confirmingID = confirming ? entries.first?.id : nil
        self.outcome = outcome
        self.onMove = onMove
        self.onRename = onRename
        self.onRemove = onRemove
        self.onAddDiscovered = onAddDiscovered
        self.onAddByAddress = onAddByAddress
    }

    /// The entry a removal is being confirmed for, or nil while none is.
    @State private var confirmingID: UUID?

    var body: some View {
        Form {
            Section {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if entry.id == confirmingID {
                        removalRow(for: entry)
                    } else {
                        ClockEntryRow(
                            entry: entry,
                            canMoveUp: index > 0,
                            canMoveDown: index < entries.count - 1,
                            onMoveUp: { move(entry, by: -1) },
                            onMoveDown: { move(entry, by: 1) },
                            onRename: { onRename(entry.id, $0) },
                            onRemove: { confirmingID = entry.id }
                        )
                        // The drop destination, beside the row: a drag released
                        // here moves the dragged clock to this row's place. The
                        // payload is the clock's own id, read back by the model.
                        .dropDestination(for: String.self) { payload, _ in
                            guard let source = payload.first, let id = UUID(uuidString: source),
                                id != entry.id
                            else { return false }
                            onMove(id, entry.id)
                            return true
                        }
                        .onDrag {
                            NSItemProvider(object: entry.id.uuidString as NSString)
                        }
                    }
                }
            } header: {
                Text("Clocks")
            }
            if !discovered.isEmpty {
                Section("Found on the network") {
                    ForEach(discovered, id: \.address) { clock in
                        HStack {
                            Text("\(clock.name) · \(clock.model)")
                            Spacer()
                            Button("Add") { onAddDiscovered(clock) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            Section {
                AddByAddressRow(onAdd: onAddByAddress)
                // Under the section rather than beside either button: both paths
                // answer here, so the reader of one refusal is the reader of both.
                if let outcome {
                    Text(outcome)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The neighbour a chevron swaps with — the entries as they are, which
    /// is the store's own order the panel's sections follow.
    private func move(_ entry: ClockListEntry, by step: Int) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let target = index + step
        guard entries.indices.contains(target) else { return }
        onMove(entry.id, entries[target].id)
    }

    private func removalRow(for entry: ClockListEntry) -> some View {
        HStack(spacing: 8) {
            Text(Self.removalQuestion(for: entry.name))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Remove") { onRemove(entry.id) }
                .controlSize(.small)
            Button("Cancel") { confirmingID = nil }
                .controlSize(.small)
        }
    }
}

/// One configured clock's row, with the rename, reorder and remove controls.
private struct ClockEntryRow: View {
    let entry: ClockListEntry
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRename: (String) -> Void
    let onRemove: () -> Void

    @State private var renaming = false
    @State private var newName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if renaming {
                    TextField(entry.name, text: $newName)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        onRename(newName)
                        renaming = false
                    }
                    .controlSize(.small)
                    Button("Cancel") { renaming = false }
                        .controlSize(.small)
                } else {
                    Text(entry.name).font(.callout)
                    Spacer()
                    Button {
                        onMoveUp()
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(canMoveUp == false)
                    .accessibilityLabel("Move \(entry.name) up")
                    Button {
                        onMoveDown()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(canMoveDown == false)
                    .accessibilityLabel("Move \(entry.name) down")
                    Button {
                        newName = entry.name
                        renaming = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Rename \(entry.name)")
                    Button(action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(entry.name)")
                }
            }
            Text("\(entry.model) · \(entry.address) · \(entry.status)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The second way in: an address typed straight in, for a clock discovery
/// has not seen or a network it cannot browse.
private struct AddByAddressRow: View {
    let onAdd: (String) -> Void

    @State private var address = ""

    var body: some View {
        HStack {
            TextField("Add by address — 10.0.0.5", text: $address)
                .textFieldStyle(.roundedBorder)
            Button("Add") { onAdd(address) }
                .controlSize(.small)
                .disabled(address.isEmpty)
        }
    }
}
