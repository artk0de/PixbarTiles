import AwtrixKit
import SwiftUI

/// Everything set once and forgotten, behind the gear.
///
/// Shown in place of the panel rather than as a `.sheet`. A menu bar extra's
/// window dismisses when it loses focus and takes any sheet over it with it, so
/// a sheet here is a surface that vanishes while it is being read. Swapping the
/// content also makes the rule literal: the settings are a view, and nothing
/// about the schedule, the poll or a run in flight knows they are open.
struct SettingsSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            deviceHostSection
            Divider()
            iconSection
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { model.closeSettings() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Back")
            Text("Settings").font(.headline)
        }
    }

    /// The address the next launch will use.
    ///
    /// Saves as it is typed — `AppModel.typedHost` writes on every change — so
    /// there is no Save button and no submit to remember. What it writes is the
    /// same `UserDefaults` key `AppModel.live()` reads at launch, which is why
    /// it can exist beside a `deviceHost` that stays a `let`: it rebuilds
    /// nothing, and says so.
    private var deviceHostSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Device address").font(.caption).foregroundStyle(.secondary)
            TextField("Device address", text: $model.typedHost)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            if let note = model.hostNote {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// The only thing this app writes to the device's flash, and the only way to
    /// take it back off.
    ///
    /// Its result line lives here beside it rather than on the panel: the user
    /// pressed this button on this surface, and an answer thrown back to a panel
    /// they have already left is an answer nobody reads. An action taken once in
    /// the life of an installation also has no business sitting next to one
    /// taken daily.
    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Remove icons this app uploaded") { model.removeInstalledIcons() }
                .controlSize(.small)
            if let status = model.iconStatus {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
