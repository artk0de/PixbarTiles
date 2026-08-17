import Foundation

public enum AwtrixError: Error, Sendable {
    case http(status: Int, body: String, endpoint: String)
    case invalidHost(String)
}

extension AwtrixError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .http(status, body, endpoint):
            return "\(endpoint) -> HTTP \(status): \(body)"
        case let .invalidHost(host):
            return "invalid device host: \(host)"
        }
    }
}
