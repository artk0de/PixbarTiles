import Foundation
import Testing
@testable import AwtrixKit

/// Records what was sent and replays a canned response.
final class RecordingTransport: Transport, @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    var status = 200
    var body = Data("OK".utf8)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
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

    await #expect(throws: AwtrixError.self) {
        try await device.playMelody(named: "missing")
    }
}

@Test func statsDecodesTheDeviceReport() async throws {
    let transport = RecordingTransport()
    transport.body = Data(#"{"bat":83,"ram":139112,"version":"0.98","uid":"awtrix_a07f9c","ip_address":"192.168.1.72"}"#.utf8)
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    let stats = try await device.stats()

    #expect(stats.version == "0.98")
    #expect(stats.uid == "awtrix_a07f9c")
    #expect(stats.bat == 83)
    #expect(stats.ipAddress == "192.168.1.72")
}
