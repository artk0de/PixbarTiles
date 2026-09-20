import Foundation
import PixelClockKit

/// One TC002 clock's answer to "are you there".
///
/// What `ClockHealth` is for an AWTRIX clock, minus everything this firmware
/// does not have: no battery (the stock firmware answers no level, and the
/// panel draws no battery line at all rather than a placeholder), no
/// relocation (the broadcast carries the MAC the store already keeps), and no
/// stats — the only health surface is `/getBase`, whose body is an identity
/// and nothing more. There is nothing here to carry in a
/// `DeviceState.online`, so the answering state is this type's own three
/// cases, said in the words `DeviceStatusLine` uses for every other clock.
///
/// `@unchecked` names what the isolation checker cannot see, exactly as on
/// `ClockHealth`: every mutable field here is `@MainActor`-confined.
@MainActor
final class UlanziClockHealth: @unchecked Sendable {
    enum Answering: Equatable {
        /// No poll has run yet. Not online, and not offline either — an
        /// answer nobody took is not a disconnection.
        case notAsked
        /// `/getBase` answered an identity.
        case answering
        /// The poll asked and nothing usable came back.
        case unreachable
    }

    let clockId: UUID
    let name: String
    private(set) var answering: Answering = .notAsked
    private let device: UlanziDevice

    init(clockId: UUID, name: String, device: UlanziDevice) {
        self.clockId = clockId
        self.name = name
        self.device = device
    }

    var isOnline: Bool { answering == .answering }

    /// One poll: the clock answered or it did not. No threshold to cross and
    /// no warning to return — there is nothing here whose level could move.
    func poll(at now: Date) async -> BatteryWarning? {
        do {
            _ = try await device.identity()
            answering = .answering
        } catch {
            answering = .unreachable
        }
        return nil
    }
}
