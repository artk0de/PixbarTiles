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
            quietHoursSection
            Divider()
            microphonesSection
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

    /// When the app stays quiet, and which rule is deciding that.
    ///
    /// The pickers are shown whichever rule is in force, not only when the
    /// window is the one deciding. Two reasons, and only the first is about the
    /// user: a control that appears and disappears with a permission the user
    /// cannot see the state of is a control they cannot find when they need it,
    /// and setting the window BEFORE the fallback bites is the whole point of
    /// having one. The second is about the test below — with the pickers hidden
    /// on one of the two renders, the surfaces would differ by the pickers as
    /// well as by the line, and the test claiming the line would pass with the
    /// line deleted.
    private var quietHoursSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Quiet hours").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                hourPicker("From", selection: Binding(
                    get: { model.quietHours.startHour },
                    set: { model.setQuietHours(QuietWindow(
                        startHour: $0, endHour: model.quietHours.endHour
                    )) }
                ))
                hourPicker("To", selection: Binding(
                    get: { model.quietHours.endHour },
                    set: { model.setQuietHours(QuietWindow(
                        startHour: model.quietHours.startHour, endHour: $0
                    )) }
                ))
            }
            // Said whichever rule holds, because "no Focus is on" and "I am not
            // allowed to know" look identical from outside and only one of them
            // means the window below is doing anything.
            Text(FocusRuleLine.text(for: model.focusRule))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One end of the window.
    ///
    /// Both ends draw from the same list of hours: a window is a pair of hours,
    /// not a start with a length, and a picker offering durations would have to
    /// decide what a nine-hour window starting at 23:00 is called.
    private func hourPicker(_ label: String, selection: Binding<Int>) -> some View {
        Picker(label, selection: selection) {
            ForEach(QuietWindow.selectableHours, id: \.self) { candidate in
                Text(QuietWindow.clockFace(candidate)).tag(candidate)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel(label)
    }

    /// Which microphones the schedule waits for.
    ///
    /// Every input the system reports, watched ones ticked — not only the
    /// watched ones. A gate the user cannot inspect is a gate they will
    /// eventually fight, and the always-on interface that reports itself busy
    /// for ever is only understandable next to the inputs that do not.
    ///
    /// Read live on every draw, at one CoreAudio enumeration — 1.36 ms measured
    /// on this machine — because the list changes underneath the app: the phone
    /// appears and vanishes, headphones are plugged in. Nothing on this surface
    /// redraws at frame rate, which is what makes that affordable here and
    /// worth stating before anybody moves it to the panel.
    private var microphonesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Wait for these microphones").font(.caption).foregroundStyle(.secondary)
            ForEach(model.microphoneListing) { choice in
                Toggle(choice.input.name, isOn: Binding(
                    get: { choice.isWatched },
                    set: { model.setWatched($0, for: choice.input) }
                ))
                .controlSize(.small)
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
