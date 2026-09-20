import PixelClockKit
import SwiftUI

/// The selected clock's status: connectivity, address, battery when the clock
/// reports one, and the discovery line when there is something to say.
///
/// Composition over the existing status lines — `DeviceStatusLine`,
/// `DiscoveryStatusLine` and `BatteryLine`, which stay where they are until
/// the switch-over moves them beside this block. No new line text is invented
/// here; the block only decides WHICH of them the clock's inputs earn.
///
/// A nil battery is no battery CELL, not a placeholder: the TC002's stock
/// firmware answers no level over its API, so whatever drew there would be a
/// guess. Which clock can report one is decided upstream — the block is
/// handed nil and draws nothing.
struct ClockStatusBlock: View {
    let state: DeviceState
    let address: String
    let battery: BatteryReading?
    let discovery: DiscoveryState?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(DeviceStatusLine.colour(for: state))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(DeviceStatusLine.title(for: state))
                        .font(.headline)
                    // The address and the battery in one row but two labels:
                    // only the second of them turns orange, and a single
                    // string would have taken the address with it.
                    HStack(spacing: 4) {
                        Text(address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let line = battery.map(BatteryLine.text) ?? nil {
                            Text("· " + line)
                                .font(.caption)
                                .foregroundStyle(BatteryLine.colour(for: battery))
                        }
                    }
                }
            }
            if let line = discovery.map(DiscoveryStatusLine.text) ?? nil {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
