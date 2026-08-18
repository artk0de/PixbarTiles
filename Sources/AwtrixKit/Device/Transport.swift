import Foundation

/// Everything that reaches the device goes through here, so tests can observe it.
public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: Transport {
    /// How long a single request may take.
    ///
    /// Named rather than written into the signature because it is the longest
    /// anything reaching the device can block, which makes it the budget for
    /// every wait built on top of one — the app's quit path reads it for
    /// exactly that reason.
    public static let defaultTimeout: TimeInterval = 15

    private let session: URLSession

    public init(timeout: TimeInterval = URLSessionTransport.defaultTimeout) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
