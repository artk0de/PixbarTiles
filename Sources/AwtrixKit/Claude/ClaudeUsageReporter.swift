import Foundation

/// Asks Anthropic what is left of this week's allowance.
///
/// One GET against an endpoint that exists for exactly this and costs no model
/// tokens. The same figures ride on the headers of every ordinary API response,
/// which was the alternative — and it was rejected because reading them means
/// making a real request to a model and paying for it to draw an indicator.
public struct ClaudeUsageReporter: ClaudeUsageReporting {
    /// Verified to exist against the live service on 2026-08-20: it answered a
    /// stale token with a proper authentication error rather than a 404, which
    /// is a route saying "you are not signed in", not "there is nothing here".
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// The endpoint belongs to the OAuth surface rather than the messages API,
    /// and this header is what selects it.
    static let betaHeader = "oauth-2025-04-20"

    private let transport: any Transport
    private let credentials: any ClaudeCredentialReading

    public init(
        transport: any Transport = URLSessionTransport(),
        credentials: any ClaudeCredentialReading = AnyClaudeCredentials()
    ) {
        self.transport = transport
        self.credentials = credentials
    }

    /// The weekly reading, or nil for every flavour of "cannot tell".
    ///
    /// No credential, an expired one, a service having a bad day, an answer
    /// carrying no weekly bar — all of them answer nil, and none of them throws.
    /// The distinction the caller needs is only between a figure and no figure:
    /// the connector turns nil into no delivery, and the clock drops the app
    /// when its lifetime expires, which stops the matrix claiming a number
    /// nothing can currently support. Reporting zero instead would be a calm,
    /// confident lie.
    public func read() async throws -> ClaudeUsageReading? {
        // Read every time rather than caching, so the poll after Claude Code
        // renews its token picks the new one up without being told.
        guard let token = credentials.accessToken() else { return nil }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")

        guard let (data, response) = try? await transport.send(request) else { return nil }
        guard (200..<300).contains(response.statusCode) else { return nil }
        return ClaudeUsageReading(json: data)
    }
}
