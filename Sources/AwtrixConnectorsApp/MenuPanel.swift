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

struct MenuPanel: View {
    @ObservedObject var model: AppModel
    /// Observed separately from `model`: a nested `ObservableObject` publishes
    /// nothing to whoever holds it, so a view that wants the battery reading has
    /// to watch the monitor itself.
    @ObservedObject var monitor: DeviceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusSection
            Divider()
            ForEach(model.registry.all, id: \.id) { connector in
                connectorRow(connector)
            }
            Divider()
            iconSection
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 320)
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

    /// The only thing this app writes to the device's flash, and the only way to
    /// take it back off.
    ///
    /// A menu item rather than something quit does: the icons are meant to
    /// survive quit and relaunch, so removing them on the way out would
    /// re-download the same bytes on the way back in.
    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Remove icons this app uploaded") { model.removeInstalledIcons() }
            .controlSize(.small)
            if let status = model.iconStatus {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                if let result = model.lastResults[connector.id] {
                    Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
