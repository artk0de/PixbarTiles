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
            WeatherSettings(model: model)
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

/// Where the weather is read from, and what showing it costs on a clock this
/// app does not own alone.
///
/// One field holding both numbers rather than two holding halves of one place,
/// and typed rather than asked for: CoreLocation cannot be authorized by an
/// unsigned binary on this machine — probed, and `requestLocation` comes back
/// `kCLErrorDenied` — and a desk clock does not travel anyway.
///
/// The line under it is the part that is not decoration. `OVERLAY` is a GLOBAL
/// device setting, the same one the clock's own web interface writes, so an
/// overlay set by hand is replaced the next time the weather changes. Said
/// here, that is a documented consequence; unsaid, it is somebody chasing a bug
/// in the firmware.
///
/// A view of its own rather than a section inside `SettingsSheet`, and the
/// reason is measurable: laying the whole settings surface out costs 57 ms of
/// SYNCHRONOUS main-actor work — the two 24-hour pickers are most of it — and
/// every rendering test spends that out of the budget of whatever poll is
/// running beside it. A test about this section can now draw this section. What
/// keeps that honest is that the section being ON the settings surface is
/// proved separately, by reading the location box off the control tree.
struct WeatherSettings: View {
    @ObservedObject var model: AppModel

    /// What the weather costs on a device this app shares.
    ///
    /// Held as a constant so a test can name the rule it is checking rather
    /// than the sentence, and so the sentence can be reworded without hunting
    /// for whoever asserted it.
    static let overlayIsSharedWithTheDevice =
        "The clock's weather overlay is set from here. It is one device-wide "
            + "setting, so an overlay you set by hand is replaced when the weather "
            + "next changes, and put back as you left it when this connector is "
            + "switched off."

    /// Said because the connector ships switched ON.
    ///
    /// The first launch puts weather on the clock and takes the device-wide
    /// overlay without anybody having asked for either. That is the design —
    /// an app that showed nothing until it was configured would be a menu bar
    /// item with nothing behind it — but it is not something a user should
    /// discover from the clock.
    static let weatherStartsSwitchedOn =
        "Weather is on from the first launch. Switch it off here to stop it and "
            + "hand the overlay back."

    /// The connector this section is about, or none when nothing weather-shaped
    /// is registered.
    ///
    /// Found by TYPE rather than by the id "weather". A string here is a lookup
    /// that can silently stop matching — rename the connector's id and the
    /// switch quietly disappears from a surface that still carries the sentence
    /// telling you to use it — where a type is checked by the compiler. Read off
    /// the registry rather than handed in, because that is where the panel reads
    /// its own connectors from and a second route would be a second answer.
    ///
    /// Optional, and drawn only when it is there: no weather connector means no
    /// weather switch, which is honest. The section's location field is not
    /// conditional on it, because a location is a stored setting that outlives
    /// whatever is reading it.
    private var connector: (any Connector)? {
        model.registry.all.first { $0 is WeatherConnector }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Where the panel's weather row used to be. The panel is opened
            // dozens of times a day to answer "is the clock alive, and run
            // something now", and this connector answers neither — but it is
            // still something that can be switched off, and a connector with
            // nowhere to switch it off is one the user cannot stop.
            //
            // Labelled with the connector's own name, which is the label the
            // row carried: the control moved surfaces and was not renamed on
            // the way.
            if let connector {
                Toggle(connector.displayName, isOn: Binding(
                    get: { model.settings(for: connector).isEnabled },
                    set: { model.setEnabled($0, for: connector) }
                ))
                .controlSize(.small)
            }
            Text("Weather location").font(.caption).foregroundStyle(.secondary)
            TextField("Latitude, longitude", text: $model.typedLocation)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            if let note = model.locationNote {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(Self.overlayIsSharedWithTheDevice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.weatherStartsSwitchedOn)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
