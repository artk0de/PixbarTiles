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

extension AwtrixError: LocalizedError {
    /// Routed to `description` rather than repeating the text, so the two
    /// renderings cannot drift apart. Without this, `localizedDescription`
    /// falls back to "The operation couldn't be completed. (PixbarKit
    /// .AwtrixError error 0.)" — and `localizedDescription` is what callers
    /// reach for when they have to render an arbitrary `Error`.
    public var errorDescription: String? { description }
}
