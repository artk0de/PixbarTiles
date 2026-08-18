// `ObservableObject` and `@Published` are declared in Combine. Foundation
// re-exports both as typealiases, so this import is not required to compile —
// it names the framework that actually declares them.
import Combine
import Foundation

public enum DeviceState: Sendable, Equatable {
    case unknown
    case online(DeviceStats)
    case offline(String)
}

/// Publishes device reachability for the menu bar. Owns no timer — the app
/// decides how often to ask, which keeps this testable without real time.
@MainActor
public final class DeviceMonitor: ObservableObject {
    @Published public private(set) var state: DeviceState = .unknown

    private let device: AwtrixDevice

    public init(device: AwtrixDevice) {
        self.device = device
    }

    public func refresh() async {
        do {
            state = .online(try await device.stats())
        } catch {
            state = .offline(error.localizedDescription)
        }
    }

    public var isOnline: Bool {
        if case .online = state { return true }
        return false
    }

    public var batteryPercent: Int? {
        guard case let .online(stats) = state else { return nil }
        return stats.bat
    }
}
