import Foundation
import Testing
@testable import AwtrixKit

private func bodyString(_ request: URLRequest) -> String {
    String(decoding: request.httpBody ?? Data(), as: UTF8.self)
}

@Test func listParsesTheDirectoryReport() async throws {
    let transport = RecordingTransport()
    transport.body = Data(#"[{"type":"dir","size":"0","name":"ICONS"},{"type":"file","size":"131","name":"777.gif"}]"#.utf8)
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    let files = try await device.list("/")

    #expect(files == [
        RemoteFile(name: "ICONS", size: 0, isDirectory: true),
        RemoteFile(name: "777.gif", size: 131, isDirectory: false),
    ])
    #expect(transport.requests.first?.url?.absoluteString == "http://10.0.0.5/list?dir=/")
}

@Test func uploadSendsMultipartWithDestinationInFilename() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    try await device.upload(Data("GIF89a".utf8), to: "/ICONS/9039.gif")

    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "http://10.0.0.5/edit")
    #expect(request.httpMethod == "POST")
    let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
    #expect(contentType.hasPrefix("multipart/form-data; boundary="))
    let body = bodyString(request)
    #expect(body.contains(#"name="file"; filename="/ICONS/9039.gif""#))
    #expect(body.contains("GIF89a"))
}

@Test func deleteSendsThePathAsAFormField() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    try await device.delete("/MELODIES/nokia.txt")

    let request = try #require(transport.requests.first)
    #expect(request.httpMethod == "DELETE")
    let body = bodyString(request)
    #expect(body.contains(#"name="path""#))
    #expect(body.contains("/MELODIES/nokia.txt"))
}

@Test func installMelodyWritesRtttlAsATextFile() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    try await device.installMelody("nokia:d=4,o=5,b=225:8e6", named: "nokia")

    let body = bodyString(try #require(transport.requests.first))
    #expect(body.contains(#"filename="/MELODIES/nokia.txt""#))
    #expect(body.contains("nokia:d=4,o=5,b=225:8e6"))
}

@Test func installIconWritesAGifUnderIcons() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    try await device.installIcon(Data("GIF89a".utf8), named: "laugh")

    let body = bodyString(try #require(transport.requests.first))
    #expect(body.contains(#"filename="/ICONS/laugh.gif""#))
}
