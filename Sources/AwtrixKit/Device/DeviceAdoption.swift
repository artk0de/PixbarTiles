import Foundation

/// Which clock, out of everything advertising itself, this app may move onto
/// without being told — and how it proves the one it moved onto is the right
/// one.
///
/// A DHCP lease is the whole reason this exists. The address a person typed
/// into the panel is the address the clock had that day; the router hands out a
/// different one the next time the clock joins, and from then on every poll
/// spends the full 15-second transport timeout reaching a machine that is not
/// there. Bonjour has known where it went the entire time — what was missing
/// was the rule for when acting on that is safe.
///
/// Two rules, and the order between them is the design.
///
/// The remembered clock is consulted FIRST, and a count is not a tiebreaker for
/// it. "Exactly one device on the network" reads like a safe condition and is
/// the dangerous one: our clock unplugged and a neighbour's advertising is
/// exactly one device, and moving onto it would write to their overlay and put
/// an app in their loop, silently, on a machine nobody asked us to touch.
///
/// A count decides only where there is nothing to remember, which is a first
/// launch. One clock and no memory is not a choice being made on somebody's
/// behalf; two clocks and no memory is, so that answers nothing and the panel
/// goes on saying what it sees.
public enum DeviceAdoption {
    /// The clock to try, or nil when nothing here may be moved onto silently.
    ///
    /// - Parameters:
    ///   - uid: the clock this app has already been talking to, as the firmware
    ///     names itself in `/api/stats`. Nil before any poll has ever answered.
    ///   - devices: what a browse found, already filtered to AWTRIX instances.
    public static func candidate(
        remembering uid: String?, among devices: [DiscoveredDevice]
    ) -> DiscoveredDevice? {
        guard let uid else { return devices.count == 1 ? devices.first : nil }
        return devices.first { sameName($0.instanceName, uid) }
    }

    /// Whether the clock that answered at an address is the clock that was
    /// found at it.
    ///
    /// `<instanceName>.local` is a construction this app makes, not a fact it
    /// was handed, and mDNS is a cache that can answer for a name whose lease
    /// has moved on. Asking the address who it is turns the construction into
    /// evidence — and it costs one request that has to be made anyway, since
    /// nothing is worth adopting that cannot be reached.
    public static func isTheSameClock(_ probedUID: String, as device: DiscoveredDevice) -> Bool {
        sameName(probedUID, device.instanceName)
    }

    /// One clock's name reaching this app by two routes — a Bonjour browse and
    /// the firmware's own `/api/stats` — with nothing promising the two agree
    /// on case. `DeviceDiscovery.isAwtrixInstance` lowercases for the same
    /// reason: the name is whatever the firmware was flashed with.
    private static func sameName(_ one: String, _ other: String) -> Bool {
        one.lowercased() == other.lowercased()
    }
}
