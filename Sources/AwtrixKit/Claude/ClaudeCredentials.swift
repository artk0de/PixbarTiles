import Foundation
import Security

/// Where this app finds the credential Claude Code signed in with.
///
/// Read-only by design, and the design is not a convenience. The token belongs
/// to another program: an OAuth refresh rotates the refresh token, so a refresh
/// performed here would invalidate the one Claude Code is holding and drop it
/// out of its own session in the middle of somebody's work. This app therefore
/// takes what is there and, when that has expired, reports nothing until Claude
/// Code renews it on its own account.
///
/// For the same reason nothing here caches. Every look is a fresh read, so the
/// poll after a renewal picks up the new token without anything being told.
public protocol ClaudeCredentialReading: Sendable {
    /// The current access token, or nil when there is not one to be had.
    func accessToken() -> String?
}

/// The token as Claude Code keeps it in the login keychain.
///
/// The first place to look, because it is where a running installation actually
/// keeps it: the JSON file beside it can be months stale while the program
/// works perfectly, which is exactly what was observed on this machine.
///
/// Reading another application's keychain item prompts the user the first time
/// and remembers the answer against this app's signature — which is why the app
/// is signed with a stable identity rather than ad hoc, and why a re-signed
/// build asks again.
public struct KeychainClaudeCredentials: ClaudeCredentialReading {
    /// The service names to try, in order.
    ///
    /// A list rather than one name because the item is another program's and
    /// has been renamed across versions. Trying each costs one keychain lookup
    /// and removes a whole class of silent failure — an app that reports
    /// nothing forever because a string moved.
    public static let serviceNames = ["Claude Code-credentials", "Claude Code"]

    private let services: [String]

    public init(services: [String] = KeychainClaudeCredentials.serviceNames) {
        self.services = services
    }

    public func accessToken() -> String? {
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard
                SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                let blob = item as? Data
            else { continue }

            // The stored value is a JSON document rather than a bare token, and
            // it is another program's document — so it is searched by key name
            // at any depth rather than decoded into a shape written down here.
            if let token = ClaudeCredentialSearch.accessToken(inJSON: blob) { return token }
            // A keychain item holding the token unwrapped is still a token.
            if let plain = String(data: blob, encoding: .utf8),
               plain.hasPrefix("sk-"), !plain.contains("{") {
                return plain
            }
        }
        return nil
    }
}

/// The token as Claude Code leaves it on disk.
///
/// The fallback, not the primary: on a machine where the keychain holds the
/// live credential this file can be arbitrarily old, and trusting it first
/// produces an app that reports nothing while everything else works.
public struct FileClaudeCredentials: ClaudeCredentialReading {
    public static let defaultURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/.credentials.json")

    private let url: URL

    public init(url: URL = FileClaudeCredentials.defaultURL) {
        self.url = url
    }

    public func accessToken() -> String? {
        guard let blob = try? Data(contentsOf: url) else { return nil }
        return ClaudeCredentialSearch.accessToken(inJSON: blob)
    }
}

/// Tries each source in turn and answers with the first token found.
public struct AnyClaudeCredentials: ClaudeCredentialReading {
    private let sources: [any ClaudeCredentialReading]

    /// Keychain first, file second — see `FileClaudeCredentials` for why that
    /// order is load-bearing rather than arbitrary.
    public init(
        sources: [any ClaudeCredentialReading] = [
            KeychainClaudeCredentials(), FileClaudeCredentials(),
        ]
    ) {
        self.sources = sources
    }

    public func accessToken() -> String? {
        for source in sources {
            if let token = source.accessToken() { return token }
        }
        return nil
    }
}

/// Takes Claude's own access token out of a document that holds several.
enum ClaudeCredentialSearch {
    /// The one container Claude's own credential lives in.
    ///
    /// Named rather than searched for, and the naming is the safety property.
    /// The same document carries `mcpOAuth` — one entry per MCP server the user
    /// has signed into, each with an `accessToken` of its own. A search for the
    /// first `accessToken` at any depth returns whichever the dictionary
    /// happens to yield first, and dictionary order is not defined: on this
    /// machine that would have sent Figma's or Miro's credential to Anthropic.
    ///
    /// A named path breaks loudly if the shape moves — no token, no reading, an
    /// app that stops appearing. The greedy search breaks quietly and sends the
    /// wrong secret to the wrong host, which is not a trade worth making for
    /// resilience against a rename.
    private static let container = "claudeAiOauth"
    /// Both spellings, because the two stores this reads have used both.
    private static let tokenKeys = ["accessToken", "access_token"]

    static func accessToken(inJSON blob: Data) -> String? {
        guard
            let root = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
            let claude = root[container] as? [String: Any]
        else { return nil }

        for key in tokenKeys {
            if let token = claude[key] as? String, !token.isEmpty { return token }
        }
        return nil
    }
}
