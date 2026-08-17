import Foundation

public struct RemoteFile: Sendable, Equatable {
    public let name: String
    public let size: Int
    public let isDirectory: Bool

    public init(name: String, size: Int, isDirectory: Bool) {
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
    }
}

private struct ListingEntry: Decodable {
    let type: String
    let size: String
    let name: String
}

extension AwtrixDevice {
    public func list(_ path: String = "/") async throws -> [RemoteFile] {
        let data = try await perform("GET", "/list?dir=\(path)")
        let entries = try JSONDecoder().decode([ListingEntry].self, from: data)
        return entries.map {
            RemoteFile(name: $0.name, size: Int($0.size) ?? 0, isDirectory: $0.type == "dir")
        }
    }

    /// The destination path travels in the multipart *filename*, which is how the
    /// device's editor endpoint decides where the bytes land.
    public func upload(_ blob: Data, to remotePath: String) async throws {
        let boundary = UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(remotePath)\"\r\n".utf8
        ))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(blob)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        _ = try await perform(
            "POST", "/edit", body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    public func delete(_ remotePath: String) async throws {
        let boundary = UUID().uuidString
        let body = Data("""
        --\(boundary)\r
        Content-Disposition: form-data; name="path"\r
        \r
        \(remotePath)\r
        --\(boundary)--\r

        """.utf8)
        _ = try await perform(
            "DELETE", "/edit", body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    public func installIcon(_ blob: Data, named name: String) async throws {
        try await upload(blob, to: "/ICONS/\(name).gif")
    }

    public func removeIcon(named name: String) async throws {
        try await delete("/ICONS/\(name).gif")
    }

    /// Melodies are RTTTL text; the play key is the basename without extension.
    public func installMelody(_ rtttl: String, named name: String) async throws {
        try await upload(Data(rtttl.utf8), to: "/MELODIES/\(name).txt")
    }

    public func removeMelody(named name: String) async throws {
        try await delete("/MELODIES/\(name).txt")
    }
}
