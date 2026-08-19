import Foundation
import Testing
@testable import AwtrixKit

/// Records what was sent and replays a canned response.
///
/// Shared by several test files, so the recorded state is lock-guarded: a test
/// that drives one recorder from two devices or a `TaskGroup` would otherwise
/// race on `append`.
///
/// `@unchecked` is not a waiver here — every access below goes through `lock`.
/// Swift rejects a plain `Sendable` conformance on any class with mutable
/// stored properties, however they are synchronized ("stored property
/// 'recorded' of 'Sendable'-conforming class 'RecordingTransport' is
/// mutable"). Holding the state in a `let Mutex` would satisfy the checker, but
/// `Mutex` is macOS 15+ and this package floors at macOS 14.
final class RecordingTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var cannedStatus = 200
    private var cannedBody = Data("OK".utf8)

    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    var status: Int {
        get { lock.withLock { cannedStatus } }
        set { lock.withLock { cannedStatus = newValue } }
    }

    var body: Data {
        get { lock.withLock { cannedBody } }
        set { lock.withLock { cannedBody = newValue } }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // One acquisition, released before the response is built — never held
        // across a suspension point.
        let (status, body) = lock.withLock { () -> (Int, Data) in
            recorded.append(request)
            return (cannedStatus, cannedBody)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (body, response)
    }
}

private func decodeBody(_ request: URLRequest) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
}

@Test func notifyPostsTextToTheNotifyEndpoint() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    try await device.notify(NotifyPayload(text: "ВНИМАНИЕ, АНЕКДОТ"))

    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "http://10.0.0.5/api/notify")
    #expect(request.httpMethod == "POST")
    let body = try decodeBody(request)
    #expect(body["text"] as? String == "ВНИМАНИЕ, АНЕКДОТ")
}

@Test func notifyOmitsUnsetFieldsEntirely() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    try await device.notify(NotifyPayload(text: "hi", duration: 12))

    let body = try decodeBody(try #require(transport.requests.first))
    #expect(body["duration"] as? Int == 12)
    #expect(body["icon"] == nil)
    #expect(body["rtttl"] == nil)
    #expect(body.keys.count == 2)
}

@Test func notifyUsesTheApiFieldNamesNotTheSwiftOnes() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    try await device.notify(NotifyPayload(text: "hi", repeatCount: 2, scrollSpeed: 80, pushIcon: 2))

    let body = try decodeBody(try #require(transport.requests.first))
    #expect(body["repeat"] as? Int == 2)
    #expect(body["scrollSpeed"] as? Int == 80)
    #expect(body["pushIcon"] as? Int == 2)
}

@Test func playRTTTLPostsRawTextNotJSON() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    try await device.playRTTTL("nokia:d=4,o=5,b=225:8e6,8d6")

    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "http://10.0.0.5/api/rtttl")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/plain")
    #expect(String(decoding: request.httpBody!, as: UTF8.self) == "nokia:d=4,o=5,b=225:8e6,8d6")
}

@Test func playMelodyReferencesTheNameWithoutExtension() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    try await device.playMelody(named: "nokia")

    let body = try decodeBody(try #require(transport.requests.first))
    #expect(body["sound"] as? String == "nokia")
}

@Test func nonSuccessStatusSurfacesEndpointAndBody() async throws {
    let transport = RecordingTransport()
    transport.status = 404
    transport.body = Data("FileNotFound".utf8)
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    do {
        try await device.playMelody(named: "missing")
        Issue.record("expected a failure for a 404 response")
    } catch let AwtrixError.http(status, body, endpoint) {
        #expect(status == 404)
        #expect(body == "FileNotFound")
        #expect(endpoint == "/api/sound")
    }
}

@Test func anUnusableHostThrowsInsteadOfTrapping() async {
    let device = AwtrixDevice(host: "not a host", transport: RecordingTransport())

    await #expect(throws: AwtrixError.self) {
        try await device.stats()
    }
}

@Test func statsDecodesTheDeviceReport() async throws {
    let transport = RecordingTransport()
    transport.body = Data(#"{"bat":83,"ram":139112,"version":"0.98","uid":"awtrix_a07f9c","ip_address":"192.168.1.72"}"#.utf8)
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    let stats = try await device.stats()

    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "http://10.0.0.5/api/stats")
    #expect(stats.version == "0.98")
    #expect(stats.uid == "awtrix_a07f9c")
    #expect(stats.bat == 83)
    #expect(stats.ipAddress == "192.168.1.72")
}

@Test func anAwtrixErrorLocalisesToItsOwnDescription() {
    // `DeviceState.offline` carries `localizedDescription`, which for an Error
    // with no LocalizedError conformance is "The operation couldn't be
    // completed. (AwtrixKit.AwtrixError error 0.)" — the endpoint, status and
    // body all gone. The conformance routes it to `description` rather than
    // repeating the text, so this asserts the two agree.
    let failed = AwtrixError.http(status: 500, body: "boom", endpoint: "/api/stats")

    #expect(failed.localizedDescription == "/api/stats -> HTTP 500: boom")
    #expect(failed.localizedDescription == failed.description)
    #expect(AwtrixError.invalidHost("not a host").localizedDescription
        == "invalid device host: not a host")
}

// MARK: - The app in the loop

// A custom app stays in the clock's loop until something takes it out, and a
// clean quit is the only ending that does one. A crash, a force quit, the Mac
// going to sleep or the wifi dropping all leave the last reading on the matrix
// for good — yesterday's temperature shown as today's, with nothing on screen
// to say it is stale. A lifetime is the firmware removing it on this app's
// behalf once the updates stop arriving.
@Test func anAppWithALifetimeSendsItToTheFirmware() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    try await device.showApp(AppPayload(text: "4°", lifetime: 3_600), named: "weather")

    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "http://10.0.0.5/api/custom?name=weather")
    #expect(try decodeBody(request)["lifetime"] as? Int == 3_600)
}

// Unset is an absent key rather than a null, as every other optional field on
// both payloads already is — the firmware rejects nulls.
@Test func anAppWithoutALifetimeOmitsTheKeyEntirely() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    try await device.showApp(AppPayload(text: "4°", icon: "2289"), named: "weather")

    let body = try decodeBody(try #require(transport.requests.first))
    #expect(body["lifetime"] == nil)
    #expect(body.keys.count == 2)
}

// MARK: - What a typed address is aimed at

// Pasting the address out of the clock's own web interface is the single most
// likely thing anybody does with the field, and the result was a request to a
// host literally named `http`: every URL is built as `http://<host><path>`, so
// `http://10.0.0.5` produced `http://http://10.0.0.5/api/stats`. What reached
// the user was a DNS error in the offline reason and nothing suggesting the
// address was malformed.
@Test func aPastedSchemeIsNotPartOfTheHost() {
    #expect(DeviceAddress.host(from: "http://10.0.0.5") == "10.0.0.5")
    #expect(DeviceAddress.host(from: "https://10.0.0.5") == "10.0.0.5")
    // Whatever its case: an address bar is lowercase, a clipboard is whatever
    // was in the document it came from.
    #expect(DeviceAddress.host(from: "HTTP://10.0.0.5") == "10.0.0.5")
    #expect(DeviceAddress.host(from: "HtTpS://awtrix.local") == "awtrix.local")
}

// The browser shows `http://10.0.0.5/`, and that slash left in place puts a
// double one in every URL this app builds.
@Test func everythingFromTheFirstSlashOnIsAPathRatherThanAHost() {
    #expect(DeviceAddress.host(from: "http://10.0.0.5/") == "10.0.0.5")
    #expect(DeviceAddress.host(from: "http://10.0.0.5/api/stats") == "10.0.0.5")
    #expect(DeviceAddress.host(from: "10.0.0.5/") == "10.0.0.5")
}

// A port is part of the address and stays. It is what somebody running the
// firmware behind a forward has to type.
@Test func aPortSurvivesNormalisationBecauseItIsPartOfTheAddress() {
    #expect(DeviceAddress.host(from: "http://10.0.0.5:8080") == "10.0.0.5:8080")
    #expect(DeviceAddress.host(from: "10.0.0.5:8080") == "10.0.0.5:8080")
}

// An ordinary address is returned exactly as it stands, or the normalisation is
// doing something to the case this app is actually pointed at.
@Test func anOrdinaryAddressIsLeftAlone() {
    #expect(DeviceAddress.host(from: "192.168.1.72") == "192.168.1.72")
    #expect(DeviceAddress.host(from: "  192.168.1.72\n ") == "192.168.1.72")
    #expect(DeviceAddress.host(from: "awtrix.local") == "awtrix.local")
}

// And what cannot be made into a host is refused rather than guessed at.
@Test func anEntryWithNoHostLeftInItIsRefused() {
    #expect(DeviceAddress.host(from: "http://") == nil)
    #expect(DeviceAddress.host(from: "/") == nil)
    #expect(DeviceAddress.host(from: "   ") == nil)
    // A space cannot be in a host. `URL(string:)` answers nil for one, so
    // accepting it here only moves the complaint to the next poll.
    #expect(DeviceAddress.host(from: "a b") == nil)
}

// End to end, through the device that builds the URL: the request goes to the
// clock rather than to a host named after a scheme. Not asserted on the
// normaliser alone, because the defect was the two of them together.
@Test func aDeviceBuiltFromAPastedAddressAsksTheClockItself() async throws {
    let transport = RecordingTransport()
    transport.body = Data(#"{"version":"0.96","uid":"a","bat":50,"ram":1,"ip_address":"10.0.0.5"}"#.utf8)
    let device = AwtrixDevice(host: "http://10.0.0.5/", transport: transport)

    _ = try await device.stats()

    #expect(transport.requests.first?.url?.host == "10.0.0.5")
    #expect(transport.requests.first?.url?.absoluteString == "http://10.0.0.5/api/stats")
}

// An address nothing can be made of is kept as it stands rather than replaced
// with something plausible, so the error names what the user actually entered.
@Test func anUnusableAddressIsStillReportedByName() async {
    let device = AwtrixDevice(host: "a b", transport: RecordingTransport())

    do {
        _ = try await device.stats()
        Issue.record("expected the address to be refused")
    } catch let AwtrixError.invalidHost(named) {
        // The user's own entry, verbatim. Substituting something plausible in
        // the initialiser would leave this naming an address nobody typed.
        #expect(named == "a b")
    } catch {
        Issue.record("expected .invalidHost, got \(error)")
    }
}
