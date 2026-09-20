import SwiftUI

/// One configured clock, as the Clocks section lists it.
struct ClockListEntry: Identifiable {
    let id: UUID
    let name: String
    let model: String
    let address: String
    let status: String
}

/// A clock the discovery has seen advertising itself, not yet configured.
struct DiscoveredClock {
    let name: String
    let model: String
    let address: String
}

/// The Clocks section of the general settings: the clocks on the tree, the
/// two ways to add one, and nothing from `AppModel` — the dual-probe and the
/// UDP discovery behind it are the clock actions' task to wire.
///
/// Removal confirms inline and says what custody will do, because it is
/// irreversible from this surface: every tile on the clock goes through its
/// session's teardown, and the settings on it go with it.
struct ClocksSettings: View {
    let entries: [ClockListEntry]
    let discovered: [DiscoveredClock]
    let onRename: (UUID, String) -> Void
    let onRemove: (UUID) -> Void
    let onAddDiscovered: (DiscoveredClock) -> Void
    let onAddByAddress: (String) -> Void

    /// The whole question, clock named.
    static func removalQuestion(for clockName: String) -> String {
        "Remove \(clockName)? Every tile on it goes with it."
    }

    /// The confirmation state, entered directly — how the tests reach the
    /// question without driving the button.
    init(
        entries: [ClockListEntry], discovered: [DiscoveredClock],
        confirming: Bool = false,
        onRename: @escaping (UUID, String) -> Void,
        onRemove: @escaping (UUID) -> Void,
        onAddDiscovered: @escaping (DiscoveredClock) -> Void,
        onAddByAddress: @escaping (String) -> Void
    ) {
        self.entries = entries
        self.discovered = discovered
        self.confirmingID = confirming ? entries.first?.id : nil
        self.onRename = onRename
        self.onRemove = onRemove
        self.onAddDiscovered = onAddDiscovered
        self.onAddByAddress = onAddByAddress
    }

    /// The entry a removal is being confirmed for, or nil while none is.
    @State private var confirmingID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clocks").font(.headline)
            ForEach(entries) { entry in
                if entry.id == confirmingID {
                    removalRow(for: entry)
                } else {
                    ClockEntryRow(
                        entry: entry,
                        onRename: { onRename(entry.id, $0) },
                        onRemove: { confirmingID = entry.id }
                    )
                }
            }
            if !discovered.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Found on the network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            AddByAddressRow(onAdd: onAddByAddress)
        }
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

/// One configured clock's row, with the rename and remove controls.
private struct ClockEntryRow: View {
    let entry: ClockListEntry
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
