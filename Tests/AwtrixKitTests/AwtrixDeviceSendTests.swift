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
