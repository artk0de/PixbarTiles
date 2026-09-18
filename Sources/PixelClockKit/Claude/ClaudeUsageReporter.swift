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

    /// The token this reporter is currently working with.
    ///
    /// Held in memory for as long as it works, and that is a fix for a
    /// complaint rather than an optimisation. Reading it means reaching into
    /// ANOTHER application's keychain item, and macOS may put a password prompt
    /// in front of any such read. The connector polls every five minutes, so
    /// fetching it each time was two hundred and eighty-eight opportunities a
    /// day for that dialog — which is exactly what was reported.
    ///
    /// A class rather than a stored property because this type is a struct that
    /// gets copied around; the cache has to be the same one whichever copy is
    /// asked.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?

        func current() -> String? { lock.withLock { token } }
        func remember(_ value: String) { lock.withLock { token = value } }
        func forget() { lock.withLock { token = nil } }
    }

    private let transport: any Transport
    private let credentials: any ClaudeCredentialReading
    private let cache = Cache()

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
        // The one held in memory first. Reaching for the keychain is what puts a
        // password prompt on screen, so it is done as rarely as the service
        // allows rather than on every poll.
        //
        // This replaced "read every time so a renewal is picked up without being
        // told", which was correct about renewals and wrong about everything
        // else: at a five-minute poll it was 288 reads of another application's
        // keychain item a day, and 288 chances for that dialog.
        guard let token = cache.current() ?? credentials.accessToken() else { return nil }

        let first = await ask(with: token)
        guard first.refused else {
            if first.reading != nil { cache.remember(token) }
            return first.reading
        }

        // Refused, which is the one answer that means the held token is no
        // longer the right one — Claude Code renewed it. So this is where a
        // fresh read is paid for. Once, and never in a loop: a store handing
        // back the same refused token must not be asked forever.
        cache.forget()
        guard let renewed = credentials.accessToken(), renewed != token else { return nil }

        let second = await ask(with: renewed)
        guard !second.refused, let reading = second.reading else { return nil }
        cache.remember(renewed)
        return reading
    }

    /// One request, and whether the service refused the credential.
    ///
    /// The refusal is answered apart from the reading because the two mean
    /// different things here: a refusal is worth spending a keychain read on,
    /// and every other failure — a flat network, a bad day at the service — is
    /// not, because the token is fine and re-reading it would only raise a
    /// dialog for nothing.
    private func ask(with token: String) async -> (reading: ClaudeUsageReading?, refused: Bool) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")

        guard let (data, response) = try? await transport.send(request) else { return (nil, false) }
        if response.statusCode == 401 || response.statusCode == 403 { return (nil, true) }
        guard (200..<300).contains(response.statusCode) else { return (nil, false) }
        return (ClaudeUsageReading(json: data), false)
    }
}
