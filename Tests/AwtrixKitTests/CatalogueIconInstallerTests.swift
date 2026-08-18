import Foundation
import Testing
@testable import AwtrixKit

// MARK: - Doubles

private struct Route: Sendable {
    let match: String
    let status: Int
    let body: Data
}

/// Answers per-URL so one test can serve both a device listing and a CDN
/// download — the installer talks to two different hosts through one transport.
///
/// The routing table is a `let` handed in at init rather than a mutable
/// property: nothing here needs to re-route mid-test, and an immutable table is
/// one fewer thing for `@unchecked` to be covering up. What remains mutable is
/// the request log, and every access to it goes through `lock` — the actor
/// under test calls `send` from a task the test does not own. `Mutex` would
/// satisfy the checker without `@unchecked`, but it is macOS 15+ and this
/// package floors at macOS 14.
private final class RoutingTransport: Transport, @unchecked Sendable {
    private let routes: [Route]
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    init(_ routes: [Route] = []) {
        self.routes = routes
    }

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        let url = request.url?.absoluteString ?? ""
        let route = routes.first { url.contains($0.match) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: route?.status ?? 200, httpVersion: nil, headerFields: nil
        )!
        return (route?.body ?? Data("OK".utf8), response)
    }
}

private let emptyIconDirectory = Route(match: "/list?dir=/ICONS", status: 200, body: Data("[]".utf8))

private func iconDirectory(holding names: String...) -> Route {
    let entries = names.map { #"{"type":"file","size":"131","name":"\#($0)"}"# }
    return Route(
        match: "/list?dir=/ICONS", status: 200,
        body: Data("[\(entries.joined(separator: ","))]".utf8)
    )
}

/// A GIF89a header followed by a few bytes of nothing in particular. Only the
/// signature is load-bearing — nothing in this package decodes the image.
private let gifBytes = Data("GIF89a".utf8) + Data([0x01, 0x00, 0x01, 0x00])

private func installer(_ transport: RoutingTransport) -> CatalogueIconInstaller {
    CatalogueIconInstaller(
        device: AwtrixDevice(host: "10.0.0.5", transport: transport), transport: transport
    )
}

private func uploads(_ transport: RoutingTransport) -> [URLRequest] {
    transport.requests.filter { $0.url?.path == "/edit" && $0.httpMethod == "POST" }
}

private func catalogueFetches(_ transport: RoutingTransport) -> [URLRequest] {
    transport.requests.filter { $0.url?.absoluteString.contains("icon_thumbs") == true }
}

// MARK: - Tests

@Test func installedIconIsReturnedAsIs() async throws {
    // A listing is wired up on purpose. An installer that went and confirmed
    // the name against the device would then succeed, and be caught by the
    // assertion below rather than by a decode error on an unrouted reply.
    let transport = RoutingTransport([emptyIconDirectory])

    let name = try await installer(transport).ensureInstalled(.installed("laugh"))

    #expect(name == "laugh")
    // Not "no upload" but "no traffic at all": a name the user typed is taken
    // at its word, so neither the catalogue nor the device is consulted.
    #expect(transport.requests.isEmpty)
}

@Test func catalogueIconIsDownloadedAndUploadedOnce() async throws {
    let transport = RoutingTransport([
        emptyIconDirectory,
        Route(match: "icon_thumbs/9039.gif", status: 200, body: gifBytes),
    ])

    let name = try await installer(transport).ensureInstalled(.catalogue(9039))

    #expect(name == "9039")

    let fetches = catalogueFetches(transport)
    #expect(fetches.count == 1)
    #expect(
        fetches.first?.url?.absoluteString
            == "https://developer.lametric.com/content/apps/icon_thumbs/9039.gif"
    )
    // Pinned so that dropping the header is a decision. The CDN does not
    // currently gate on the agent — checked 2026-08-18 under a browser agent, a
    // default one and none — so this asserts an intent, not an observed need.
    #expect(fetches.first?.value(forHTTPHeaderField: "User-Agent") == "Mozilla/5.0")

    // "Once" is the claim in the name of this test, so it is the assertion:
    // exactly one upload, carrying those bytes to that path.
    let sent = uploads(transport)
    #expect(sent.count == 1)
    let body = String(decoding: try #require(sent.first?.httpBody), as: UTF8.self)
    #expect(body.contains(#"filename="/ICONS/9039.gif""#))
    #expect(body.contains("GIF89a"))
}

@Test func anIconAlreadyOnTheDeviceIsNotReuploaded() async throws {
    // The CDN is wired up and would answer with a perfectly good icon. Leaving
    // it unrouted would make this test pass off the download failing, which is
    // not the rule in its name.
    let transport = RoutingTransport([
        iconDirectory(holding: "9039.gif"),
        Route(match: "icon_thumbs/9039.gif", status: 200, body: gifBytes),
    ])

    let name = try await installer(transport).ensureInstalled(.catalogue(9039))

    #expect(name == "9039")
    #expect(uploads(transport).isEmpty)
    // And not downloaded either. Skipping only the upload would still pay for
    // the fetch on every single delivery.
    #expect(catalogueFetches(transport).isEmpty)
}

@Test func aDifferentIconOnTheDeviceDoesNotCountAsThisOne() async throws {
    let transport = RoutingTransport([
        iconDirectory(holding: "90391.gif", "1903.gif"),
        Route(match: "icon_thumbs/9039.gif", status: 200, body: gifBytes),
    ])

    let name = try await installer(transport).ensureInstalled(.catalogue(9039))

    #expect(name == "9039")
    #expect(uploads(transport).count == 1)
}

@Test func anHtmlErrorPageIsRejectedRatherThanInstalled() async {
    let transport = RoutingTransport([
        emptyIconDirectory,
        // The harder of the two error shapes, and the one a status check would
        // install. The CDN's own answer for a bogus id is a 404 carrying HTML
        // (checked 2026-08-18), which this same guard rejects on the same
        // grounds; a 200 carrying HTML is what a WAF, a captive portal or a CDN
        // error page serves, and only the bytes catch that one.
        Route(
            match: "icon_thumbs/1.gif", status: 200,
            body: Data("<!DOCTYPE html><html>not found</html>".utf8)
        ),
    ])
    let subject = installer(transport)

    await #expect(throws: CatalogueIconInstaller.Failure.notAnImage(1)) {
        _ = try await subject.ensureInstalled(.catalogue(1))
    }

    // Rejected before the flash is touched. Throwing after the upload would
    // leave a page of HTML on the device named `1.gif`.
    #expect(uploads(transport).isEmpty)
}

@Test func aTruncatedSignatureIsNotAnImageEither() async {
    let transport = RoutingTransport([
        emptyIconDirectory,
        Route(match: "icon_thumbs/2.gif", status: 200, body: Data("GIF".utf8)),
    ])
    let subject = installer(transport)

    // Three bytes are not a signature: GIF has exactly two, GIF87a and GIF89a,
    // and both are six bytes long.
    await #expect(throws: CatalogueIconInstaller.Failure.notAnImage(2)) {
        _ = try await subject.ensureInstalled(.catalogue(2))
    }
}

@Test func theStatusIsNotWhatDecidesWhetherBytesAreAnImage() async throws {
    let transport = RoutingTransport([
        emptyIconDirectory,
        Route(match: "icon_thumbs/9039.gif", status: 404, body: gifBytes),
    ])

    // The mirror of the HTML case. Not a shape this CDN produces — its error
    // bodies are HTML — but the rule it pins is the one that makes bytes-first
    // strictly safer than a status check, and it is here so that "harden this
    // by reading the status" fails a test instead of passing review.
    let name = try await installer(transport).ensureInstalled(.catalogue(9039))

    #expect(name == "9039")
    #expect(uploads(transport).count == 1)
}

@Test func aDeviceThatCannotBeListedFailsTheInstall() async {
    let transport = RoutingTransport([
        Route(match: "/list?dir=/ICONS", status: 500, body: Data("boom".utf8)),
    ])
    let subject = installer(transport)

    // Not a `notAnImage`: the catalogue was never asked. A failure to reach the
    // device has to arrive as a device failure, or the app reports a missing
    // icon when what it has is a missing clock.
    await #expect(throws: AwtrixError.self) {
        _ = try await subject.ensureInstalled(.catalogue(9039))
    }
    #expect(catalogueFetches(transport).isEmpty)
}
