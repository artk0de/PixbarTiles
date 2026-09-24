import PixbarKit
import SwiftUI

/// One configured clock, as the Clocks section lists it.
///
/// The device is the model itself rather than its spoken name, and the dot
/// comes over with it. The list and the panel are two views of the same clocks,
/// and they used to describe them in two vocabularies — the panel drawing the
/// device and reading its dot, the list writing a grey "TC002 · … · Connected".
/// A reader cannot hold one surface against the other that way.
struct ClockListEntry: Identifiable {
    let id: UUID
    let name: String
    let device: ClockModel
    let address: String
    let status: String
    let dot: PanelModel.ClockDot
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
            // Headed, because a grouped form reads a text field's placeholder
            // as the row's LEADING LABEL: "Add by address — 10.0.0.5" was
            // being drawn at label size down the left of the row, with an
            // unexplained empty box beside it. The instruction belongs in the
            // header, and the placeholder is left to do its own job.
            Section("Add by address") {
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
        // A grouped form paints an opaque scroll background over whatever is
        // behind it, so the Clocks tab was an opaque slab inside a window
        // made of material. The tiles list next door already strips its own;
        // this is the same line, in the one place that was missing it.
        .scrollContentBackground(.hidden)
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
        InlineConfirmRow(
            question: Self.removalQuestion(for: entry.name),
            onConfirm: { onRemove(entry.id) },
            onCancel: { confirmingID = nil }
        )
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

    @Environment(\.colorScheme) private var scheme
    @State private var renaming = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // The clock itself, drawn the way the panel's cards draw it — the
            // one mark that says which of the two this row is without being
            // read.
            PixelArt(
                map: PanelGlyph.map(for: entry.device),
                palette: PanelGlyph.devicePalette(
                    for: entry.device, dark: dark, live: entry.dot != .red
                )
            )
            .frame(width: 42, height: 36, alignment: .top)
            details
        }
        .padding(.vertical, 2)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if renaming {
                    InlineRenameField(
                        current: entry.name,
                        onSave: {
                            onRename($0)
                            renaming = false
                        },
                        onCancel: { renaming = false }
                    )
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
                    // The label a screen reader hears, said again where a
                    // mouse can read it: four icon-only buttons in a row is
                    // exactly where a tooltip earns its keep.
                    .help("Move \(entry.name) up")
                    Button {
                        onMoveDown()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(canMoveDown == false)
                    .accessibilityLabel("Move \(entry.name) down")
                    .help("Move \(entry.name) down")
                    Button { renaming = true } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Rename \(entry.name)")
                    .help("Rename \(entry.name)")
                    Button(action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(entry.name)")
                    .help("Remove \(entry.name)")
                }
            }
            HStack(spacing: 6) {
                Text("\(entry.device.spokenName) · \(entry.address)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // The connection said the way the panel says it: the lamp
                // carries the urgency and the word carries the detail, so the
                // two surfaces cannot disagree about what "down" looks like.
                PixelArt(map: PanelGlyph.led, palette: PanelGlyph.ledPalette(for: entry.dot))
                Text(entry.status)
                    .font(.caption)
                    .foregroundStyle(Color(hex: Self.tint(of: entry.dot)))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.name), \(entry.device.spokenName), \(entry.address), \(entry.status)")
    }

    private static func tint(of dot: PanelModel.ClockDot) -> UInt32 {
        switch dot {
        case .green: PanelGlyph.onlineTint
        case .yellow: PanelGlyph.checkingTint
        case .red: PanelGlyph.offlineTint
        }
    }
}

/// The second way in: an address typed straight in, for a clock discovery
/// has not seen or a network it cannot browse.
private struct AddByAddressRow: View {
    let onAdd: (String) -> Void

    @State private var address = ""

    private func add() {
        guard !address.isEmpty else { return }
        onAdd(address)
    }

    var body: some View {
        HStack {
            TextField("10.0.0.5", text: $address)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                // Typing an address and pressing Return is what a person
                // does; reaching for the button beside it afterwards was the
                // step this field made them take.
                .onSubmit(add)
            Button("Add", action: add)
                .controlSize(.small)
                .disabled(address.isEmpty)
        }
    }
}
