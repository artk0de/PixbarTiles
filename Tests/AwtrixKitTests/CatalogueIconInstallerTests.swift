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

private func installer(
    _ transport: RoutingTransport,
    recordingInto uploads: any UploadedIconStore = InMemoryUploadedIconStore()
) -> CatalogueIconInstaller {
    CatalogueIconInstaller(
        device: AwtrixDevice(host: "10.0.0.5", transport: transport),
        transport: transport,
        uploads: uploads
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

// MARK: - What this app put on the flash

/// The paths named in `DELETE /edit` bodies, in call order. The device takes the
/// path in a multipart field rather than in the URL, so this is where a removal
/// is actually visible.
private func deletions(_ transport: RoutingTransport) -> [String] {
    transport.requests
        .filter { $0.url?.path == "/edit" && $0.httpMethod == "DELETE" }
        .compactMap { $0.httpBody }
        .map { String(decoding: $0, as: UTF8.self) }
}

@Test func installingAnIconRecordsItAsUploaded() async throws {
    let transport = RoutingTransport([
        emptyIconDirectory,
        Route(match: "icon_thumbs/9039.gif", status: 200, body: gifBytes),
    ])
    let uploads = InMemoryUploadedIconStore()

    _ = try await installer(transport, recordingInto: uploads).ensureInstalled(.catalogue(9039))

    #expect(uploads.uploadedIcons() == ["9039"])
}

// The one fact removal rests on. `<id>.gif` is the same name whether this app
// wrote it or the user did — deliberately, because that is what lets the skip
// below reuse an icon they already had — so an icon that was found rather than
// uploaded can never be told apart afterwards. If it is not recorded at the
// moment of the upload, it is not knowable at all.
@Test func anIconAlreadyOnTheDeviceIsNeverRecordedAsUploaded() async throws {
    let transport = RoutingTransport([
        iconDirectory(holding: "9039.gif"),
        Route(match: "icon_thumbs/9039.gif", status: 200, body: gifBytes),
    ])
    let uploads = InMemoryUploadedIconStore()

    _ = try await installer(transport, recordingInto: uploads).ensureInstalled(.catalogue(9039))

    #expect(uploads.uploadedIcons().isEmpty)
}

@Test func anIconNamedByTheUserIsNeverRecordedAsUploaded() async throws {
    let transport = RoutingTransport([emptyIconDirectory])
    let uploads = InMemoryUploadedIconStore()

    _ = try await installer(transport, recordingInto: uploads).ensureInstalled(.installed("laugh"))

    #expect(uploads.uploadedIcons().isEmpty)
}

@Test func aFailedInstallIsNeverRecordedAsUploaded() async {
    let transport = RoutingTransport([
        emptyIconDirectory,
        Route(match: "icon_thumbs/1.gif", status: 200, body: Data("<!DOCTYPE html>".utf8)),
    ])
    let uploads = InMemoryUploadedIconStore()
    let subject = installer(transport, recordingInto: uploads)

    _ = try? await subject.ensureInstalled(.catalogue(1))

    #expect(uploads.uploadedIcons().isEmpty)
}

@Test func removingUploadedIconsDeletesExactlyWhatThisAppUploaded() async throws {
    let transport = RoutingTransport([emptyIconDirectory])
    let uploads = InMemoryUploadedIconStore()
    uploads.record("9039")
    let subject = installer(transport, recordingInto: uploads)

    let removed = try await subject.removeUploaded()

    #expect(removed == ["9039"])
    #expect(deletions(transport).count == 1)
    #expect(deletions(transport).first?.contains("/ICONS/9039.gif") == true)
}

@Test func nothingUploadedMeansNothingRemoved() async throws {
    let transport = RoutingTransport([emptyIconDirectory])
    let subject = installer(transport, recordingInto: InMemoryUploadedIconStore())

    let removed = try await subject.removeUploaded()

    #expect(removed.isEmpty)
    // Not "no deletions" but "no traffic at all": an empty record must not send
    // the device a listing request either.
    #expect(transport.requests.isEmpty)
}

@Test func aRemovedIconIsForgottenSoASecondRemovalDoesNothing() async throws {
    let transport = RoutingTransport([emptyIconDirectory])
    let uploads = InMemoryUploadedIconStore()
    uploads.record("9039")
    let subject = installer(transport, recordingInto: uploads)

    _ = try await subject.removeUploaded()
    let again = try await subject.removeUploaded()

    #expect(again.isEmpty)
    #expect(uploads.uploadedIcons().isEmpty)
    #expect(deletions(transport).count == 1)
}

// The device is unreachable, or refuses. The icon is still on its flash, so
// forgetting it here would strand it there for good — nothing else in this app
// can ever name it again.
@Test func anIconThatCannotBeDeletedStaysRecorded() async {
    let transport = RoutingTransport([
        Route(match: "/edit", status: 500, body: Data("boom".utf8)),
    ])
    let uploads = InMemoryUploadedIconStore()
    uploads.record("9039")
    let subject = installer(transport, recordingInto: uploads)

    await #expect(throws: CatalogueIconInstaller.Failure.notRemoved(["9039"])) {
        _ = try await subject.removeUploaded()
    }

    #expect(uploads.uploadedIcons() == ["9039"])
}

@Test func whatWasUploadedSurvivesTheUserDefaultsStore() throws {
    let suite = "uploaded-icons-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    UserDefaultsUploadedIconStore(defaults: defaults).record("9039")

    // A second instance, because the point of this store is surviving a quit:
    // an icon uploaded in one launch is removable in the next.
    #expect(UserDefaultsUploadedIconStore(defaults: defaults).uploadedIcons() == ["9039"])

    UserDefaultsUploadedIconStore(defaults: defaults).forget("9039")

    #expect(UserDefaultsUploadedIconStore(defaults: defaults).uploadedIcons().isEmpty)
}

@Test func recordingTheSameIconTwiceRemovesItOnce() {
    let uploads = InMemoryUploadedIconStore()

    uploads.record("9039")
    uploads.record("9039")

    #expect(uploads.uploadedIcons() == ["9039"])
}

// One stale name the device answers 404 for must not block the icons behind it.
// Stopping at the first refusal blocks them permanently, not just this time:
// the refused name stays in the record and is met again next attempt, in the
// same position, for ever.
@Test func oneRefusalDoesNotBlockTheIconsBehindIt() async {
    let transport = RefusingTransport(refusing: "/ICONS/9039.gif")
    let uploads = InMemoryUploadedIconStore()
    uploads.record("9039")
    uploads.record("1234")
    let subject = CatalogueIconInstaller(
        device: AwtrixDevice(host: "10.0.0.5", transport: transport),
        transport: transport,
        uploads: uploads
    )

    await #expect(throws: CatalogueIconInstaller.Failure.notRemoved(["9039"])) {
        _ = try await subject.removeUploaded()
    }

    // The one behind it came off, and only the refusal is still recorded.
    #expect(uploads.uploadedIcons() == ["9039"])
    #expect(transport.deletedPaths.contains("/ICONS/1234.gif"))
}

/// Refuses to delete one named path and accepts everything else.
private final class RefusingTransport: Transport, @unchecked Sendable {
    private let refusing: String
    private let lock = NSLock()
    private var deleted: [String] = []

    init(refusing: String) { self.refusing = refusing }

    var deletedPaths: [String] { lock.withLock { deleted } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let refused = body.contains(refusing)
        if !refused, request.httpMethod == "DELETE" {
            lock.withLock {
                deleted.append(body.contains("/ICONS/1234.gif") ? "/ICONS/1234.gif" : body)
            }
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: refused ? 500 : 200, httpVersion: nil, headerFields: nil
        )!
        return (Data("OK".utf8), response)
    }
}

// MARK: - Concurrent records

// The durable store reads, modifies and writes, which `UserDefaults` does not
// make atomic. Two installs finishing at once lose one of the two records — an
// icon left on the flash that nothing in this app can ever name again.
//
// Sixteen concurrent records rather than two, because a lost update is a window
// rather than a certainty. Sixteen and not two hundred: measured across five
// runs each, an unlocked store keeps 2 of 16 and 22 of 200, so the smaller
// burst is just as decisive — and two hundred tasks saturate the cooperative
// pool hard enough to push `theProducersPacingIsObeyedPerClipNotAveraged`, a
// timing test three files away, past its 70 ms budget in 6 runs out of 8. A
// test that makes another one flaky is not a test, whatever it proves.
@Test func concurrentRecordsAreNeverLost() async throws {
    let suite = "uploaded-icons-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsUploadedIconStore(defaults: defaults)

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<16 {
            group.addTask { store.record("icon-\(index)") }
        }
    }

    #expect(store.uploadedIcons().count == 16)
}

// And the same through two instances over one domain, which is what the app
// would have if the model and the host each built their own installer. The lock
// guards the key, not the object, so this has to hold too — with a per-instance
// lock it loses records at the same rate as no lock at all.
@Test func concurrentRecordsThroughTwoInstancesAreNeverLostEither() async throws {
    let suite = "uploaded-icons-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = UserDefaultsUploadedIconStore(defaults: defaults)
    let second = UserDefaultsUploadedIconStore(defaults: defaults)

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<16 {
            let store = index.isMultiple(of: 2) ? first : second
            group.addTask { store.record("icon-\(index)") }
        }
    }

    #expect(first.uploadedIcons().count == 16)
}

// MARK: - Listing the flash once rather than once per delivery

/// The `/list` calls that reached the clock, in order. Everything below is
/// bought in exactly this number, so it is what the assertions count.
private func listings(_ transport: RoutingTransport) -> [URLRequest] {
    transport.requests.filter { $0.url?.path == "/list" }
}

// The weather draws an icon on every poll — 900 seconds by default — and the
// anecdotes draw one on every telling. Asking the clock which files it holds,
// to answer a question this process already answered, is a request per delivery
// for a fact that cannot have changed underneath it: while this app runs, it is
// the only thing writing to `/ICONS`. Fewer requests to the clock is the whole
// point of this wave of work, so an icon that costs one on every delivery is
// moving backwards.
@Test func anIconConfirmedOnceIsNotLookedForAgain() async throws {
    let transport = RoutingTransport([
        iconDirectory(holding: "9039.gif"),
        Route(match: "icon_thumbs/9039.gif", status: 200, body: gifBytes),
    ])
    let subject = installer(transport)

    _ = try await subject.ensureInstalled(.catalogue(9039))
    _ = try await subject.ensureInstalled(.catalogue(9039))

    #expect(listings(transport).count == 1)
    #expect(uploads(transport).isEmpty)
}

// The other way onto the flash, and the one the fake device cannot fake: it
// does not keep what is uploaded, so a second listing would answer "empty" and
// the icon would be downloaded and written again. One listing, one download,
// one upload.
@Test func anIconThisAppJustUploadedIsNotLookedForEither() async throws {
    let transport = RoutingTransport([
        emptyIconDirectory,
        Route(match: "icon_thumbs/9039.gif", status: 200, body: gifBytes),
    ])
    let subject = installer(transport)

    _ = try await subject.ensureInstalled(.catalogue(9039))
    _ = try await subject.ensureInstalled(.catalogue(9039))

    #expect(listings(transport).count == 1)
    #expect(uploads(transport).count == 1)
    #expect(catalogueFetches(transport).count == 1)
}

// Confirmed by name, not "we have listed once". A blanket flag would answer for
// an icon the listing never mentioned — the anecdote face on a clock that only
// ever showed the weather — and skip straight to an upload it cannot know is
// needed, or worse, to a name that is not there.
@Test func anIconThatWasNeverConfirmedIsStillLookedFor() async throws {
    let transport = RoutingTransport([
        iconDirectory(holding: "9039.gif", "2282.gif"),
        Route(match: "icon_thumbs/2282.gif", status: 200, body: gifBytes),
    ])
    let subject = installer(transport)

    _ = try await subject.ensureInstalled(.catalogue(9039))
    _ = try await subject.ensureInstalled(.catalogue(2282))

    #expect(listings(transport).count == 2)
}

// An upload the device refused leaves nothing on the flash, so there is nothing
// to remember. Remembering it anyway is how an app ends up icon-less for the
// rest of the launch: every later delivery would skip both the listing and the
// upload, and nothing ever revisits an icon believed to be there.
@Test func anUploadTheDeviceRefusedIsNotRememberedAsPresent() async throws {
    let transport = RoutingTransport([
        emptyIconDirectory,
        Route(match: "icon_thumbs/9039.gif", status: 200, body: gifBytes),
        Route(match: "/edit", status: 500, body: Data("boom".utf8)),
    ])
    let subject = installer(transport)

    await #expect(throws: AwtrixError.self) {
        _ = try await subject.ensureInstalled(.catalogue(9039))
    }
    await #expect(throws: AwtrixError.self) {
        _ = try await subject.ensureInstalled(.catalogue(9039))
    }

    // Listed both times, and tried both times. Nothing was confirmed, so
    // nothing may be skipped.
    #expect(listings(transport).count == 2)
    #expect(uploads(transport).count == 2)
}

// "Remove icons" takes the file back off the flash. A memory that outlived the
// file would skip the listing and skip the upload on the next weather poll, and
// the app would draw nothing at all until the next launch — with the record
// saying the icon is there and the clock disagreeing.
@Test func aRemovedIconIsForgottenSoTheNextDeliveryPutsItBack() async throws {
    let transport = RoutingTransport([
        emptyIconDirectory,
        Route(match: "icon_thumbs/9039.gif", status: 200, body: gifBytes),
    ])
    let subject = installer(transport)

    _ = try await subject.ensureInstalled(.catalogue(9039))
    _ = try await subject.removeUploaded()
    _ = try await subject.ensureInstalled(.catalogue(9039))

    #expect(uploads(transport).count == 2)
    #expect(listings(transport).count == 2)
}
