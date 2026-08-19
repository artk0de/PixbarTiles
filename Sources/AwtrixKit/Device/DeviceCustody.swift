import Foundation

/// What this app has borrowed or added on the device, and how to give it back.
///
/// Two things go on the clock that are not this app's to keep. `OVERLAY` is a
/// GLOBAL setting — not scoped to an app, written to flash, and changeable by
/// hand from the device's own web interface — so writing it means displacing a
/// value somebody else chose. An app in the loop is the other: it stays in the
/// rotation until something removes it.
///
/// Three rules follow, and each of them is a defect if it is missing.
///
/// Read the overlay that was there BEFORE the first write and put that back,
/// rather than assuming `clear`. The plan's constraint is that the app removes
/// what it created, and a setting is as much of a trace as a file on the flash.
///
/// Never rewrite an unchanged overlay. It is a flash write on a device that
/// lives on a shelf for years, and an identical value buys nothing at all. The
/// app in the loop is the opposite case and is rewritten every time: it lives
/// in RAM, so a clock that reboots comes back without it and a
/// skip-if-unchanged would never put it back.
///
/// And the overlay has exactly one borrower, because there is exactly one of
/// it. A connector switched off gives back only what it took; another
/// connector's overlay is not its to restore.
public actor DeviceCustody {
    private let device: AwtrixDevice

    /// The overlay this app displaced, what it wrote over it, and which
    /// connector asked. One global setting, so one record.
    private var overlay: (before: String, applied: DeviceOverlay, borrower: String)?
    /// Apps put in the loop, by the connector that asked for them.
    private var apps: [String: Set<String>] = [:]

    public init(device: AwtrixDevice) {
        self.device = device
    }

    /// Puts this app's overlay on the device, remembering what it displaced.
    ///
    /// The read comes first and is allowed to fail the whole call. Writing a
    /// global setting whose previous value could not be read would leave
    /// nothing to put back — better to deliver nothing than to take something
    /// this app cannot return.
    public func apply(_ wanted: DeviceOverlay, for connectorId: String) async throws {
        if let held = overlay, held.borrower == connectorId, held.applied == wanted { return }

        // The ORIGINAL, never the value written on the way past: a connector
        // that has already borrowed this keeps the overlay it first displaced.
        // A firmware with no OVERLAY key at all reads as `clear`, which is the
        // value it coerces every unknown name to and so the closest thing it
        // has to "nothing set".
        let before: String
        if let held = overlay {
            before = held.before
        } else {
            before = try await device.settings().overlay ?? DeviceOverlay.clear.rawValue
        }
        try await device.setOverlay(named: wanted.rawValue)
        overlay = (before: before, applied: wanted, borrower: connectorId)
    }

    /// Puts an app in the device's loop, remembering that it is this app's to
    /// remove.
    public func show(
        _ payload: AppPayload, named name: String, for connectorId: String
    ) async throws {
        try await device.showApp(payload, named: name)
        apps[connectorId, default: []].insert(name)
    }

    /// Puts the device back the way this app found it.
    ///
    /// - Parameter connectorId: only what this connector took, or nil for
    ///   everything outstanding — which is what a quit wants, since it is not
    ///   about any one connector.
    ///
    /// What was given back is forgotten only once the device has confirmed it.
    /// A restore that failed against an unreachable clock leaves the record
    /// standing, so the next one still knows what to put back rather than
    /// having quietly dropped it.
    public func restore(borrowedBy connectorId: String?) async throws {
        // Every piece is attempted independently, and the first failure is
        // reported only once they all have been. The two are not a sequence:
        // an app in the loop is RAM and dies with the next reboot anyway, while
        // the overlay is a setting in flash that outlives the app, the loop and
        // this process. Written as a straight line of `try`s, a clock that had
        // stopped answering — the ordinary state of one during a quit, since
        // unplugging things is usually why somebody is quitting — would throw
        // on the app removal and never reach the overlay at all, leaving the
        // worse of the two traces behind for the better one.
        var failure: (any Error)?

        for (id, names) in apps where connectorId == nil || connectorId == id {
            for name in names {
                do {
                    try await device.removeApp(named: name)
                    apps[id]?.remove(name)
                } catch {
                    failure = failure ?? error
                }
            }
            if apps[id]?.isEmpty == true { apps[id] = nil }
        }

        if let held = overlay, connectorId == nil || connectorId == held.borrower {
            do {
                try await device.setOverlay(named: held.before)
                overlay = nil
            } catch {
                failure = failure ?? error
            }
        }

        if let failure { throw failure }
    }
}
