import AppKit
import AwtrixKit
import SwiftUI

/// What the dot and the line above it say about the device.
///
/// Three states, not two. `isOnline` is false for `.unknown` as much as for
/// `.offline`, so a panel opened in the first twenty seconds after launch —
/// before the first poll has answered — announced a disconnection it had no
/// grounds for. That conflation is the same one `DeviceState` exists to prevent.
enum DeviceStatusLine {
    static func title(for state: DeviceState) -> String {
        switch state {
        case .unknown: "Checking…"
        case .online: "Connected"
        case .offline: "Disconnected"
        }
    }

    static func colour(for state: DeviceState) -> Color {
        switch state {
        case .unknown: .secondary
        case .online: .green
        case .offline: .red
        }
    }
}

/// What the line under the status says about the network.
///
/// Five answers rather than a list that may be empty, because "you have not
/// been asked yet", "still looking", "nothing is advertising here" and "you
/// refused this app the local network" all render as zero devices and only one
/// of them is fixed by plugging the clock in. A panel that says "no devices
/// found" to somebody who declined the permission prompt has sent them to look
/// at their router.
enum DiscoveryStatusLine {
    static func text(for state: DiscoveryState) -> String? {
        switch state {
        case .idle:
            nil
        case .searching:
            "Looking for AWTRIX devices…"
        case let .listed(devices):
            listing(devices)
        case let .unavailable(reason):
            "Waiting for a network to browse — \(reason)"
        case .denied:
            "Local Network access is off for this app — turn it on in System "
                + "Settings › Privacy & Security › Local Network"
        case let .failed(reason):
            "Could not look for devices: \(reason)"
        }
    }

    /// Names every instance, and never counts them.
    ///
    /// The name is the only thing a browse knows — the instance name is not a
    /// hostname, `awtrix.local` does not resolve — so "2 devices found" leaves
    /// the reader with nothing they can act on. With more than one advertising
    /// itself, the address the app talks to is the thing that decides which,
    /// and it is not something discovery may pick on the user's behalf.
    private static func listing(_ devices: [DiscoveredDevice]) -> String {
        guard devices.isEmpty == false else {
            return "No AWTRIX device is advertising itself on this network"
        }
        let names = devices.map(\.instanceName).joined(separator: ", ")
        guard devices.count > 1 else { return "Seen on the network: \(names)" }
        return "Seen on the network: \(names) — the address below decides which one this "
            + "app talks to"
    }
}

/// Where the next launch will look for the clock.
///
/// The write half of what the discovery line tells the user. Its own type
/// rather than a closure in the view, because the rule that makes it safe — a
/// blank field is not saved — is behaviour, and a `TextField`'s action closure
/// is not somewhere behaviour can be read back from.
@MainActor
enum DeviceHostField {
    /// Said after a save, and deliberately not "connected".
    ///
    /// `AppModel` reads the address once at launch and hands it to the device,
    /// the monitor and the host; nothing rebuilds those underneath a running
    /// schedule, so a field that implied the app had moved to the new address
    /// would be lying until the next launch.
    static let takesEffectNextLaunch = "Saved — takes effect at next launch"

    /// Stores a typed address for the next launch, and answers what to say.
    ///
    /// Nil when there is nothing to store. A blank or whitespace-only entry is
    /// refused rather than written: the next launch would come up pointed at an
    /// empty host, and the panel that could fix it is the one behind the device
    /// that no longer answers.
    @discardableResult
    static func save(_ typed: String, to defaults: UserDefaults) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        defaults.set(trimmed, forKey: AppModel.deviceHostKey)
        return takesEffectNextLaunch
    }
}

/// When the next run is due, or what is holding it.
///
/// A time and a reason are the same slot because they answer the same question,
/// and only one of them is ever true. Naming an hour while something is holding
/// the schedule is the failure worth avoiding: the user plans around it.
enum NextRunLine {
    static func text(for next: NextRun?) -> String? {
        switch next {
        case nil: nil
        case let .due(date): "next \(date.formatted(date: .omitted, time: .shortened))"
        case let .held(reason): reason
        }
    }
}

struct MenuPanel: View {
    @ObservedObject var model: AppModel
    /// Observed separately from `model`: a nested `ObservableObject` publishes
    /// nothing to whoever holds it, so a view that wants the battery reading has
    /// to watch the monitor itself.
    @ObservedObject var monitor: DeviceMonitor
    /// Observed separately for the same reason `monitor` is: a nested
    /// `ObservableObject` publishes nothing to whoever holds it.
    @ObservedObject var discovery: DeviceBrowser
    var body: some View {
        if model.settingsAreOpen {
            SettingsSheet(model: model)
        } else {
            panel
        }
    }

    /// What a click opens: is the clock alive, and run something now.
    ///
    /// Everything set once and forgotten went behind the gear in the last row.
    /// The address field and the icon action were each a row of a menu that
    /// opens dozens of times a day and were each reached for about once.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusSection
            discoverySection
            Divider()
            ForEach(model.registry.all, id: \.id) { connector in
                connectorRow(connector)
            }
            Divider()
            lastRow
        }
        .padding(14)
        .frame(width: 320)
    }

    /// Quit, and the gear.
    ///
    /// The gear shares the row rather than taking one of its own: it is a corner
    /// of what is already there, and a panel that grew a row to hold a settings
    /// button would have paid for the tidying with the space it was tidying.
    private var lastRow: some View {
        HStack {
            Button("Quit") { NSApplication.shared.terminate(nil) }
            Spacer()
            Button { model.openSettings() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Settings")
        }
    }

    private var statusSection: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(DeviceStatusLine.colour(for: monitor.state))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(DeviceStatusLine.title(for: monitor.state))
                    .font(.headline)
                Text(model.deviceHost + (monitor.batteryPercent.map { " · \($0)%" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What is advertising itself on the network, kept apart from the status
    /// line above it.
    ///
    /// Two lines with two sources, deliberately not merged: the status line is
    /// the monitor's answer about the address this app is pointed at, and this
    /// one is a Bonjour advertisement. A clock can advertise itself and still
    /// not answer `/api/stats` — a different subnet, firmware still booting,
    /// the web interface switched off — so being seen here is not being
    /// reachable, and the panel never says it is.
    ///
    /// There is no field to type an address into, and that is not an omission:
    /// `deviceHost` is read once at launch because changing it would have to
    /// rebuild the device, the monitor and the host underneath a running
    /// schedule. What this line is for is knowing WHICH name to write with
    /// `defaults write dev.artk0re.awtrix-connectors deviceHost …`, which
    /// previously meant knowing it by heart.
    private var discoverySection: some View {
        Group {
            if let line = DiscoveryStatusLine.text(for: discovery.state) {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connectorRow(_ connector: any Connector) -> some View {
        let settings = model.settings(for: connector)
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(connector.displayName, isOn: Binding(
                get: { settings.isEnabled },
                set: { model.setEnabled($0, for: connector) }
            ))
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(settings.intervalPosition) },
                        set: { model.setIntervalPosition(Int($0.rounded()), for: connector) }
                    ),
                    in: 0...Double(IntervalScale.positions.count - 1),
                    step: 1
                )
                Text(IntervalScale.label(atPosition: settings.intervalPosition))
                    .font(.caption.monospacedDigit())
                    .frame(width: 48, alignment: .trailing)
            }
            HStack {
                Button("Run now") { model.runNow(connector.id) }
                    .controlSize(.small)
                // Beside the button that overrides it, because the two answer
                // the same question from opposite ends: when will this happen,
                // and make it happen now.
                if let due = NextRunLine.text(for: model.nextRun[connector.id]) {
                    Text(due).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let result = model.lastResults[connector.id] {
                    Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            // Under the run's own line rather than beside it, and only when
            // there is something wrong. The two answer different questions —
            // how the last delivery went, and whether there will be anything to
            // deliver next time — and a restock that is working has nothing to
            // say about either.
            if let trouble = model.lastMaintenanceFailure[connector.id] {
                Text(trouble)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
