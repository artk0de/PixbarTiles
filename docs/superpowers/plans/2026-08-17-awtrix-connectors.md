# AWTRIX Connectors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu bar app that runs pluggable connectors and pushes their output to a Ulanzi TC001 running AWTRIX 3, shipping with an anecdote connector that voices dialogue with cloned character voices.

**Architecture:** One SwiftPM package. `AwtrixKit` is a library holding every piece of logic and is the only thing under test; `AwtrixConnectorsApp` is a thin SwiftUI executable that owns the menu bar surface and nothing else. Connectors are types conforming to a protocol and registered in a registry — the plugin boundary is a protocol, not a process. HTTP goes through an injected `Transport`, so device behaviour is testable without hardware.

**Tech Stack:** Swift 6.3.3, SwiftPM (no Xcode project), SwiftUI `MenuBarExtra`, `swift-testing`, `AVFoundation` for local playback, a Python sidecar for speech synthesis.

**Spec:** `docs/superpowers/specs/2026-08-17-awtrix-connectors-design.md`

**Reference implementation:** `prototype/awtrix/client.py` is the working, hardware-verified version of the device client. When Task 2 or Task 3 is ambiguous, read it — it is stdlib-only precisely so it maps onto Foundation.

## Global Constraints

- Swift tools version `6.0`, platform floor `.macOS(.v14)`. Verified: `swift build` of a `MenuBarExtra` executable target succeeds on Swift 6.3.3 in 6.6s with no Xcode project.
- Swift 6 strict concurrency is on. Types crossing an actor boundary are `Sendable`.
- Do not name the executable's entry file `main.swift`. A file with that name is top-level code and conflicts with `@main`. Use `App.swift`.
- Device under development: `192.168.1.72`, AWTRIX `0.98`, `type: 0` (stock Ulanzi TC001). Never hardcode the address outside test fixtures and the default in settings.
- The clock cannot decode audio. Speech plays on the Mac. The device receives text, an icon, and RTTTL only. Do not add an "upload the WAV" path — it was measured and it does not work.
- Cyrillic renders on the device font as-is. Do not transliterate, do not strip diacritics.
- Anything the app writes to device flash must be namespaced and removable, and the app removes what it created.
- All source comments, identifiers, commit messages and documentation are English.
- No third-party dependencies. Foundation and SwiftUI only.

---

### Task 1: Package skeleton

**Files:**
- Create: `Package.swift`
- Create: `Sources/AwtrixKit/AwtrixKit.swift`
- Test: `Tests/AwtrixKitTests/PackageSmokeTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: the `AwtrixKit` library target that every later task adds to, and a green `swift test` baseline

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AwtrixKitTests/PackageSmokeTests.swift
import Testing
@testable import AwtrixKit

@Test func packageExposesItsVersion() {
    #expect(AwtrixKit.version == "0.1.0")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test`
Expected: FAIL — no such module `AwtrixKit`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AwtrixConnectors",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AwtrixKit"),
        .testTarget(name: "AwtrixKitTests", dependencies: ["AwtrixKit"]),
    ]
)
```

```swift
// Sources/AwtrixKit/AwtrixKit.swift
/// Namespace for package-level constants.
public enum AwtrixKit {
    public static let version = "0.1.0"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS, 1 test.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "feat: AwtrixKit package skeleton"
```

---

### Task 2: Transport and the sending half of the device client

**Files:**
- Create: `Sources/AwtrixKit/Device/Transport.swift`
- Create: `Sources/AwtrixKit/Device/AwtrixDevice.swift`
- Create: `Sources/AwtrixKit/Device/AwtrixError.swift`
- Test: `Tests/AwtrixKitTests/AwtrixDeviceSendTests.swift`

**Interfaces:**
- Consumes: Task 1's `AwtrixKit` target
- Produces:
  - `protocol Transport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }`
  - `actor AwtrixDevice` with `init(host: String, transport: Transport)`
  - `func notify(_ payload: NotifyPayload) async throws`
  - `func playRTTTL(_ melody: String) async throws`
  - `func playMelody(named name: String) async throws`
  - `func stats() async throws -> DeviceStats`
  - `struct NotifyPayload: Sendable` with `text`, `icon`, `duration`, `color`, `rtttl`, `sound`, `repeatCount`, `scrollSpeed`, `stack`, `wakeup`, `hold`, `pushIcon` — all optional except `text`
  - `struct DeviceStats: Sendable, Decodable` with `version`, `uid`, `bat`, `ram`, `ipAddress`
  - `enum AwtrixError: Error, Sendable { case http(status: Int, body: String, endpoint: String) }`

Why an injected `Transport` rather than `URLSession` directly: every test below runs with no hardware and no network, and asserts on the exact request that would have gone out. Verifying the JSON body is the whole point — a payload with a `null` field is rejected by the firmware.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AwtrixKitTests/AwtrixDeviceSendTests.swift
import Foundation
import Testing
@testable import AwtrixKit

/// Records what was sent and replays a canned response.
///
/// Shared by several test files, so the recorded state is lock-guarded: a test
/// that drives one recorder from two devices or a `TaskGroup` would otherwise
/// race on `append`. Measured, not assumed — a 200-way TaskGroup probe under
/// ThreadSanitizer loses an append (199 of 200) without the lock.
///
/// `@unchecked` is not a waiver here — every access below goes through `lock`.
/// Swift rejects a plain `Sendable` conformance on any class with mutable
/// stored properties, however they are synchronized. Holding the state in a
/// `let Mutex` would satisfy the checker, but `Mutex` is macOS 15+ and this
/// package floors at macOS 14.
///
/// It stays a class with a synchronous property API on purpose: an actor would
/// force `await` on every access, and Task 10 builds its fixture in a
/// synchronous helper.
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

    // Asserting only the error TYPE would pass against an empty
    // .http(0, "", "") — the payload is the whole point of the case.
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

    #expect(stats.version == "0.98")
    #expect(stats.uid == "awtrix_a07f9c")
    #expect(stats.bat == 83)
    #expect(stats.ipAddress == "192.168.1.72")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AwtrixDeviceSendTests`
Expected: FAIL — `Transport`, `AwtrixDevice`, `NotifyPayload`, `DeviceStats`, `AwtrixError` are undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AwtrixKit/Device/Transport.swift
import Foundation

/// Everything that reaches the device goes through here, so tests can observe it.
public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: Transport {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
```

```swift
// Sources/AwtrixKit/Device/AwtrixError.swift
import Foundation

public enum AwtrixError: Error, Sendable {
    case http(status: Int, body: String, endpoint: String)
    /// The configured host cannot form a URL. The address is user-typable from
    /// Task 14 on, so this must be an error, never a trap.
    case invalidHost(String)
}

extension AwtrixError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .http(status, body, endpoint):
            return "\(endpoint) -> HTTP \(status): \(body)"
        case let .invalidHost(host):
            return "invalid device host: \(host)"
        }
    }
}
```

```swift
// Sources/AwtrixKit/Device/AwtrixDevice.swift
import Foundation

/// One device's HTTP surface. Field names below are the firmware's, not Swift's.
public struct NotifyPayload: Sendable {
    public var text: String
    public var icon: String?
    public var duration: Int?
    public var color: String?
    public var rtttl: String?
    public var sound: String?
    public var repeatCount: Int?
    public var scrollSpeed: Int?
    public var stack: Bool?
    public var wakeup: Bool?
    public var hold: Bool?
    public var pushIcon: Int?

    public init(
        text: String,
        icon: String? = nil,
        duration: Int? = nil,
        color: String? = nil,
        rtttl: String? = nil,
        sound: String? = nil,
        repeatCount: Int? = nil,
        scrollSpeed: Int? = nil,
        stack: Bool? = nil,
        wakeup: Bool? = nil,
        hold: Bool? = nil,
        pushIcon: Int? = nil
    ) {
        self.text = text
        self.icon = icon
        self.duration = duration
        self.color = color
        self.rtttl = rtttl
        self.sound = sound
        self.repeatCount = repeatCount
        self.scrollSpeed = scrollSpeed
        self.stack = stack
        self.wakeup = wakeup
        self.hold = hold
        self.pushIcon = pushIcon
    }

    /// Only set fields are emitted — the firmware rejects nulls.
    var jsonObject: [String: Any] {
        var object: [String: Any] = ["text": text]
        if let icon { object["icon"] = icon }
        if let duration { object["duration"] = duration }
        if let color { object["color"] = color }
        if let rtttl { object["rtttl"] = rtttl }
        if let sound { object["sound"] = sound }
        if let repeatCount { object["repeat"] = repeatCount }
        if let scrollSpeed { object["scrollSpeed"] = scrollSpeed }
        if let stack { object["stack"] = stack }
        if let wakeup { object["wakeup"] = wakeup }
        if let hold { object["hold"] = hold }
        if let pushIcon { object["pushIcon"] = pushIcon }
        return object
    }
}

public struct DeviceStats: Sendable, Decodable {
    public let version: String
    public let uid: String
    public let bat: Int
    public let ram: Int
    public let ipAddress: String

    private enum CodingKeys: String, CodingKey {
        case version, uid, bat, ram
        case ipAddress = "ip_address"
    }
}

public actor AwtrixDevice {
    private let host: String
    private let transport: Transport

    public init(host: String, transport: Transport) {
        self.host = host
        self.transport = transport
    }

    // MARK: sending

    public func notify(_ payload: NotifyPayload) async throws {
        _ = try await postJSON("/api/notify", payload.jsonObject)
    }

    public func dismissNotification() async throws {
        _ = try await postJSON("/api/notify/dismiss", [:])
    }

    public func playRTTTL(_ melody: String) async throws {
        _ = try await perform("POST", "/api/rtttl", body: Data(melody.utf8), contentType: "text/plain")
    }

    public func playMelody(named name: String) async throws {
        _ = try await postJSON("/api/sound", ["sound": name])
    }

    public func stats() async throws -> DeviceStats {
        let data = try await perform("GET", "/api/stats")
        return try JSONDecoder().decode(DeviceStats.self, from: data)
    }

    // MARK: transport plumbing

    func postJSON(_ path: String, _ object: [String: Any]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object)
        return try await perform("POST", path, body: body, contentType: "application/json")
    }

    func perform(
        _ method: String,
        _ path: String,
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        // Never force-unwrap: the host is user-typed from Task 14 on, and a
        // trap in a background menu bar process makes the app vanish silently.
        guard let url = URL(string: "http://\(host)\(path)") else {
            throw AwtrixError.invalidHost(host)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw AwtrixError.http(
                status: response.statusCode,
                body: String(decoding: data, as: UTF8.self),
                endpoint: path
            )
        }
        return data
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AwtrixDeviceSendTests`
Expected: PASS, 8 tests.

Note for later tasks: `AwtrixError` now has two cases, so any exhaustive `switch`
over it must handle `.invalidHost` — most relevant in Task 14, where the host
becomes user-typable.

- [ ] **Step 5: Commit**

```bash
git add Sources/AwtrixKit/Device Tests/AwtrixKitTests/AwtrixDeviceSendTests.swift
git commit -m "feat: AwtrixDevice sending surface over an injected transport"
```

---

### Task 3: Device flash — files, icons, melodies

**Files:**
- Create: `Sources/AwtrixKit/Device/AwtrixDevice+Flash.swift`
- Test: `Tests/AwtrixKitTests/AwtrixDeviceFlashTests.swift`

**Interfaces:**
- Consumes: Task 2's `AwtrixDevice`, `AwtrixError`
- Produces:
  - `struct RemoteFile: Sendable, Equatable { let name: String; let size: Int; let isDirectory: Bool }`
  - `func list(_ path: String) async throws -> [RemoteFile]`
  - `func upload(_ blob: Data, to remotePath: String) async throws`
  - `func delete(_ remotePath: String) async throws`
  - `func installIcon(_ blob: Data, named name: String) async throws` — writes `/ICONS/<name>.gif`
  - `func installMelody(_ rtttl: String, named name: String) async throws` — writes `/MELODIES/<name>.txt`
  - `func removeIcon(named name: String) async throws`
  - `func removeMelody(named name: String) async throws`

Measured facts this task encodes, both from `prototype/`: the melody folder holds RTTTL **text** files and the play key is the basename without extension; upload is a multipart POST to `/edit` where the *filename* field carries the full destination path; delete is a multipart DELETE to `/edit` with a `path` field.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AwtrixKitTests/AwtrixDeviceFlashTests.swift
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
    // Exact bytes, not `contains`: a close delimiter that degrades to a bare CR
    // is invisible to a substring assertion.
    let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
    let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
    let expected =
        "--\(boundary)\r\n"
        + "Content-Disposition: form-data; name=\"path\"\r\n"
        + "\r\n"
        + "/MELODIES/nokia.txt\r\n"
        + "--\(boundary)--\r\n"
    #expect(String(decoding: try #require(request.httpBody), as: UTF8.self) == expected)
}

@Test func removeIconTargetsTheGifUnderIcons() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    try await device.removeIcon(named: "laugh")

    let request = try #require(transport.requests.first)
    #expect(request.httpMethod == "DELETE")
    #expect(bodyString(request).contains("/ICONS/laugh.gif"))
}

@Test func removeMelodyTargetsTheTextFileUnderMelodies() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    try await device.removeMelody(named: "nokia")

    let request = try #require(transport.requests.first)
    #expect(request.httpMethod == "DELETE")
    // The .txt is the contract, not a detail: the firmware resolves melodies as
    // RTTTL text, and a .mp3 in that folder is invisible to the sound path.
    #expect(bodyString(request).contains("/MELODIES/nokia.txt"))
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AwtrixDeviceFlashTests`
Expected: FAIL — `RemoteFile` and the flash methods are undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AwtrixKit/Device/AwtrixDevice+Flash.swift
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

    /// Built by explicit append, like `upload` above. A multiline literal works
    /// too, but its closing delimiter depends on a blank line that reads as
    /// stray formatting — delete that line and the body degrades to a bare CR
    /// while every `contains` assertion stays green.
    public func delete(_ remotePath: String) async throws {
        let boundary = UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"path\"\r\n".utf8))
        body.append(Data("\r\n".utf8))
        body.append(Data("\(remotePath)\r\n".utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AwtrixDeviceFlashTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AwtrixKit/Device/AwtrixDevice+Flash.swift Tests/AwtrixKitTests/AwtrixDeviceFlashTests.swift
git commit -m "feat: device flash operations for files, icons and melodies"
```

---

### Task 4: Interval scale

**Files:**
- Create: `Sources/AwtrixKit/Scheduling/IntervalScale.swift`
- Test: `Tests/AwtrixKitTests/IntervalScaleTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `enum IntervalScale` with `static let positions: [TimeInterval]`
  - `static func duration(atPosition: Int) -> TimeInterval`
  - `static func position(for duration: TimeInterval) -> Int`
  - `static func label(atPosition: Int) -> String`

The slider is non-linear by requirement: 5-minute steps up to an hour, then 1-hour steps up to twelve. A linear slider over 5 minutes to 12 hours is unusable, so the UI binds to a **position index** and this type owns the mapping. Both the UI and the host need it, which is why it lands before either.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AwtrixKitTests/IntervalScaleTests.swift
import Foundation
import Testing
@testable import AwtrixKit

@Test func scaleHasTwentyThreePositions() {
    #expect(IntervalScale.positions.count == 23)
}

@Test func firstTwelvePositionsStepFiveMinutesToOneHour() {
    #expect(IntervalScale.duration(atPosition: 0) == 5 * 60)
    #expect(IntervalScale.duration(atPosition: 1) == 10 * 60)
    #expect(IntervalScale.duration(atPosition: 11) == 60 * 60)
}

@Test func remainingPositionsStepOneHourToTwelve() {
    #expect(IntervalScale.duration(atPosition: 12) == 2 * 3600)
    #expect(IntervalScale.duration(atPosition: 22) == 12 * 3600)
}

@Test func positionsAreStrictlyIncreasing() {
    let values = IntervalScale.positions
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
}

@Test func outOfRangePositionsClampInsteadOfCrashing() {
    #expect(IntervalScale.duration(atPosition: -5) == 5 * 60)
    #expect(IntervalScale.duration(atPosition: 999) == 12 * 3600)
}

@Test func positionForDurationSnapsToTheNearestStep() {
    #expect(IntervalScale.position(for: 5 * 60) == 0)
    #expect(IntervalScale.position(for: 8 * 60) == 1)      // nearer 10 than 5
    #expect(IntervalScale.position(for: 3 * 3600) == 13)
}

@Test func labelsReadAsMinutesThenHours() {
    #expect(IntervalScale.label(atPosition: 0) == "5 min")
    #expect(IntervalScale.label(atPosition: 11) == "1 h")
    #expect(IntervalScale.label(atPosition: 22) == "12 h")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter IntervalScaleTests`
Expected: FAIL — `IntervalScale` is undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AwtrixKit/Scheduling/IntervalScale.swift
import Foundation

/// Maps a slider position to a run interval.
///
/// The scale is deliberately non-linear: five-minute resolution is what matters
/// under an hour, and nobody needs it above one.
public enum IntervalScale {
    public static let positions: [TimeInterval] = {
        let minutes = stride(from: 5, through: 60, by: 5).map { TimeInterval($0 * 60) }
        let hours = stride(from: 2, through: 12, by: 1).map { TimeInterval($0 * 3600) }
        return minutes + hours
    }()

    public static func duration(atPosition position: Int) -> TimeInterval {
        positions[min(max(position, 0), positions.count - 1)]
    }

    public static func position(for duration: TimeInterval) -> Int {
        positions
            .enumerated()
            .min { abs($0.element - duration) < abs($1.element - duration) }?
            .offset ?? 0
    }

    public static func label(atPosition position: Int) -> String {
        let seconds = duration(atPosition: position)
        if seconds < 3600 {
            return "\(Int(seconds / 60)) min"
        }
        return "\(Int(seconds / 3600)) h"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter IntervalScaleTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AwtrixKit/Scheduling/IntervalScale.swift Tests/AwtrixKitTests/IntervalScaleTests.swift
git commit -m "feat: non-linear interval scale for the tray slider"
```

---

### Task 5: Dialogue parser

**Files:**
- Create: `Sources/AwtrixKit/Anecdotes/DialogueParser.swift`
- Test: `Tests/AwtrixKitTests/DialogueParserTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `struct Turn: Sendable, Equatable { let speaker: Speaker; let text: String }`
  - `enum Speaker: Sendable, Equatable, Hashable { case narrator; case actor(Int) }`
  - `enum DialogueParser { static func parse(_ text: String) -> [Turn] }`

This is the single most failure-prone piece in the project, so it gets real fixtures pulled from `anekdot.ru` rather than invented ones.

**The trap:** a dash marks a speaker turn only at the *start of a line*. Russian punctuation uses dashes mid-sentence constantly — a live sample reads `- Вот я - убеждённый жаворонок`, which is one turn containing a dash, not two turns. Splitting on any dash produces garbage.

Line separator in the source feed is the literal `<br>` tag; the source strips it to newlines before this parser sees the text.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AwtrixKitTests/DialogueParserTests.swift
import Testing
@testable import AwtrixKit

@Test func plainTextIsOneNarratorTurn() {
    let turns = DialogueParser.parse("Посмотрел \"Теремок\". Что вам сказать? Сказка короче...")

    #expect(turns == [Turn(speaker: .narrator, text: "Посмотрел \"Теремок\". Что вам сказать? Сказка короче...")])
}

@Test func twoDashedLinesAlternateBetweenTwoActors() {
    let turns = DialogueParser.parse("""
    - Ты у меня зонт забыла!
    - Это не зонт, это трость!
    """)

    #expect(turns == [
        Turn(speaker: .actor(0), text: "Ты у меня зонт забыла!"),
        Turn(speaker: .actor(1), text: "Это не зонт, это трость!"),
    ])
}

@Test func aDashInsideALineDoesNotStartANewTurn() {
    // Real sample: the second dash is punctuation, not a speaker marker.
    let turns = DialogueParser.parse("""
    - Вот я - убеждённый жаворонок. И после десяти вечера я не работаю!
    - Получается, будильник таки звонит...
    """)

    #expect(turns.count == 2)
    #expect(turns[0].text == "Вот я - убеждённый жаворонок. И после десяти вечера я не работаю!")
    #expect(turns[1].speaker == .actor(1))
}

@Test func leadingNarrationKeepsItsOwnTurnBeforeTheDialogue() {
    let turns = DialogueParser.parse("""
    Звонок от курьера:
    - Здравствуйте! Я подъехал...
    - Здравствуйте! Но я вас не вижу...
    - Такое бывает. Я у соседнего подъезда!
    """)

    #expect(turns.count == 4)
    #expect(turns[0] == Turn(speaker: .narrator, text: "Звонок от курьера:"))
    #expect(turns[1].speaker == .actor(0))
    #expect(turns[2].speaker == .actor(1))
    #expect(turns[3].speaker == .actor(0))
}

@Test func consecutiveDashedLinesAlternateBetweenTwoActors() {
    // Plain dashed lines carry no speaker identity, so alternation between two
    // is the honest reading. A third actor would need naming the parser cannot see.
    let turns = DialogueParser.parse("""
    - раз
    - два
    - три
    - четыре
    """)

    #expect(turns.map(\.speaker) == [.actor(0), .actor(1), .actor(0), .actor(1)])
}

@Test func emDashAndHyphenAreBothSpeakerMarkers() {
    let turns = DialogueParser.parse("""
    — Первый.
    - Второй.
    """)

    #expect(turns.map(\.speaker) == [.actor(0), .actor(1)])
    #expect(turns[0].text == "Первый.")
}

@Test func blankLinesAreDropped() {
    let turns = DialogueParser.parse("""
    Первая строка.

    Вторая строка.
    """)

    #expect(turns.count == 2)
}

@Test func emptyInputYieldsNoTurns() {
    #expect(DialogueParser.parse("   \n\n  ").isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DialogueParserTests`
Expected: FAIL — `DialogueParser`, `Turn`, `Speaker` are undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AwtrixKit/Anecdotes/DialogueParser.swift
import Foundation

public enum Speaker: Sendable, Equatable, Hashable {
    case narrator
    case actor(Int)
}

public struct Turn: Sendable, Equatable {
    public let speaker: Speaker
    public let text: String

    public init(speaker: Speaker, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

/// Splits an anecdote into speaker turns.
///
/// A dash opens a turn only at the start of a line. Russian prose uses dashes
/// mid-sentence freely, so splitting on any dash shreds ordinary text.
public enum DialogueParser {
    private static let speakerMarkers: Set<Character> = ["-", "—", "–"]

    public static func parse(_ text: String) -> [Turn] {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var turns: [Turn] = []
        var nextActor = 0

        for line in lines {
            guard let first = line.first, speakerMarkers.contains(first) else {
                turns.append(Turn(speaker: .narrator, text: line))
                continue
            }
            let body = line.dropFirst()
                .trimmingCharacters(in: .whitespaces)
            // A marker with nothing after it is a separator, not speech. Emitting
            // it would voice an empty string, and consuming a speaker slot would
            // flip who talks next — two people would merge into one voice, with
            // nothing failing to show it.
            guard !body.isEmpty else { continue }
            turns.append(Turn(speaker: .actor(nextActor), text: body))
            nextActor = (nextActor + 1) % 2
        }

        return turns
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DialogueParserTests`
Expected: PASS, 11 tests — the eight above plus three added during implementation:
a bare-marker line must not consume a speaker slot, CRLF input must not produce
empty entries, and a non-breaking space must be trimmed (both live risks for text
scraped out of an HTML feed).

- [ ] **Step 5: Commit**

```bash
git add Sources/AwtrixKit/Anecdotes/DialogueParser.swift Tests/AwtrixKitTests/DialogueParserTests.swift
git commit -m "feat: dialogue parser splitting anecdotes into speaker turns"
```

---

### Task 6: Voice caster

**Files:**
- Create: `Sources/AwtrixKit/Anecdotes/VoiceCaster.swift`
- Test: `Tests/AwtrixKitTests/VoiceCasterTests.swift`

**Interfaces:**
- Consumes: Task 5's `Turn`, `Speaker`
- Produces:
  - `struct Voice: Sendable, Equatable, Hashable { let id: String }` — the id is the voice name the synthesis sidecar resolves to `voices/<id>.wav`
  - `struct VoicedTurn: Sendable, Equatable { let voice: Voice; let text: String }`
  - `struct VoiceCaster: Sendable` with `init(narrator: Voice, pool: [Voice])` and `func cast(_ turns: [Turn]) -> [VoicedTurn]`
  - `static let arthas: Voice`, `static let peon: Voice`

Casting rules, straight from the requirement: narration is Arthas, the *second* speaking actor is Peon, further actors draw from the pool in first-appearance order. The laughter tail is always Arthas, and Task 8 appends it as a narrator turn, which is what makes that fall out for free.

**Pool size is coupled to parser capability.** When actors outnumber voices the pool wraps, so two characters share a voice with nothing to signal it. That is unreachable today — `DialogueParser` advances with `(nextActor + 1) % 2` and can only emit `.actor(0)` and `.actor(1)`, because a bare dash carries no speaker identity and a third speaker cannot be detected from the text. Anyone teaching the parser to distinguish three or more speakers must add voices in the same change, or the third character will quietly sound like the first.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AwtrixKitTests/VoiceCasterTests.swift
import Testing
@testable import AwtrixKit

private let extra = Voice(id: "extra")

private func makeCaster() -> VoiceCaster {
    VoiceCaster(narrator: .arthas, pool: [.arthas, .peon, extra])
}

@Test func narrationUsesTheNarratorVoice() {
    let cast = makeCaster().cast([Turn(speaker: .narrator, text: "Звонок от курьера:")])

    #expect(cast == [VoicedTurn(voice: .arthas, text: "Звонок от курьера:")])
}

@Test func firstActorIsArthasAndSecondIsPeon() {
    let cast = makeCaster().cast([
        Turn(speaker: .actor(0), text: "Я подъехал"),
        Turn(speaker: .actor(1), text: "Я вас не вижу"),
    ])

    #expect(cast.map(\.voice.id) == ["arthas", "peon"])
}

@Test func aRepeatedActorKeepsTheSameVoice() {
    let cast = makeCaster().cast([
        Turn(speaker: .actor(0), text: "раз"),
        Turn(speaker: .actor(1), text: "два"),
        Turn(speaker: .actor(0), text: "три"),
    ])

    #expect(cast.map(\.voice.id) == ["arthas", "peon", "arthas"])
}

@Test func aThirdActorDrawsTheNextPoolVoice() {
    let cast = makeCaster().cast([
        Turn(speaker: .actor(0), text: "раз"),
        Turn(speaker: .actor(1), text: "два"),
        Turn(speaker: .actor(2), text: "три"),
    ])

    #expect(cast.map(\.voice.id) == ["arthas", "peon", "extra"])
}

@Test func moreActorsThanVoicesWrapsAroundThePool() {
    let caster = VoiceCaster(narrator: .arthas, pool: [.arthas, .peon])
    let cast = caster.cast((0..<3).map { Turn(speaker: .actor($0), text: "\($0)") })

    #expect(cast.map(\.voice.id) == ["arthas", "peon", "arthas"])
}

@Test func laughterAppendedAsNarrationIsArthas() {
    let cast = makeCaster().cast([
        Turn(speaker: .actor(0), text: "реплика"),
        Turn(speaker: .narrator, text: "АХАХАХАХАХА"),
    ])

    #expect(cast.last?.voice == .arthas)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter VoiceCasterTests`
Expected: FAIL — `Voice`, `VoicedTurn`, `VoiceCaster` are undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AwtrixKit/Anecdotes/VoiceCaster.swift
import Foundation

/// A voice is addressed by name. The synthesis sidecar resolves the name to
/// `voices/<name>.wav` itself, so adding a third actor means dropping a file in
/// that directory — no code change here.
public struct Voice: Sendable, Equatable, Hashable {
    public let id: String

    public init(id: String) {
        self.id = id
    }

    public static let arthas = Voice(id: "arthas")
    public static let peon = Voice(id: "peon")
}

public struct VoicedTurn: Sendable, Equatable {
    public let voice: Voice
    public let text: String

    public init(voice: Voice, text: String) {
        self.voice = voice
        self.text = text
    }
}

/// Assigns a voice per speaker, stable across a single anecdote.
public struct VoiceCaster: Sendable {
    private let narrator: Voice
    private let pool: [Voice]

    public init(narrator: Voice = .arthas, pool: [Voice] = [.arthas, .peon]) {
        self.narrator = narrator
        self.pool = pool.isEmpty ? [narrator] : pool
    }

    public func cast(_ turns: [Turn]) -> [VoicedTurn] {
        var assigned: [Int: Voice] = [:]
        var nextPoolIndex = 0

        return turns.map { turn in
            switch turn.speaker {
            case .narrator:
                return VoicedTurn(voice: narrator, text: turn.text)
            case let .actor(index):
                if let known = assigned[index] {
                    return VoicedTurn(voice: known, text: turn.text)
                }
                let voice = pool[nextPoolIndex % pool.count]
                nextPoolIndex += 1
                assigned[index] = voice
                return VoicedTurn(voice: voice, text: turn.text)
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter VoiceCasterTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AwtrixKit/Anecdotes/VoiceCaster.swift Tests/AwtrixKitTests/VoiceCasterTests.swift
git commit -m "feat: voice casting per speaker with Arthas narration and Peon second actor"
```

---

### Task 7: Anecdote source

**Files:**
- Create: `Sources/AwtrixKit/Anecdotes/AnecdoteSource.swift`
- Test: `Tests/AwtrixKitTests/AnecdoteSourceTests.swift`
- Test: `Tests/AwtrixKitTests/Fixtures/export_top_sample.xml`

**Interfaces:**
- Consumes: Task 2's `Transport`
- Produces:
  - `struct Anecdote: Sendable, Equatable { let id: String; let text: String }`
  - `struct AnecdoteSource: Sendable` with `init(transport: Transport, feed: URL = AnecdoteSource.topFeed)`
  - `static let topFeed: URL` — `https://www.anekdot.ru/rss/export_top.xml`
  - `func fetch() async throws -> [Anecdote]`
  - `static func parse(_ xml: Data) -> [Anecdote]`

Feed choice: `export_top.xml` is titled "Лучшие анекдоты по результатам голосований" and carries 50 items — that is the popularity ranking the requirement asks for. `export_j.xml` is only the fresh ten, and `export_bestday.xml` is best-of-past-years.

Shape verified live: item text lives in `<description>` inside `CDATA`, lines are separated by the literal `<br>` tag, and `<guid>` is a stable per-anecdote URL suitable as a dedupe key.

- [ ] **Step 1: Write the failing test**

Create the fixture first, with real feed content:

```xml
<!-- Tests/AwtrixKitTests/Fixtures/export_top_sample.xml -->
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
<channel>
<title>Анекдоты из России. Лучшие анекдоты по результатам голосований</title>
<item>
<title>Анекдот №1</title>
<link>https://www.anekdot.ru/release/anekdot/day/2026-08-17/#1622958</link>
<description><![CDATA[- Ты у меня зонт забыла!<br>- Это не зонт, это трость!]]></description>
<guid>https://www.anekdot.ru/id/1622958/</guid>
</item>
<item>
<title>Анекдот №2</title>
<link>https://www.anekdot.ru/release/anekdot/day/2026-08-17/#1622956</link>
<description><![CDATA[Посмотрел &quot;Теремок&quot;. Что вам сказать? Сказка короче...]]></description>
<guid>https://www.anekdot.ru/id/1622956/</guid>
</item>
</channel>
</rss>
```

```swift
// Tests/AwtrixKitTests/AnecdoteSourceTests.swift
import Foundation
import Testing
@testable import AwtrixKit

private func loadFixture() throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: "export_top_sample", withExtension: "xml"
    ))
    return try Data(contentsOf: url)
}

@Test func parseExtractsEveryItem() throws {
    let anecdotes = AnecdoteSource.parse(try loadFixture())

    #expect(anecdotes.count == 2)
}

@Test func parseUsesGuidAsTheIdentity() throws {
    let anecdotes = AnecdoteSource.parse(try loadFixture())

    #expect(anecdotes[0].id == "https://www.anekdot.ru/id/1622958/")
}

@Test func parseTurnsBreakTagsIntoNewlines() throws {
    let anecdotes = AnecdoteSource.parse(try loadFixture())

    #expect(anecdotes[0].text == "- Ты у меня зонт забыла!\n- Это не зонт, это трость!")
}

@Test func parseDecodesHtmlEntities() throws {
    let anecdotes = AnecdoteSource.parse(try loadFixture())

    #expect(anecdotes[1].text.contains("\"Теремок\""))
    #expect(!anecdotes[1].text.contains("&quot;"))
}

@Test func parseOfGarbageYieldsNothingRatherThanThrowing() {
    #expect(AnecdoteSource.parse(Data("not xml at all".utf8)).isEmpty)
}

@Test func fetchRequestsTheTopFeed() async throws {
    let transport = RecordingTransport()
    transport.body = try loadFixture()
    let source = AnecdoteSource(transport: transport)

    let anecdotes = try await source.fetch()

    #expect(transport.requests.first?.url == AnecdoteSource.topFeed)
    #expect(anecdotes.count == 2)
}
```

Add the fixture to the test target in `Package.swift`:

```swift
.testTarget(
    name: "AwtrixKitTests",
    dependencies: ["AwtrixKit"],
    resources: [.process("Fixtures")]
),
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnecdoteSourceTests`
Expected: FAIL — `AnecdoteSource` and `Anecdote` are undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AwtrixKit/Anecdotes/AnecdoteSource.swift
import Foundation

public struct Anecdote: Sendable, Equatable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// Reads the day's popular anecdotes.
///
/// The chosen feed ranks by reader votes rather than recency; the sibling
/// `export_j.xml` is only the fresh ten and does not answer "most popular".
public struct AnecdoteSource: Sendable {
    public static let topFeed = URL(string: "https://www.anekdot.ru/rss/export_top.xml")!

    private let transport: Transport
    private let feed: URL

    public init(transport: Transport, feed: URL = AnecdoteSource.topFeed) {
        self.transport = transport
        self.feed = feed
    }

    public func fetch() async throws -> [Anecdote] {
        var request = URLRequest(url: feed)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw AwtrixError.http(
                status: response.statusCode,
                body: String(decoding: data, as: UTF8.self),
                endpoint: feed.absoluteString
            )
        }
        return Self.parse(data)
    }

    public static func parse(_ xml: Data) -> [Anecdote] {
        let document = String(decoding: xml, as: UTF8.self)
        return items(in: document).compactMap { item in
            guard
                let guid = value(of: "guid", in: item),
                let description = value(of: "description", in: item)
            else { return nil }
            return Anecdote(id: guid, text: normalize(description))
        }
    }

    // MARK: parsing helpers

    private static func items(in document: String) -> [String] {
        document
            .components(separatedBy: "<item>")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "</item>").first }
    }

    private static func value(of tag: String, in item: String) -> String? {
        guard
            let open = item.range(of: "<\(tag)>"),
            let close = item.range(of: "</\(tag)>", range: open.upperBound..<item.endIndex)
        else { return nil }
        var raw = String(item[open.upperBound..<close.lowerBound])
        if raw.hasPrefix("<![CDATA[") {
            raw = String(raw.dropFirst("<![CDATA[".count))
            if raw.hasSuffix("]]>") { raw = String(raw.dropLast(3)) }
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The feed separates lines with a literal <br> tag, which the dialogue
    /// parser expects as a newline.
    private static func normalize(_ raw: String) -> String {
        var text = raw
        for tag in ["<br/>", "<br />", "<br>"] {
            text = text.replacingOccurrences(of: tag, with: "\n")
        }
        let entities = [
            "&quot;": "\"", "&apos;": "'", "&lt;": "<", "&gt;": ">",
            "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&amp;": "&",
        ]
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AnecdoteSourceTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AwtrixKit/Anecdotes/AnecdoteSource.swift Tests/AwtrixKitTests Package.swift
git commit -m "feat: anecdote source reading the vote-ranked feed"
```

---

### Task 8: Speech synthesis over the Python sidecar

**Files:**
- Create: `Sources/AwtrixKit/Speech/SpeechSynthesizing.swift`
- Create: `Sources/AwtrixKit/Speech/SidecarSpeechSynthesizer.swift`
- Test: `Tests/AwtrixKitTests/SpeechTests.swift`

**Interfaces:**
- Consumes: Task 6's `VoicedTurn`, `Voice`
- Produces:
  - `protocol SpeechSynthesizing: Sendable { func synthesize(_ turns: [VoicedTurn]) async throws -> [URL] }`
  - `actor SidecarSpeechSynthesizer: SpeechSynthesizing` with `init(pythonPath: String, scriptPath: String, workingDirectory: String, outputDirectory: URL)`
  - `final class StubSpeechSynthesizer: SpeechSynthesizing` for tests and for running without the sidecar installed — a class, not a struct: it records what it was asked, and Task 10's tests hold a reference to the same instance the connector uses
  - `enum SpeechError: Error, Sendable { case sidecarUnavailable(String); case synthesisFailed(String) }`
  - `static func requestLine(for turn: VoicedTurn, outputPath: String) -> String`
  - `static func parseResponse(_ line: String) throws -> URL`
  - `enum SpeechText { static func prepare(_ line: String) -> String }` — the
    normalisation every line passes through before synthesis

Why a protocol and a stub: the sidecar needs a 1.8 GB model and a Python environment, so nothing above this line may depend on it being present. The connector takes `SpeechSynthesizing`, and the app degrades to no audio rather than failing to run.

**The sidecar contract** (already built and verified — do not redesign it). Script
`~/.local/share/tts-voices/speak.py`, launched once as `speak.py --serve`, then
one JSON object per line on stdin, one per line on stdout:

```
in   {"voice":"arthas","text":"Внимание, анекдот","out":"/tmp/turn-0.wav"}
out  {"ok":true,"voice":"arthas","out":"/tmp/turn-0.wav","duration":1.995}
out  {"ok":false,"error":"unknown voice: foo (have: arthas, peon)"}
```

A voice is addressed by **name**, not by a reference path — the sidecar owns
`voices/<name>.wav`. Alternating voices mid-stream is free: conditioning latents
are cached per voice after the first use. Verified with an Arthas → Peon →
Arthas → Peon run in one process, all four `ok:true`.

**Text normalisation is not optional and not cosmetic.** Each rule below fixes a
defect that was heard, reproduced, and confirmed. `SpeechText.prepare` applies
them; the clock keeps the original text.

- Strip `«» “” „‟ " ' ‘’ ` ´`. XTTS vocalises quotation marks —
  `точка»` came out as "точкала", the closing quote becoming a syllable.
- Drop a dash surrounded by spaces. Kept, it pauses long enough to sound broken.
- Remove a trailing full stop. It provokes the decoder into appending an audible
  fragment after the sentence, separated by real silence — a phantom syllable.
- KEEP a trailing `?` or `!` and append a space. The mark carries the intonation;
  without the space the final consonant is swallowed and "Анекдот!" loses its Т.
- Collapse whitespace runs, and never leave a space before punctuation.

Do NOT add stress marks. `+` and the combining acute are absent from the XTTS BPE
vocabulary, encode to `[UNK]`, and corrupt the characters next to them; a capital
is lowercased before tokenization. All four conventions were tested and all four
fail. This is recorded in the spec so it is not attempted again.

Environment constraints that will resurface — encode them, do not rediscover them:
- `transformers` must stay below 5.x; 5.x removed `isin_mps_friendly`, which coqui-tts imports.
- The sidecar must not run with a working directory containing a `coverage/` directory — it shadows the PyPI package and the failure surfaces as an unrelated numba error. Hence the explicit `workingDirectory`.
- Model load costs seconds. **The process is started once and reused.** Spawning per phrase pays that load every time and throws away the cached latents, which is the whole reason `--serve` exists.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AwtrixKitTests/SpeechTests.swift
import Foundation
import Testing
@testable import AwtrixKit

@Test func stubSynthesizerReturnsOneURLPerTurn() async throws {
    let stub = StubSpeechSynthesizer()

    let urls = try await stub.synthesize([
        VoicedTurn(voice: .arthas, text: "раз"),
        VoicedTurn(voice: .peon, text: "два"),
    ])

    #expect(urls.count == 2)
}

@Test func stubSynthesizerRecordsWhatItWasAsked() async throws {
    let stub = StubSpeechSynthesizer()

    _ = try await stub.synthesize([VoicedTurn(voice: .peon, text: "работа-работа")])

    #expect(stub.received.map(\.voice.id) == ["peon"])
    #expect(stub.received.map(\.text) == ["работа-работа"])
}

@Test func sidecarRequestLineAddressesTheVoiceByName() throws {
    let line = SidecarSpeechSynthesizer.requestLine(
        for: VoicedTurn(voice: .arthas, text: "Внимание, анекдот"),
        outputPath: "/tmp/turn0.wav"
    )
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]

    #expect(object["voice"] as? String == "arthas")
    #expect(object["text"] as? String == "Внимание, анекдот")
    #expect(object["out"] as? String == "/tmp/turn0.wav")
    #expect(!line.contains("\n"))  // one request per line
}

@Test func sidecarResponseYieldsTheProducedFile() throws {
    let url = try SidecarSpeechSynthesizer.parseResponse(
        #"{"ok":true,"voice":"peon","out":"/tmp/turn-1.wav","duration":3.52}"#
    )

    #expect(url.path == "/tmp/turn-1.wav")
}

@Test func sidecarFailureResponseSurfacesTheReportedReason() {
    #expect(throws: SpeechError.self) {
        _ = try SidecarSpeechSynthesizer.parseResponse(
            #"{"ok":false,"error":"unknown voice: foo (have: arthas, peon)"}"#
        )
    }
}

@Test func unparseableSidecarOutputIsAFailureNotACrash() {
    #expect(throws: SpeechError.self) {
        _ = try SidecarSpeechSynthesizer.parseResponse("Traceback (most recent call last):")
    }
}

@Test func missingSidecarScriptIsReportedAsUnavailable() async {
    let synthesizer = SidecarSpeechSynthesizer(
        pythonPath: "/usr/bin/false",
        scriptPath: "/nonexistent/speak.py",
        workingDirectory: NSTemporaryDirectory(),
        outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
    )

    await #expect(throws: SpeechError.self) {
        _ = try await synthesizer.synthesize([VoicedTurn(voice: .arthas, text: "hi")])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SpeechTests`
Expected: FAIL — the speech types are undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AwtrixKit/Speech/SpeechSynthesizing.swift
import Foundation

public enum SpeechError: Error, Sendable {
    case sidecarUnavailable(String)
    case synthesisFailed(String)
}

/// Turns voiced text into audio files, in order.
public protocol SpeechSynthesizing: Sendable {
    func synthesize(_ turns: [VoicedTurn]) async throws -> [URL]
}

/// Produces silent placeholder files. Lets everything above this line run
/// without a Python environment or a 1.8 GB model on disk.
public final class StubSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    public private(set) var received: [VoicedTurn] = []

    public init() {}

    public func synthesize(_ turns: [VoicedTurn]) async throws -> [URL] {
        received.append(contentsOf: turns)
        return turns.indices.map {
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("stub-turn-\($0).wav")
        }
    }
}
```

```swift
// Sources/AwtrixKit/Speech/SidecarSpeechSynthesizer.swift
import Foundation

/// Drives the long-lived Python synthesis process.
///
/// The model costs seconds to load and caches conditioning latents per voice, so
/// the process is started once and reused. Spawning per phrase would pay the
/// load every time and discard the cache that makes alternating voices free.
public actor SidecarSpeechSynthesizer: SpeechSynthesizing {
    private let pythonPath: String
    private let scriptPath: String
    private let workingDirectory: String
    private let outputDirectory: URL

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()

    public init(
        pythonPath: String,
        scriptPath: String,
        workingDirectory: String,
        outputDirectory: URL
    ) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
        self.workingDirectory = workingDirectory
        self.outputDirectory = outputDirectory
    }

    /// One request per line: the sidecar reads stdin line by line.
    public static func requestLine(for turn: VoicedTurn, outputPath: String) -> String {
        let object: [String: Any] = [
            "voice": turn.voice.id,
            "text": turn.text,
            "out": outputPath,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// `{"ok":true,"out":"..."}` on success, `{"ok":false,"error":"..."}` otherwise.
    public static func parseResponse(_ line: String) throws -> URL {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SpeechError.synthesisFailed("unparseable sidecar output: \(line)")
        }
        guard object["ok"] as? Bool == true else {
            throw SpeechError.synthesisFailed(object["error"] as? String ?? "unknown error")
        }
        guard let path = object["out"] as? String else {
            throw SpeechError.synthesisFailed("sidecar reported success without a file")
        }
        return URL(fileURLWithPath: path)
    }

    public func synthesize(_ turns: [VoicedTurn]) async throws -> [URL] {
        try start()
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )

        var produced: [URL] = []
        for (index, turn) in turns.enumerated() {
            let destination = outputDirectory.appendingPathComponent("turn-\(index).wav")
            let request = Self.requestLine(for: turn, outputPath: destination.path)
            try write(request)
            produced.append(try Self.parseResponse(try readLine()))
        }
        return produced
    }

    /// Restarts the sidecar if it died; a crashed synthesizer must not wedge the app.
    private func start() throws {
        if let process, process.isRunning { return }

        guard FileManager.default.isReadableFile(atPath: scriptPath) else {
            throw SpeechError.sidecarUnavailable("script not found at \(scriptPath)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath, "--serve"]
        // A working directory holding a `coverage/` directory shadows the PyPI
        // package and surfaces as an unrelated numba error.
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw SpeechError.sidecarUnavailable(String(describing: error))
        }

        self.process = process
        self.input = stdin.fileHandleForWriting
        self.output = stdout.fileHandleForReading
        self.pending = Data()
    }

    private func write(_ line: String) throws {
        guard let input else {
            throw SpeechError.sidecarUnavailable("sidecar stdin is closed")
        }
        input.write(Data((line + "\n").utf8))
    }

    private func readLine() throws -> String {
        guard let output else {
            throw SpeechError.sidecarUnavailable("sidecar stdout is closed")
        }
        while true {
            if let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = output.availableData
            guard !chunk.isEmpty else {
                throw SpeechError.synthesisFailed("sidecar closed its output")
            }
            pending.append(chunk)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SpeechTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AwtrixKit/Speech Tests/AwtrixKitTests/SpeechTests.swift
git commit -m "feat: speech synthesis protocol with sidecar and stub implementations"
```

---

### Task 9: Connector protocol, output and registry

**Files:**
- Create: `Sources/AwtrixKit/Connectors/Connector.swift`
- Create: `Sources/AwtrixKit/Connectors/ConnectorRegistry.swift`
- Test: `Tests/AwtrixKitTests/ConnectorRegistryTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces:
  - `struct SpokenClip: Sendable, Equatable { let url: URL; let leadIn: TimeInterval }` — `leadIn` is silence inserted BEFORE the clip
  - `struct ConnectorOutput: Sendable, Equatable` with `text`, `icon: IconRef?`, `jingle: String?`, `localAudio: [SpokenClip]`, `duration: Int?`, `color: String?`, `holdUntilAudioEnds: Bool`
  - `enum IconRef: Sendable, Equatable { case installed(String); case catalogue(Int) }`
  - `protocol Connector: Sendable { var id: String { get }; var displayName: String { get }; var defaultInterval: TimeInterval { get }; func produce() async throws -> ConnectorOutput }`
  - `final class ConnectorRegistry: @unchecked Sendable` with `register(_:)`, `all: [any Connector]`, `connector(id:) -> (any Connector)?`

This is the plugin boundary. A connector produces content and knows nothing about the device; the host in Task 11 does the talking. That split is what lets Task 10 be tested with no hardware.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AwtrixKitTests/ConnectorRegistryTests.swift
import Foundation
import Testing
@testable import AwtrixKit

private struct FakeConnector: Connector {
    let id: String
    let displayName: String
    let defaultInterval: TimeInterval = 300
    var output = ConnectorOutput(text: "hi")

    func produce() async throws -> ConnectorOutput { output }
}

@Test func registryReturnsRegisteredConnectorsInOrder() {
    let registry = ConnectorRegistry()
    registry.register(FakeConnector(id: "a", displayName: "A"))
    registry.register(FakeConnector(id: "b", displayName: "B"))

    #expect(registry.all.map(\.id) == ["a", "b"])
}

@Test func registryLooksUpByIdentifier() {
    let registry = ConnectorRegistry()
    registry.register(FakeConnector(id: "anecdotes", displayName: "Anecdotes"))

    #expect(registry.connector(id: "anecdotes")?.displayName == "Anecdotes")
    #expect(registry.connector(id: "missing") == nil)
}

@Test func registeringTheSameIdentifierReplacesRatherThanDuplicates() {
    let registry = ConnectorRegistry()
    registry.register(FakeConnector(id: "a", displayName: "first"))
    registry.register(FakeConnector(id: "a", displayName: "second"))

    #expect(registry.all.count == 1)
    #expect(registry.all.first?.displayName == "second")
}

@Test func outputDefaultsToNoIconNoJingleNoAudio() {
    let output = ConnectorOutput(text: "plain")

    #expect(output.icon == nil)
    #expect(output.jingle == nil)
    #expect(output.localAudio.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConnectorRegistryTests`
Expected: FAIL — `Connector`, `ConnectorOutput`, `ConnectorRegistry` are undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AwtrixKit/Connectors/Connector.swift
import Foundation

/// One audio file plus the silence that precedes it. The producer sets the
/// pacing because it knows what each clip is — an announcement, a dialogue line,
/// a punchline — and the player stays ignorant of all of that.
public struct SpokenClip: Sendable, Equatable {
    public let url: URL
    public let leadIn: TimeInterval

    public init(url: URL, leadIn: TimeInterval = 0) {
        self.url = url
        self.leadIn = leadIn
    }
}

public enum IconRef: Sendable, Equatable {
    /// Already present on the device, referenced by basename.
    case installed(String)
    /// Fetched from the LaMetric catalogue by id, then installed.
    case catalogue(Int)
}

public struct ConnectorOutput: Sendable, Equatable {
    public var text: String
    public var icon: IconRef?
    public var jingle: String?
    public var localAudio: [SpokenClip]
    /// Keep the banner on the clock until the audio finishes, rather than for a
    /// fixed duration. The producer knows how long it will speak; the host does
    /// not, and guessing a scroll count was worse.
    public var holdUntilAudioEnds: Bool
    public var duration: Int?
    public var color: String?

    public init(
        text: String,
        icon: IconRef? = nil,
        jingle: String? = nil,
        localAudio: [SpokenClip] = [],
        holdUntilAudioEnds: Bool = false,
        duration: Int? = nil,
        color: String? = nil
    ) {
        self.text = text
        self.icon = icon
        self.jingle = jingle
        self.localAudio = localAudio
        self.holdUntilAudioEnds = holdUntilAudioEnds
        self.duration = duration
        self.color = color
    }
}

/// A source of content. Produces and returns; never talks to the device.
public protocol Connector: Sendable {
    var id: String { get }
    var displayName: String { get }
    var defaultInterval: TimeInterval { get }
    func produce() async throws -> ConnectorOutput
}
```

```swift
// Sources/AwtrixKit/Connectors/ConnectorRegistry.swift
import Foundation

public final class ConnectorRegistry: @unchecked Sendable {
    private var storage: [any Connector] = []
    private let lock = NSLock()

    public init() {}

    public func register(_ connector: any Connector) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = storage.firstIndex(where: { $0.id == connector.id }) {
            storage[existing] = connector
        } else {
            storage.append(connector)
        }
    }

    public var all: [any Connector] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func connector(id: String) -> (any Connector)? {
        all.first { $0.id == id }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ConnectorRegistryTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AwtrixKit/Connectors Tests/AwtrixKitTests/ConnectorRegistryTests.swift
git commit -m "feat: connector protocol, output shape and registry"
```

---

### Task 10: Anecdote connector

**Files:**
- Create: `Sources/AwtrixKit/Connectors/AnecdoteConnector.swift`
- Test: `Tests/AwtrixKitTests/AnecdoteConnectorTests.swift`

**Interfaces:**
- Consumes: Tasks 5–9 — `DialogueParser`, `VoiceCaster`, `AnecdoteSource`, `SpeechSynthesizing`, `Connector`
- Produces:
  - `struct AnecdoteConnector: Connector` with
    `init(source: AnecdoteSource, speech: SpeechSynthesizing, caster: VoiceCaster = VoiceCaster(), picker: @Sendable ([Anecdote]) -> Anecdote? = { $0.randomElement() })`
  - `static let laughIcon: IconRef` — `.catalogue(9039)`
  - `static let nokiaJingle: String`
  - `static let prefix = "ВНИМАНИЕ, АНЕКДОТ: "`
  - `static let laughter = "АХАХАХАХАХА"`

The picker is injected so tests are deterministic; production uses a random pick from the ranked feed.

Constants come from the probe: `9039` is an animated laughing face verified present on the CDN, and the Nokia melody is the jingle chosen after auditioning eight candidates on the device.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AwtrixKitTests/AnecdoteConnectorTests.swift
import Foundation
import Testing
@testable import AwtrixKit

private func makeSource(_ xml: String) -> AnecdoteSource {
    let transport = RecordingTransport()
    transport.body = Data(xml.utf8)
    return AnecdoteSource(transport: transport)
}

private let dialogueFeed = """
<rss><channel><item>
<description><![CDATA[Звонок от курьера:<br>- Я подъехал...<br>- Но я вас не вижу...]]></description>
<guid>https://www.anekdot.ru/id/1/</guid>
</item></channel></rss>
"""

@Test func producedTextIsPrefixedAndSuffixed() async throws {
    let connector = AnecdoteConnector(
        source: makeSource(dialogueFeed),
        speech: StubSpeechSynthesizer(),
        picker: { $0.first }
    )

    let output = try await connector.produce()

    #expect(output.text.hasPrefix(AnecdoteConnector.prefix))
    #expect(output.text.hasSuffix(AnecdoteConnector.laughter))
    #expect(output.text.contains("Звонок от курьера"))
}

@Test func producedOutputCarriesTheLaughingIconAndNokiaJingle() async throws {
    let connector = AnecdoteConnector(
        source: makeSource(dialogueFeed),
        speech: StubSpeechSynthesizer(),
        picker: { $0.first }
    )

    let output = try await connector.produce()

    #expect(output.icon == .catalogue(9039))
    #expect(output.jingle == AnecdoteConnector.nokiaJingle)
}

@Test func everyTurnPlusLaughterIsSynthesized() async throws {
    let speech = StubSpeechSynthesizer()
    let connector = AnecdoteConnector(
        source: makeSource(dialogueFeed), speech: speech, picker: { $0.first }
    )

    _ = try await connector.produce()

    // narration + two actor lines + laughter
    #expect(speech.received.count == 4)
    #expect(speech.received.map(\.voice.id) == ["arthas", "arthas", "peon", "arthas"])
    #expect(speech.received.last?.text == AnecdoteConnector.laughter)
}

@Test func localAudioMatchesTheSynthesizedTurnOrder() async throws {
    let connector = AnecdoteConnector(
        source: makeSource(dialogueFeed),
        speech: StubSpeechSynthesizer(),
        picker: { $0.first }
    )

    let output = try await connector.produce()

    #expect(output.localAudio.count == 4)
}

@Test func anEmptyFeedThrowsRatherThanShowingNothing() async {
    let connector = AnecdoteConnector(
        source: makeSource("<rss><channel></channel></rss>"),
        speech: StubSpeechSynthesizer()
    )

    await #expect(throws: (any Error).self) {
        _ = try await connector.produce()
    }
}

@Test func connectorIdentityAndDefaultInterval() {
    let connector = AnecdoteConnector(
        source: makeSource(dialogueFeed), speech: StubSpeechSynthesizer()
    )

    #expect(connector.id == "anecdotes")
    #expect(connector.defaultInterval == 30 * 60)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnecdoteConnectorTests`
Expected: FAIL — `AnecdoteConnector` is undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AwtrixKit/Connectors/AnecdoteConnector.swift
import Foundation

public struct AnecdoteConnector: Connector {
    public enum Failure: Error, Sendable {
        case feedEmpty
    }

    /// Animated laughing face, verified present on the LaMetric CDN.
    public static let laughIcon = IconRef.catalogue(9039)
    public static let nokiaJingle =
        "nokia:d=4,o=5,b=225:8e6,8d6,f#,g#,8c#6,8b,d,e,8b,8a,c#,e,2a"
    public static let prefix = "ВНИМАНИЕ, АНЕКДОТ: "
    public static let laughter = "АХАХАХАХАХА"

    public let id = "anecdotes"
    public let displayName = "Anecdotes"
    public let defaultInterval: TimeInterval = 30 * 60

    private let source: AnecdoteSource
    private let speech: any SpeechSynthesizing
    private let caster: VoiceCaster
    private let picker: @Sendable ([Anecdote]) -> Anecdote?

    public init(
        source: AnecdoteSource,
        speech: any SpeechSynthesizing,
        caster: VoiceCaster = VoiceCaster(),
        picker: @escaping @Sendable ([Anecdote]) -> Anecdote? = { $0.randomElement() }
    ) {
        self.source = source
        self.speech = speech
        self.caster = caster
        self.picker = picker
    }

    public func produce() async throws -> ConnectorOutput {
        let anecdotes = try await source.fetch()
        guard let anecdote = picker(anecdotes) else { throw Failure.feedEmpty }

        // The laughter rides as narration, which is what makes it Arthas.
        let turns = DialogueParser.parse(anecdote.text)
            + [Turn(speaker: .narrator, text: Self.laughter)]
        let voiced = caster.cast(turns)
        let audio = try await speech.synthesize(voiced)

        return ConnectorOutput(
            text: Self.prefix + anecdote.text.replacingOccurrences(of: "\n", with: " ")
                + " " + Self.laughter,
            icon: Self.laughIcon,
            jingle: Self.nokiaJingle,
            localAudio: audio,
            duration: 15,
            color: "#FFD200"
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AnecdoteConnectorTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AwtrixKit/Connectors/AnecdoteConnector.swift Tests/AwtrixKitTests/AnecdoteConnectorTests.swift
git commit -m "feat: anecdote connector composing source, dialogue casting and speech"
```

---

### Task 11: Connector host

**Files:**
- Create: `Sources/AwtrixKit/Scheduling/ConnectorHost.swift`
- Create: `Sources/AwtrixKit/Scheduling/ConnectorSettings.swift`
- Test: `Tests/AwtrixKitTests/ConnectorHostTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 3, 9 — `AwtrixDevice`, `Connector`, `ConnectorRegistry`, `IconRef`
- Produces:
  - `struct ConnectorSettings: Sendable, Codable, Equatable { var isEnabled: Bool; var intervalPosition: Int }`
  - `protocol SettingsStore: Sendable { func settings(for id: String) -> ConnectorSettings; func save(_ settings: ConnectorSettings, for id: String) }`
  - `final class UserDefaultsSettingsStore: SettingsStore`
  - `final class InMemorySettingsStore: SettingsStore` (tests)
  - `protocol AudioPlaying: Sendable { func play(_ urls: [URL]) async }`
  - `actor ConnectorHost` with `init(device: AwtrixDevice, registry: ConnectorRegistry, store: SettingsStore, audio: AudioPlaying, iconInstaller: IconInstalling)`
  - `func runOnce(connectorId: String) async -> RunResult`
  - `enum RunResult: Sendable, Equatable { case delivered; case skipped; case failed(String) }`
  - `protocol IconInstalling: Sendable { func ensureInstalled(_ ref: IconRef) async throws -> String }`

`runOnce` is the whole delivery path and is what the tests drive: produce, install the icon if needed, push text plus icon plus jingle to the device, and start local audio. A connector that throws yields `.failed` and never propagates — nothing a connector does may take down the host.

Timer-driven scheduling is deliberately *not* tested with real time. `runOnce` carries the behaviour; the timer that calls it lives in the app layer.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AwtrixKitTests/ConnectorHostTests.swift
import Foundation
import Testing
@testable import AwtrixKit

private struct StubConnector: Connector {
    let id = "stub"
    let displayName = "Stub"
    let defaultInterval: TimeInterval = 300
    var output: ConnectorOutput?
    var error: (any Error)?

    func produce() async throws -> ConnectorOutput {
        if let error { throw error }
        return output ?? ConnectorOutput(text: "hello")
    }
}

private struct BoomError: Error {}

private final class SpyAudio: AudioPlaying, @unchecked Sendable {
    private(set) var played: [[URL]] = []
    func play(_ urls: [URL]) async { played.append(urls) }
}

private struct StubIconInstaller: IconInstalling {
    func ensureInstalled(_ ref: IconRef) async throws -> String {
        switch ref {
        case let .installed(name): return name
        case let .catalogue(id): return String(id)
        }
    }
}

private func makeHost(
    connector: any Connector,
    transport: RecordingTransport = RecordingTransport(),
    audio: SpyAudio = SpyAudio()
) -> (ConnectorHost, RecordingTransport, SpyAudio) {
    let registry = ConnectorRegistry()
    registry.register(connector)
    let host = ConnectorHost(
        device: AwtrixDevice(host: "10.0.0.5", transport: transport),
        registry: registry,
        store: InMemorySettingsStore(),
        audio: audio,
        iconInstaller: StubIconInstaller()
    )
    return (host, transport, audio)
}

@Test func runOnceDeliversTextToTheDevice() async {
    let (host, transport, _) = makeHost(connector: StubConnector())

    let result = await host.runOnce(connectorId: "stub")

    #expect(result == .delivered)
    let notified = transport.requests.contains { $0.url?.path == "/api/notify" }
    #expect(notified)
}

@Test func runOnceResolvesTheIconBeforeNotifying() async {
    var connector = StubConnector()
    connector.output = ConnectorOutput(text: "hi", icon: .catalogue(9039))
    let (host, transport, _) = makeHost(connector: connector)

    _ = await host.runOnce(connectorId: "stub")

    let request = try! #require(transport.requests.first { $0.url?.path == "/api/notify" })
    let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    #expect(body["icon"] as? String == "9039")
}

@Test func runOncePlaysLocalAudio() async {
    var connector = StubConnector()
    connector.output = ConnectorOutput(
        text: "hi", localAudio: [URL(fileURLWithPath: "/tmp/a.wav")]
    )
    let (host, _, audio) = makeHost(connector: connector)

    _ = await host.runOnce(connectorId: "stub")

    #expect(audio.played == [[URL(fileURLWithPath: "/tmp/a.wav")]])
}

@Test func aThrowingConnectorFailsWithoutPropagating() async {
    var connector = StubConnector()
    connector.error = BoomError()
    let (host, transport, _) = makeHost(connector: connector)

    let result = await host.runOnce(connectorId: "stub")

    guard case .failed = result else {
        Issue.record("expected .failed, got \(result)")
        return
    }
    #expect(transport.requests.isEmpty)
}

@Test func aDisabledConnectorIsSkipped() async {
    let registry = ConnectorRegistry()
    registry.register(StubConnector())
    let store = InMemorySettingsStore()
    store.save(ConnectorSettings(isEnabled: false, intervalPosition: 0), for: "stub")
    let transport = RecordingTransport()
    let host = ConnectorHost(
        device: AwtrixDevice(host: "10.0.0.5", transport: transport),
        registry: registry,
        store: store,
        audio: SpyAudio(),
        iconInstaller: StubIconInstaller()
    )

    #expect(await host.runOnce(connectorId: "stub") == .skipped)
    #expect(transport.requests.isEmpty)
}

@Test func anUnknownConnectorFailsRatherThanCrashing() async {
    let (host, _, _) = makeHost(connector: StubConnector())

    guard case .failed = await host.runOnce(connectorId: "nope") else {
        Issue.record("expected .failed for unknown connector")
        return
    }
}

@Test func settingsDefaultToEnabledAtThirtyMinutes() {
    let store = InMemorySettingsStore()

    let settings = store.settings(for: "anything")

    #expect(settings.isEnabled)
    #expect(settings.interval == 30 * 60)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ConnectorHostTests`
Expected: FAIL — `ConnectorHost`, `ConnectorSettings`, the stores and the two protocols are undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AwtrixKit/Scheduling/ConnectorSettings.swift
import Foundation

public struct ConnectorSettings: Sendable, Codable, Equatable {
    public var isEnabled: Bool
    public var intervalPosition: Int

    public init(isEnabled: Bool = true, intervalPosition: Int = 5) {
        self.isEnabled = isEnabled
        self.intervalPosition = intervalPosition
    }

    public var interval: TimeInterval {
        IntervalScale.duration(atPosition: intervalPosition)
    }
}

public protocol SettingsStore: Sendable {
    func settings(for id: String) -> ConnectorSettings
    func save(_ settings: ConnectorSettings, for id: String)
}

public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private var storage: [String: ConnectorSettings] = [:]
    private let lock = NSLock()

    public init() {}

    public func settings(for id: String) -> ConnectorSettings {
        lock.lock()
        defer { lock.unlock() }
        return storage[id] ?? ConnectorSettings()
    }

    public func save(_ settings: ConnectorSettings, for id: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[id] = settings
    }
}

public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ id: String) -> String { "connector.\(id)" }

    public func settings(for id: String) -> ConnectorSettings {
        guard
            let data = defaults.data(forKey: key(id)),
            let decoded = try? JSONDecoder().decode(ConnectorSettings.self, from: data)
        else { return ConnectorSettings() }
        return decoded
    }

    public func save(_ settings: ConnectorSettings, for id: String) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key(id))
    }
}
```

```swift
// Sources/AwtrixKit/Scheduling/ConnectorHost.swift
import Foundation

public protocol AudioPlaying: Sendable {
    func play(_ urls: [URL]) async
}

public protocol IconInstalling: Sendable {
    /// Returns the name the device will accept in a notify payload.
    func ensureInstalled(_ ref: IconRef) async throws -> String
}

public enum RunResult: Sendable, Equatable {
    case delivered
    case skipped
    case failed(String)
}

/// Owns everything a connector must not care about: enablement, delivery to the
/// device, and containment of failures.
public actor ConnectorHost {
    private let device: AwtrixDevice
    private let registry: ConnectorRegistry
    private let store: any SettingsStore
    private let audio: any AudioPlaying
    private let iconInstaller: any IconInstalling

    public init(
        device: AwtrixDevice,
        registry: ConnectorRegistry,
        store: any SettingsStore,
        audio: any AudioPlaying,
        iconInstaller: any IconInstalling
    ) {
        self.device = device
        self.registry = registry
        self.store = store
        self.audio = audio
        self.iconInstaller = iconInstaller
    }

    public func runOnce(connectorId: String) async -> RunResult {
        guard let connector = registry.connector(id: connectorId) else {
            return .failed("unknown connector \(connectorId)")
        }
        guard store.settings(for: connectorId).isEnabled else {
            return .skipped
        }

        do {
            let output = try await connector.produce()
            var iconName: String?
            if let icon = output.icon {
                iconName = try await iconInstaller.ensureInstalled(icon)
            }
            try await device.notify(
                NotifyPayload(
                    text: output.text,
                    icon: iconName,
                    duration: output.duration,
                    color: output.color,
                    rtttl: output.jingle,
                    pushIcon: 2
                )
            )
            if !output.localAudio.isEmpty {
                await audio.play(output.localAudio)
            }
            return .delivered
        } catch {
            return .failed(String(describing: error))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ConnectorHostTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AwtrixKit/Scheduling Tests/AwtrixKitTests/ConnectorHostTests.swift
git commit -m "feat: connector host owning enablement, delivery and failure containment"
```

---

### Task 12: Icon installer and audio player

**Files:**
- Create: `Sources/AwtrixKit/Device/CatalogueIconInstaller.swift`
- Create: `Sources/AwtrixKit/Audio/SequentialAudioPlayer.swift`
- Test: `Tests/AwtrixKitTests/CatalogueIconInstallerTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 3, 11 — `AwtrixDevice`, `Transport`, `IconInstalling`, `AudioPlaying`
- Produces:
  - `struct CatalogueIconInstaller: IconInstalling` with `init(device: AwtrixDevice, transport: Transport)`
  - `actor SequentialAudioPlayer: AudioPlaying`

The catalogue CDN serves any icon by id with no auth at
`https://developer.lametric.com/content/apps/icon_thumbs/<id>.gif`. A non-existent id answers with an HTML error page rather than a 404 body, so the installer checks the GIF magic bytes rather than trusting the status.

Already-present icons are not re-uploaded — the device flash is small.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AwtrixKitTests/CatalogueIconInstallerTests.swift
import Foundation
import Testing
@testable import AwtrixKit

/// Answers per-URL so one test can serve both a listing and a CDN download.
private final class RoutingTransport: Transport, @unchecked Sendable {
    var routes: [(match: String, status: Int, body: Data)] = []
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!.absoluteString
        let route = routes.first { url.contains($0.match) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: route?.status ?? 200, httpVersion: nil, headerFields: nil
        )!
        return (route?.body ?? Data("OK".utf8), response)
    }
}

@Test func installedIconIsReturnedAsIs() async throws {
    let transport = RoutingTransport()
    let installer = CatalogueIconInstaller(
        device: AwtrixDevice(host: "10.0.0.5", transport: transport), transport: transport
    )

    let name = try await installer.ensureInstalled(.installed("laugh"))

    #expect(name == "laugh")
    #expect(transport.requests.isEmpty)
}

@Test func catalogueIconIsDownloadedAndUploadedOnce() async throws {
    let transport = RoutingTransport()
    transport.routes = [
        ("/list?dir=/ICONS", 200, Data("[]".utf8)),
        ("icon_thumbs/9039.gif", 200, Data("GIF89a-bytes".utf8)),
    ]
    let installer = CatalogueIconInstaller(
        device: AwtrixDevice(host: "10.0.0.5", transport: transport), transport: transport
    )

    let name = try await installer.ensureInstalled(.catalogue(9039))

    #expect(name == "9039")
    let uploaded = transport.requests.contains {
        $0.url?.path == "/edit" && $0.httpMethod == "POST"
    }
    #expect(uploaded)
}

@Test func anIconAlreadyOnTheDeviceIsNotReuploaded() async throws {
    let transport = RoutingTransport()
    transport.routes = [
        ("/list?dir=/ICONS", 200, Data(#"[{"type":"file","size":"131","name":"9039.gif"}]"#.utf8)),
    ]
    let installer = CatalogueIconInstaller(
        device: AwtrixDevice(host: "10.0.0.5", transport: transport), transport: transport
    )

    let name = try await installer.ensureInstalled(.catalogue(9039))

    #expect(name == "9039")
    #expect(!transport.requests.contains { $0.url?.path == "/edit" })
}

@Test func anHtmlErrorPageIsRejectedRatherThanInstalled() async {
    let transport = RoutingTransport()
    transport.routes = [
        ("/list?dir=/ICONS", 200, Data("[]".utf8)),
        ("icon_thumbs/1.gif", 200, Data("<!DOCTYPE html><html>not found</html>".utf8)),
    ]
    let installer = CatalogueIconInstaller(
        device: AwtrixDevice(host: "10.0.0.5", transport: transport), transport: transport
    )

    await #expect(throws: (any Error).self) {
        _ = try await installer.ensureInstalled(.catalogue(1))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CatalogueIconInstallerTests`
Expected: FAIL — `CatalogueIconInstaller` is undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AwtrixKit/Device/CatalogueIconInstaller.swift
import Foundation

/// Installs icons on demand, skipping ones the device already holds.
public struct CatalogueIconInstaller: IconInstalling {
    public enum Failure: Error, Sendable {
        case notAnImage(Int)
    }

    private static let cdn = "https://developer.lametric.com/content/apps/icon_thumbs"

    private let device: AwtrixDevice
    private let transport: any Transport

    public init(device: AwtrixDevice, transport: any Transport) {
        self.device = device
        self.transport = transport
    }

    public func ensureInstalled(_ ref: IconRef) async throws -> String {
        switch ref {
        case let .installed(name):
            return name
        case let .catalogue(id):
            let name = String(id)
            let present = try await device.list("/ICONS")
            if present.contains(where: { $0.name == "\(name).gif" }) {
                return name
            }
            let blob = try await download(id: id)
            try await device.installIcon(blob, named: name)
            return name
        }
    }

    private func download(id: Int) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(Self.cdn)/\(id).gif")!)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await transport.send(request)
        // A missing id answers with an HTML page, not an error status.
        guard data.starts(with: Array("GIF".utf8)) else {
            throw Failure.notAnImage(id)
        }
        return data
    }
}
```

```swift
// Sources/AwtrixKit/Audio/SequentialAudioPlayer.swift
import AVFoundation
import Foundation

/// Plays turn audio in order, so a dialogue stays a dialogue.
public actor SequentialAudioPlayer: AudioPlaying {
    private var player: AVAudioPlayer?

    public init() {}

    public func play(_ urls: [URL]) async {
        for url in urls {
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
            guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            self.player = player
            player.play()
            let seconds = player.duration
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        player = nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CatalogueIconInstallerTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AwtrixKit/Device/CatalogueIconInstaller.swift Sources/AwtrixKit/Audio Tests/AwtrixKitTests/CatalogueIconInstallerTests.swift
git commit -m "feat: catalogue icon installer and sequential audio playback"
```

---

### Task 13: Device monitor

**Files:**
- Create: `Sources/AwtrixKit/Device/DeviceMonitor.swift`
- Test: `Tests/AwtrixKitTests/DeviceMonitorTests.swift`

**Interfaces:**
- Consumes: Task 2 — `AwtrixDevice`, `DeviceStats`
- Produces:
  - `enum DeviceState: Sendable, Equatable { case unknown; case online(DeviceStats); case offline(String) }`
  - `@MainActor final class DeviceMonitor: ObservableObject` with `@Published private(set) var state: DeviceState`, `init(device: AwtrixDevice)`, `func refresh() async`, `var isOnline: Bool`, `var batteryPercent: Int?`

`DeviceStats` gains `Equatable` here so `DeviceState` can be compared in tests.

The monitor exposes a single refresh; the app owns the timer that calls it. That keeps the type testable without waiting on real seconds.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AwtrixKitTests/DeviceMonitorTests.swift
import Foundation
import Testing
@testable import AwtrixKit

private let statsJSON = #"{"bat":83,"ram":139112,"version":"0.98","uid":"awtrix_a07f9c","ip_address":"192.168.1.72"}"#

@Test @MainActor func refreshGoesOnlineOnAGoodResponse() async {
    let transport = RecordingTransport()
    transport.body = Data(statsJSON.utf8)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))

    await monitor.refresh()

    #expect(monitor.isOnline)
    #expect(monitor.batteryPercent == 83)
}

@Test @MainActor func refreshGoesOfflineOnFailure() async {
    let transport = RecordingTransport()
    transport.status = 500
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))

    await monitor.refresh()

    #expect(!monitor.isOnline)
    #expect(monitor.batteryPercent == nil)
}

@Test @MainActor func stateStartsUnknownBeforeAnyRefresh() {
    let monitor = DeviceMonitor(
        device: AwtrixDevice(host: "10.0.0.5", transport: RecordingTransport())
    )

    #expect(monitor.state == .unknown)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DeviceMonitorTests`
Expected: FAIL — `DeviceMonitor` and `DeviceState` are undefined.

- [ ] **Step 3: Write minimal implementation**

Add `Equatable` to `DeviceStats` in `Sources/AwtrixKit/Device/AwtrixDevice.swift`:

```swift
public struct DeviceStats: Sendable, Decodable, Equatable {
```

```swift
// Sources/AwtrixKit/Device/DeviceMonitor.swift
import Foundation

public enum DeviceState: Sendable, Equatable {
    case unknown
    case online(DeviceStats)
    case offline(String)
}

/// Publishes device reachability for the menu bar. Owns no timer — the app
/// decides how often to ask, which keeps this testable without real time.
@MainActor
public final class DeviceMonitor: ObservableObject {
    @Published public private(set) var state: DeviceState = .unknown

    private let device: AwtrixDevice

    public init(device: AwtrixDevice) {
        self.device = device
    }

    public func refresh() async {
        do {
            state = .online(try await device.stats())
        } catch {
            state = .offline(String(describing: error))
        }
    }

    public var isOnline: Bool {
        if case .online = state { return true }
        return false
    }

    public var batteryPercent: Int? {
        guard case let .online(stats) = state else { return nil }
        return stats.bat
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DeviceMonitorTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AwtrixKit/Device/DeviceMonitor.swift Tests/AwtrixKitTests/DeviceMonitorTests.swift
git commit -m "feat: device monitor publishing reachability and battery"
```

---

### Task 14: Menu bar app

**Files:**
- Modify: `Package.swift` (add the executable target)
- Create: `Sources/AwtrixConnectorsApp/App.swift`
- Create: `Sources/AwtrixConnectorsApp/AppModel.swift`
- Create: `Sources/AwtrixConnectorsApp/MenuPanel.swift`
- Create: `Scripts/bundle.sh`

**Interfaces:**
- Consumes: every earlier task
- Produces: a runnable `AwtrixConnectors.app`

No unit tests here — this task is wiring and SwiftUI layout, and every piece of logic it composes is already covered. Verification is running it.

The entry file must not be called `main.swift`: a file with that name is top-level code and cannot carry `@main`.

- [ ] **Step 1: Add the executable target**

```swift
// Package.swift — targets array
.executableTarget(name: "AwtrixConnectorsApp", dependencies: ["AwtrixKit"]),
```

- [ ] **Step 2: Write the app model**

```swift
// Sources/AwtrixConnectorsApp/AppModel.swift
import AwtrixKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var deviceHost: String {
        didSet { UserDefaults.standard.set(deviceHost, forKey: "deviceHost") }
    }
    @Published private(set) var monitor: DeviceMonitor
    @Published var lastResults: [String: String] = [:]
    /// Mirrored from `monitor` because a Scene does not observe a nested
    /// ObservableObject — the menu bar glyph would never change otherwise.
    @Published private(set) var isDeviceOnline = false

    let registry = ConnectorRegistry()
    private let store = UserDefaultsSettingsStore()
    private var host: ConnectorHost
    private var timers: [String: Task<Void, Never>] = [:]

    init() {
        let savedHost = UserDefaults.standard.string(forKey: "deviceHost") ?? "192.168.1.72"
        self.deviceHost = savedHost

        let transport = URLSessionTransport()
        let device = AwtrixDevice(host: savedHost, transport: transport)
        self.monitor = DeviceMonitor(device: device)
        self.host = ConnectorHost(
            device: device,
            registry: registry,
            store: store,
            audio: SequentialAudioPlayer(),
            iconInstaller: CatalogueIconInstaller(device: device, transport: transport)
        )

        registry.register(
            AnecdoteConnector(
                source: AnecdoteSource(transport: transport),
                speech: SidecarSpeechSynthesizer(
                    pythonPath: NSString(string: "~/.local/share/tts-voices/.venv/bin/python")
                        .expandingTildeInPath,
                    scriptPath: NSString(string: "~/.local/share/tts-voices/speak.py")
                        .expandingTildeInPath,
                    workingDirectory: NSString(string: "~/.local/share/tts-voices")
                        .expandingTildeInPath,
                    outputDirectory: FileManager.default.temporaryDirectory
                        .appendingPathComponent("awtrix-speech")
                )
            )
        )

        startMonitoring()
        for connector in registry.all { reschedule(connector.id) }
    }

    func settings(for id: String) -> ConnectorSettings { store.settings(for: id) }

    func setEnabled(_ enabled: Bool, for id: String) {
        var current = store.settings(for: id)
        current.isEnabled = enabled
        store.save(current, for: id)
        objectWillChange.send()
        reschedule(id)
    }

    func setIntervalPosition(_ position: Int, for id: String) {
        var current = store.settings(for: id)
        current.intervalPosition = position
        store.save(current, for: id)
        objectWillChange.send()
        reschedule(id)
    }

    func runNow(_ id: String) {
        Task { await record(await host.runOnce(connectorId: id), for: id) }
    }

    private func record(_ result: RunResult, for id: String) {
        switch result {
        case .delivered: lastResults[id] = "delivered"
        case .skipped: lastResults[id] = "off"
        case let .failed(message): lastResults[id] = "failed: \(message.prefix(60))"
        }
    }

    private func startMonitoring() {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.monitor.refresh()
                self.isDeviceOnline = self.monitor.isOnline
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func reschedule(_ id: String) {
        timers[id]?.cancel()
        let settings = store.settings(for: id)
        guard settings.isEnabled else { return }
        timers[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(settings.interval))
                guard let self else { return }
                await self.record(await self.host.runOnce(connectorId: id), for: id)
            }
        }
    }
}
```

- [ ] **Step 3: Write the panel**

```swift
// Sources/AwtrixConnectorsApp/MenuPanel.swift
import AwtrixKit
import SwiftUI

struct MenuPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: DeviceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusSection
            Divider()
            ForEach(model.registry.all, id: \.id) { connector in
                connectorRow(connector)
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var statusSection: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(monitor.isOnline ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.isOnline ? "Connected" : "Disconnected")
                    .font(.headline)
                Text(model.deviceHost + (monitor.batteryPercent.map { " · \($0)%" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func connectorRow(_ connector: any Connector) -> some View {
        let settings = model.settings(for: connector.id)
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(connector.displayName, isOn: Binding(
                get: { settings.isEnabled },
                set: { model.setEnabled($0, for: connector.id) }
            ))
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(settings.intervalPosition) },
                        set: { model.setIntervalPosition(Int($0.rounded()), for: connector.id) }
                    ),
                    in: 0...Double(IntervalScale.positions.count - 1),
                    step: 1
                )
                Text(IntervalScale.label(atPosition: settings.intervalPosition))
                    .font(.caption.monospacedDigit())
                    .frame(width: 48, alignment: .trailing)
            }
            HStack {
                Button("Run now") { model.runNow(connector.id) }
                    .controlSize(.small)
                if let result = model.lastResults[connector.id] {
                    Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Write the entry point**

```swift
// Sources/AwtrixConnectorsApp/App.swift
import AwtrixKit
import SwiftUI

@main
struct AwtrixConnectorsApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("AWTRIX", systemImage: model.isDeviceOnline ? "clock.fill" : "clock.badge.xmark") {
            MenuPanel(model: model, monitor: model.monitor)
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 5: Write the bundling script**

```bash
#!/usr/bin/env bash
# Scripts/bundle.sh — assemble a .app around the SwiftPM executable.
set -euo pipefail

CONFIG="${1:-release}"
APP="build/AwtrixConnectors.app"

swift build -c "$CONFIG" --product AwtrixConnectorsApp
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/AwtrixConnectorsApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/AwtrixConnectors"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AwtrixConnectors</string>
  <key>CFBundleIdentifier</key><string>dev.artk0re.awtrix-connectors</string>
  <key>CFBundleName</key><string>AwtrixConnectors</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu bar only: no Dock icon, no main window. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "built $APP"
```

- [ ] **Step 6: Build and run**

Run:
```bash
chmod +x Scripts/bundle.sh
./Scripts/bundle.sh debug
open build/AwtrixConnectors.app
```

Expected: a clock icon appears in the menu bar with no Dock icon. Clicking it shows connection status against `192.168.1.72`, an Anecdotes row with a toggle and an interval slider reading `30 min`, and a "Run now" button.

- [ ] **Step 7: Verify the full suite still passes**

Run: `swift test`
Expected: PASS, all tests from Tasks 1–13.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/AwtrixConnectorsApp Scripts/bundle.sh
git commit -m "feat: menu bar app wiring status, connector toggles and interval slider"
```

---

### Task 15: Retry policy and offline pause

**Files:**
- Create: `Sources/AwtrixKit/Scheduling/RetryPolicy.swift`
- Modify: `Sources/AwtrixKit/Scheduling/ConnectorHost.swift`
- Test: `Tests/AwtrixKitTests/RetryPolicyTests.swift`

**Interfaces:**
- Consumes: Task 11 — `ConnectorHost`, `RunResult`
- Produces:
  - `struct RetryPolicy: Sendable { let base: TimeInterval; let cap: TimeInterval; func delay(afterConsecutiveFailures: Int) -> TimeInterval }`
  - `func consecutiveFailures(connectorId: String) -> Int` on `ConnectorHost`
  - `func nextDelay(connectorId: String, interval: TimeInterval) -> TimeInterval` on `ConnectorHost`

Without this, a connector whose source is down retries at full rate forever. The
spec asks for exponential backoff capped at the connector's own interval, so a
failing connector degrades to its normal cadence rather than exceeding it.

Backoff is a pure function of the failure count, which is why it is a separate
type — the timing decision gets tested without waiting on real seconds.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AwtrixKitTests/RetryPolicyTests.swift
import Foundation
import Testing
@testable import AwtrixKit

@Test func noFailuresMeansNoExtraDelay() {
    let policy = RetryPolicy(base: 30, cap: 1800)

    #expect(policy.delay(afterConsecutiveFailures: 0) == 0)
}

@Test func delayDoublesWithEachConsecutiveFailure() {
    let policy = RetryPolicy(base: 30, cap: 1800)

    #expect(policy.delay(afterConsecutiveFailures: 1) == 30)
    #expect(policy.delay(afterConsecutiveFailures: 2) == 60)
    #expect(policy.delay(afterConsecutiveFailures: 3) == 120)
}

@Test func delayNeverExceedsTheCap() {
    let policy = RetryPolicy(base: 30, cap: 300)

    #expect(policy.delay(afterConsecutiveFailures: 20) == 300)
}

@Test func aHugeFailureCountDoesNotOverflow() {
    let policy = RetryPolicy(base: 30, cap: 1800)

    #expect(policy.delay(afterConsecutiveFailures: 4096) == 1800)
}

@Test func hostCountsConsecutiveFailuresAndResetsOnSuccess() async {
    let registry = ConnectorRegistry()
    var connector = StubConnector()
    connector.error = BoomError()
    registry.register(connector)
    let transport = RecordingTransport()
    let host = ConnectorHost(
        device: AwtrixDevice(host: "10.0.0.5", transport: transport),
        registry: registry,
        store: InMemorySettingsStore(),
        audio: SpyAudio(),
        iconInstaller: StubIconInstaller()
    )

    _ = await host.runOnce(connectorId: "stub")
    _ = await host.runOnce(connectorId: "stub")
    #expect(await host.consecutiveFailures(connectorId: "stub") == 2)

    registry.register(StubConnector())  // replaces with a healthy one
    _ = await host.runOnce(connectorId: "stub")
    #expect(await host.consecutiveFailures(connectorId: "stub") == 0)
}

@Test func nextDelayGrowsWhileFailingAndReturnsToIntervalAfterSuccess() async {
    let registry = ConnectorRegistry()
    var connector = StubConnector()
    connector.error = BoomError()
    registry.register(connector)
    let host = ConnectorHost(
        device: AwtrixDevice(host: "10.0.0.5", transport: RecordingTransport()),
        registry: registry,
        store: InMemorySettingsStore(),
        audio: SpyAudio(),
        iconInstaller: StubIconInstaller()
    )

    #expect(await host.nextDelay(connectorId: "stub", interval: 1800) == 1800)
    _ = await host.runOnce(connectorId: "stub")
    #expect(await host.nextDelay(connectorId: "stub", interval: 1800) == 30)
}
```

`StubConnector`, `BoomError`, `SpyAudio` and `StubIconInstaller` are declared in
`ConnectorHostTests.swift`. Remove the `private` from those four declarations so
this file can reuse them rather than redeclaring them.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RetryPolicyTests`
Expected: FAIL — `RetryPolicy`, `consecutiveFailures`, `nextDelay` are undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AwtrixKit/Scheduling/RetryPolicy.swift
import Foundation

/// Exponential backoff, capped so a failing connector settles at its own
/// cadence rather than drifting past it.
public struct RetryPolicy: Sendable {
    public let base: TimeInterval
    public let cap: TimeInterval

    public init(base: TimeInterval = 30, cap: TimeInterval = 1800) {
        self.base = base
        self.cap = cap
    }

    public func delay(afterConsecutiveFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        // Clamp the exponent before shifting: 2^4096 is not representable.
        let exponent = min(failures - 1, 32)
        let grown = base * pow(2, Double(exponent))
        return min(grown, cap)
    }
}
```

Add to `ConnectorHost`:

```swift
// in ConnectorHost, alongside the other stored properties
private var failureCounts: [String: Int] = [:]
private let retryPolicy: RetryPolicy

// extend init with:  retryPolicy: RetryPolicy = RetryPolicy()
// and assign:        self.retryPolicy = retryPolicy

public func consecutiveFailures(connectorId: String) -> Int {
    failureCounts[connectorId] ?? 0
}

/// How long to wait before the next attempt: the normal interval while healthy,
/// a growing backoff while failing, never longer than the interval itself.
public func nextDelay(connectorId: String, interval: TimeInterval) -> TimeInterval {
    let failures = consecutiveFailures(connectorId: connectorId)
    guard failures > 0 else { return interval }
    return min(retryPolicy.delay(afterConsecutiveFailures: failures), interval)
}
```

In `runOnce`, record the outcome — set `failureCounts[connectorId] = 0` on the
`.delivered` path and increment it in the `catch` before returning `.failed`.
Leave `.skipped` untouched: a disabled connector has not failed.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RetryPolicyTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Wire it into the app timer**

In `AppModel.reschedule`, replace the fixed sleep with the host's decision:

```swift
timers[id] = Task { [weak self] in
    while !Task.isCancelled {
        guard let self else { return }
        let delay = await self.host.nextDelay(connectorId: id, interval: settings.interval)
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        await self.record(await self.host.runOnce(connectorId: id), for: id)
    }
}
```

- [ ] **Step 6: Commit**

```bash
git add Sources/AwtrixKit/Scheduling Sources/AwtrixConnectorsApp/AppModel.swift Tests/AwtrixKitTests/RetryPolicyTests.swift Tests/AwtrixKitTests/ConnectorHostTests.swift
git commit -m "feat: exponential backoff capped at the connector interval"
```

---

### Task 16: mDNS device discovery

**Files:**
- Create: `Sources/AwtrixKit/Device/DeviceDiscovery.swift`
- Modify: `Sources/AwtrixConnectorsApp/MenuPanel.swift`
- Test: `Tests/AwtrixKitTests/DeviceDiscoveryTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `struct DiscoveredDevice: Sendable, Equatable { let instanceName: String }`
  - `enum DeviceDiscovery` with `static func isAwtrixInstance(_ name: String) -> Bool`
  - `@MainActor final class DeviceBrowser: ObservableObject` with `@Published private(set) var found: [DiscoveredDevice]`, `func start()`, `func stop()`

The device advertises itself over Bonjour as an `_http._tcp` instance named
`awtrix_<mac-suffix>` — that is how it was located during the probe, without
anyone typing an address. Note that `awtrix.local` does **not** resolve; the
instance name is not the hostname, so do not build one from it.

Only the name filter is unit-tested. Browsing itself needs a live network and is
covered by the manual verification step — a test that needs a device on the LAN
is a test that fails in CI for the wrong reason.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AwtrixKitTests/DeviceDiscoveryTests.swift
import Testing
@testable import AwtrixKit

@Test func awtrixInstancesAreRecognized() {
    #expect(DeviceDiscovery.isAwtrixInstance("awtrix_a07f9c"))
    #expect(DeviceDiscovery.isAwtrixInstance("AWTRIX_A07F9C"))
}

@Test func otherBonjourInstancesAreIgnored() {
    #expect(!DeviceDiscovery.isAwtrixInstance("Brother HL-L2350DW"))
    #expect(!DeviceDiscovery.isAwtrixInstance(""))
    #expect(!DeviceDiscovery.isAwtrixInstance("my-awtrix-clone"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter DeviceDiscoveryTests`
Expected: FAIL — `DeviceDiscovery` is undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AwtrixKit/Device/DeviceDiscovery.swift
import Foundation
import Network

public struct DiscoveredDevice: Sendable, Equatable {
    public let instanceName: String

    public init(instanceName: String) {
        self.instanceName = instanceName
    }
}

public enum DeviceDiscovery {
    /// Firmware advertises `_http._tcp` as `awtrix_<mac-suffix>`.
    /// The instance name is not a hostname — `awtrix.local` does not resolve.
    public static func isAwtrixInstance(_ name: String) -> Bool {
        name.lowercased().hasPrefix("awtrix_")
    }
}

@MainActor
public final class DeviceBrowser: ObservableObject {
    @Published public private(set) var found: [DiscoveredDevice] = []

    private var browser: NWBrowser?

    public init() {}

    public func start() {
        stop()
        let browser = NWBrowser(
            for: .bonjour(type: "_http._tcp", domain: nil),
            using: .init()
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DeviceDiscovery.isAwtrixInstance(name) ? name : nil
            }
            Task { @MainActor in
                self?.found = names.sorted().map(DiscoveredDevice.init)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter DeviceDiscoveryTests`
Expected: PASS, 2 tests.

- [ ] **Step 5: Surface discovery in the panel**

Add to `MenuPanel`, below `statusSection`: a `TextField` bound to
`model.deviceHost` so the address stays editable, and a line listing
`browser.found.map(\.instanceName)` as a hint when the field does not match a
reachable device. Discovery reports presence; the user still supplies the
address, because the instance name does not resolve to one.

- [ ] **Step 6: Verify against the live network**

Run: `./Scripts/bundle.sh debug && open build/AwtrixConnectors.app`
Expected: the panel lists `awtrix_a07f9c` within a few seconds.

- [ ] **Step 7: Commit**

```bash
git add Sources/AwtrixKit/Device/DeviceDiscovery.swift Sources/AwtrixConnectorsApp/MenuPanel.swift Tests/AwtrixKitTests/DeviceDiscoveryTests.swift
git commit -m "feat: Bonjour discovery of AWTRIX instances on the local network"
```

---

## Verification against hardware

After Task 14, run the connector end to end against the real device and confirm
by eye, since three things in this system cannot be asserted in a unit test:
whether the melody is audible, whether the scroll speed is comfortable, and
whether the synthesized Russian is any good.

1. Click **Run now** on Anecdotes. The clock should play the Nokia jingle, show
   the laughing icon, and scroll `ВНИМАНИЕ, АНЕКДОТ: …` in Cyrillic while the
   Mac speaks the turns in order.
2. `scrollSpeed` is unset by default. If the text runs too fast, add
   `scrollSpeed` to the notify payload in `ConnectorHost.runOnce` and tune by
   eye — the automated measurement in `prototype/measure_scroll.py` does not
   produce a valid answer.
3. Confirm the app cleaned up: `curl -s http://192.168.1.72/list?dir=/ICONS`
   should show only what the connector needs.
