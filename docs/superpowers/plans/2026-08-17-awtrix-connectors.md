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
- **No third-party dependencies** — nothing in `Package.swift`'s dependency list,
  ever. Apple's own frameworks are not dependencies in that sense and are in
  scope as the work needs them: Foundation and SwiftUI throughout, AppKit for
  the menu bar item and the terminate hook, Network for Bonjour discovery. The
  earlier wording said "Foundation and SwiftUI only", which the plan's own
  Tasks 14 and 16 contradict; the rule it was reaching for is the one above.

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

### Task 10: Anecdote queue, preparer and connector

**Files:**

- Create: `Sources/AwtrixKit/Anecdotes/PreparedAnecdote.swift`
- Create: `Sources/AwtrixKit/Anecdotes/AnecdoteQueue.swift`
- Create: `Sources/AwtrixKit/Connectors/AnecdoteConnector.swift`
- Test: `Tests/AwtrixKitTests/AnecdoteQueueTests.swift`
- Test: `Tests/AwtrixKitTests/AnecdoteConnectorTests.swift`

**Interfaces:**

- Consumes: Tasks 5–9 — `DialogueParser`, `VoiceCaster`, `AnecdoteSource`, `SpeechSynthesizing`, `SpeechText`, `Connector`, `ConnectorOutput`, `SpokenClip`
- Produces:
  - `struct PreparedAnecdote: Sendable, Codable, Equatable { let id: String; let text: String; let clips: [SpokenClip]; let laughter: String }`
  - `actor AnecdoteQueue` with `init(storeURL: URL)`, `func ready() -> Int`, `func enqueue(_:)`, `func next() -> PreparedAnecdote?`, `func markPlayed(_ id: String)`, `func hasPlayed(_ id: String) -> Bool`, `func unseen(from: [Anecdote]) -> [Anecdote]`
  - `actor AnecdotePreparer` with `init(source: AnecdoteSource, speech: SpeechSynthesizing, queue: AnecdoteQueue, caster: VoiceCaster = VoiceCaster())`, `func refill(target: Int) async throws -> Int`
  - `struct AnecdoteConnector: Connector` with `init(queue: AnecdoteQueue, preparer: AnecdotePreparer, refillThreshold: Int = 3, batchSize: Int = 10)`
  - `static let laughIcon = IconRef.catalogue(66558)`
  - `static let nokiaJingle`, `static let banner`, `static let announcement`
  - `enum Laughter { static func forAnecdote(_ text: String, using: RandomNumberGenerator) -> String }`
  - EXTENDS Task 8's `SpeechSynthesizing` with a namespace:
    `func synthesize(_ turns: [VoicedTurn], namespace: String) async throws -> [URL]`.
    **This is not optional.** Task 8 writes `turn-<index>.wav` into one fixed
    directory, so preparing ten anecdotes in a batch would have every one
    overwrite the last — nine of the ten silently destroyed, with the queue still
    reporting ten ready. The preparer passes the anecdote's id (hashed to a safe
    filename) as the namespace, and the synthesizer writes into a subdirectory of
    that name. Task 8's implementer found this and correctly declined to fix an
    interface it did not own.
  - EXTENDS Task 7's `AnecdoteSource` with `static let cascade: [URL]` and
    `func fetch(from feed: URL) async throws -> [Anecdote]`. Task 7 shipped only
    `fetch()` against the primary feed; the cascade is new here. Keep the
    existing no-argument `fetch()` working — Task 7's tests call it.

**Why this shape.** One model load costs 70 seconds; the synthesis on top of it
costs fractions of a second. Generating an anecdote at the moment it is due pays
the whole load for four seconds of speech, which is the worst possible trade. So
the connector never synthesizes: a preparer fills a queue in batches through ONE
sidecar session, and the connector pops an already-prepared anecdote when the
timer fires. Both numbers are measured, not estimated.

**Anecdotes must not repeat.** Played ids are remembered in the same store,
which is why the feed `<guid>` is load-bearing. When every anecdote in the
primary feed has been played, the preparer widens rather than resetting:
`export_top.xml` (50, vote-ranked) → `export_bestday.xml` (12, best of past
years) → `export_j.xml` (10, the fresh ten). Roughly 72 items, refreshed daily.
Resetting instead brings repeats back inside a day at a half-hour interval.

**The spoken shape**, established by demonstration against real hardware:

1. Nokia jingle on the clock, and the banner `ВНИМАНИЕ, АНЕКДОТ!` — not the joke
   itself, which is heard rather than read. The banner is held and dismissed when
   the audio ends, so `holdUntilAudioEnds` is true.
2. `Внимание! Анекдот!` spoken in the narrator's voice.
3. The dialogue turns, each in its cast voice.
4. A beat, then the laughter.

Lead-ins, tuned by ear: 0 before the announcement, 0.7 s before the first line,
0.25 s between dialogue lines, 0.7 s before the laughter — the last is a comic
beat, not a separator.

**Laughter scales with the joke.** A one-liner does not earn a fifteen-syllable
cackle. Twelve words or fewer draw at random from three short variants so
consecutive quick jokes do not laugh identically; longer jokes get `А` plus `ХА`
repeated `min(4 + words / 8, 14)` times, and past nine repeats the laugh takes a
breath — the last three `ХА` are separated by a space. The generator is injected
so tests are deterministic.

- [ ] **Step 1: Write the failing tests for the queue**

```swift
// Tests/AwtrixKitTests/AnecdoteQueueTests.swift
import Foundation
import Testing
@testable import AwtrixKit

private func temporaryStore() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("queue-\(UUID().uuidString).json")
}

private func prepared(_ id: String) -> PreparedAnecdote {
    PreparedAnecdote(
        id: id, text: "joke \(id)",
        clips: [SpokenClip(url: URL(fileURLWithPath: "/tmp/\(id).wav"), leadIn: 0)],
        laughter: "АХАХАХА"
    )
}

@Test func anEmptyQueueHasNothingReady() async {
    let queue = AnecdoteQueue(storeURL: temporaryStore())

    #expect(await queue.ready() == 0)
    #expect(await queue.next() == nil)
}

@Test func nextReturnsInEnqueueOrderAndDrains() async {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    await queue.enqueue(prepared("a"))
    await queue.enqueue(prepared("b"))

    #expect(await queue.ready() == 2)
    #expect(await queue.next()?.id == "a")
    #expect(await queue.next()?.id == "b")
    #expect(await queue.next() == nil)
}

@Test func aPlayedAnecdoteIsRememberedAcrossInstances() async {
    let store = temporaryStore()
    let first = AnecdoteQueue(storeURL: store)
    await first.markPlayed("https://www.anekdot.ru/id/1/")
    await first.flush()

    let second = AnecdoteQueue(storeURL: store)

    #expect(await second.hasPlayed("https://www.anekdot.ru/id/1/"))
    #expect(await second.hasPlayed("https://www.anekdot.ru/id/2/") == false)
}

@Test func unseenFiltersOutWhatWasAlreadyPlayed() async {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    await queue.markPlayed("b")

    let fresh = await queue.unseen(from: [
        Anecdote(id: "a", text: "one"),
        Anecdote(id: "b", text: "two"),
        Anecdote(id: "c", text: "three"),
    ])

    #expect(fresh.map(\.id) == ["a", "c"])
}

@Test func unseenAlsoExcludesWhatIsAlreadyQueued() async {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    await queue.enqueue(prepared("b"))

    let fresh = await queue.unseen(from: [
        Anecdote(id: "a", text: "one"),
        Anecdote(id: "b", text: "two"),
    ])

    // Queueing the same anecdote twice would play it twice — the whole point
    // of the seen set is defeated if the pending queue is not consulted.
    #expect(fresh.map(\.id) == ["a"])
}

@Test func aCorruptStoreStartsEmptyInsteadOfThrowing() async {
    let store = temporaryStore()
    try? Data("not json".utf8).write(to: store)

    let queue = AnecdoteQueue(storeURL: store)

    #expect(await queue.ready() == 0)
    #expect(await queue.hasPlayed("anything") == false)
}
```

- [ ] **Step 2: Run the queue tests and confirm they fail**

Run: `swift test --filter AnecdoteQueueTests`
Expected: FAIL — `PreparedAnecdote` and `AnecdoteQueue` are undefined.

- [ ] **Step 3: Implement the queue**

```swift
// Sources/AwtrixKit/Anecdotes/PreparedAnecdote.swift
import Foundation

/// An anecdote whose audio already exists on disk, waiting for its turn.
public struct PreparedAnecdote: Sendable, Codable, Equatable {
    public let id: String
    public let text: String
    public let clips: [SpokenClip]
    public let laughter: String

    /// A filename-safe key derived from the feed guid, which contains slashes.
    public static func namespace(for id: String) -> String {
        String(
            id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        ).suffix(48).description
    }

    public init(id: String, text: String, clips: [SpokenClip], laughter: String) {
        self.id = id
        self.text = text
        self.clips = clips
        self.laughter = laughter
    }
}
```

```swift
// Sources/AwtrixKit/Anecdotes/AnecdoteQueue.swift
import Foundation

/// Prepared anecdotes waiting to play, and the ids of those already played.
///
/// Both live in one file because they answer one question together: what may be
/// played next. A played id is never forgotten — the requirement is that
/// anecdotes do not repeat, and the feed's guid is the identity that makes that
/// checkable.
public actor AnecdoteQueue {
    private struct Store: Codable {
        var pending: [PreparedAnecdote] = []
        var played: Set<String> = []
    }

    private let storeURL: URL
    private var store: Store

    public init(storeURL: URL) {
        self.storeURL = storeURL
        // A store we cannot read is treated as absent. Refusing to start because
        // of a corrupt cache would be worse than losing the cache.
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode(Store.self, from: data) {
            self.store = decoded
        } else {
            self.store = Store()
        }
    }

    public func ready() -> Int { store.pending.count }

    public func enqueue(_ anecdote: PreparedAnecdote) {
        store.pending.append(anecdote)
        persist()
    }

    public func next() -> PreparedAnecdote? {
        guard !store.pending.isEmpty else { return nil }
        let head = store.pending.removeFirst()
        persist()
        return head
    }

    public func markPlayed(_ id: String) {
        store.played.insert(id)
        persist()
    }

    public func hasPlayed(_ id: String) -> Bool { store.played.contains(id) }

    /// Anecdotes neither played nor already waiting. Consulting the pending list
    /// matters: an anecdote queued twice plays twice.
    public func unseen(from anecdotes: [Anecdote]) -> [Anecdote] {
        let queued = Set(store.pending.map(\.id))
        return anecdotes.filter { !store.played.contains($0.id) && !queued.contains($0.id) }
    }

    public func flush() { persist() }

    private func persist() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: storeURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run the queue tests and confirm they pass**

Run: `swift test --filter AnecdoteQueueTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Write the failing tests for the preparer and connector**

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

private func temporaryStore() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("conn-\(UUID().uuidString).json")
}

private let dialogueFeed = """
<rss><channel><item>
<description><![CDATA[Звонок от курьера:<br>- Я подъехал...<br>- Но я вас не вижу...]]></description>
<guid>https://www.anekdot.ru/id/1/</guid>
</item></channel></rss>
"""

/// Deterministic generator so the short-joke laughter draw can be asserted.
private struct FixedGenerator: RandomNumberGenerator {
    var value: UInt64 = 0
    mutating func next() -> UInt64 { value }
}

@Test func laughterGrowsWithTheLengthOfTheJoke() {
    var generator = FixedGenerator()
    let short = Laughter.forAnecdote("Раз два три", using: &generator)
    let long = Laughter.forAnecdote(
        String(repeating: "слово ", count: 60), using: &generator
    )

    #expect(short.count < long.count)
    #expect(long.hasPrefix("А"))
}

@Test func aLongJokeLaughTakesABreath() {
    var generator = FixedGenerator()
    let laugh = Laughter.forAnecdote(String(repeating: "слово ", count: 100), using: &generator)

    #expect(laugh.contains(" "))
}

@Test func aShortJokeDrawsFromTheShortVariants() {
    var generator = FixedGenerator()
    let laugh = Laughter.forAnecdote("Коротко", using: &generator)

    #expect(Laughter.shortVariants.contains(laugh))
}

@Test func preparerFillsTheQueueAndSynthesizesEveryTurn() async throws {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: speech, queue: queue
    )

    let added = try await preparer.refill(target: 5)

    #expect(added == 1)                       // the fixture holds one anecdote
    #expect(await queue.ready() == 1)
    // announcement + narration + two dialogue lines + laughter
    #expect(speech.received.count == 5)
    #expect(speech.received.map(\.voice.id) == ["arthas", "arthas", "arthas", "peon", "arthas"])
}

@Test func preparerSkipsAnecdotesAlreadyPlayed() async throws {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    await queue.markPlayed("https://www.anekdot.ru/id/1/")
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: speech, queue: queue
    )

    let added = try await preparer.refill(target: 5)

    #expect(added == 0)
    #expect(speech.received.isEmpty)
}

@Test func connectorEmitsTheBannerNotTheJoke() async throws {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: speech, queue: queue
    )
    _ = try await preparer.refill(target: 1)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    let output = try await connector.produce()

    #expect(output.text == AnecdoteConnector.banner)
    #expect(output.text.contains("курьера") == false)
    #expect(output.holdUntilAudioEnds)
    #expect(output.icon == .catalogue(66558))
    #expect(output.jingle == AnecdoteConnector.nokiaJingle)
}

@Test func connectorPacesTheClipsWithLeadIns() async throws {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: speech, queue: queue
    )
    _ = try await preparer.refill(target: 1)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    let output = try await connector.produce()

    #expect(output.localAudio.first?.leadIn == 0)          // announcement leads
    #expect(output.localAudio.last?.leadIn == 0.7)         // punchline beat
    #expect(output.localAudio.count == 5)
}

@Test func playingAnAnecdoteMarksItSoItNeverRepeats() async throws {
    let store = temporaryStore()
    let queue = AnecdoteQueue(storeURL: store)
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: speech, queue: queue
    )
    _ = try await preparer.refill(target: 1)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    _ = try await connector.produce()

    #expect(await queue.hasPlayed("https://www.anekdot.ru/id/1/"))
}

@Test func anEmptyQueueAndAnExhaustedFeedThrowsRatherThanShowingNothing() async {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    let preparer = AnecdotePreparer(
        source: makeSource("<rss><channel></channel></rss>"),
        speech: StubSpeechSynthesizer(), queue: queue
    )
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    await #expect(throws: (any Error).self) {
        _ = try await connector.produce()
    }
}
```

- [ ] **Step 6: Run them and confirm they fail**

Run: `swift test --filter AnecdoteConnectorTests`
Expected: FAIL — `Laughter`, `AnecdotePreparer` and the new `AnecdoteConnector`
shape are undefined.

- [ ] **Step 7: Implement the laughter, preparer and connector**

```swift
// Sources/AwtrixKit/Connectors/AnecdoteConnector.swift
import Foundation

/// The laugh scales with the joke. A one-liner does not earn a long cackle, and
/// a build-up deserves more than three syllables.
public enum Laughter {
    public static let shortVariants = ["АХАХАХА", "АХАХАХАХА", "АХАХАХАХАХ ХАХА"]
    static let shortJokeWords = 12
    static let maxRepeats = 14

    public static func forAnecdote(
        _ text: String, using generator: inout some RandomNumberGenerator
    ) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).count
        if words <= shortJokeWords {
            // Random so a run of quick jokes does not laugh identically.
            return shortVariants.randomElement(using: &generator) ?? shortVariants[0]
        }
        let repeats = min(4 + words / 8, maxRepeats)
        guard repeats >= 9 else { return "А" + String(repeating: "ХА", count: repeats) }
        // Past a certain length the laugh needs somewhere to breathe.
        return "А" + String(repeating: "ХА", count: repeats - 3)
            + " " + String(repeating: "ХА", count: 3)
    }
}

/// Fills the queue in batches. One sidecar session per batch: loading the model
/// is the entire cost of synthesis, so paying it per anecdote is the worst
/// possible trade.
public actor AnecdotePreparer {
    public enum Failure: Error, Sendable { case feedExhausted }

    static let leadFirstLine: TimeInterval = 0.7
    static let leadBetweenLines: TimeInterval = 0.25
    static let leadLaughter: TimeInterval = 0.7

    private let source: AnecdoteSource
    private let speech: any SpeechSynthesizing
    private let queue: AnecdoteQueue
    private let caster: VoiceCaster

    public init(
        source: AnecdoteSource,
        speech: any SpeechSynthesizing,
        queue: AnecdoteQueue,
        caster: VoiceCaster = VoiceCaster()
    ) {
        self.source = source
        self.speech = speech
        self.queue = queue
        self.caster = caster
    }

    /// Prepare until the queue holds `target`, widening across the feed cascade
    /// when the primary feed runs dry. Returns how many were added.
    @discardableResult
    public func refill(target: Int) async throws -> Int {
        var added = 0
        for feed in AnecdoteSource.cascade {
            if await queue.ready() >= target { break }
            let fetched = try await source.fetch(from: feed)
            for anecdote in await queue.unseen(from: fetched) {
                if await queue.ready() >= target { break }
                await queue.enqueue(try await prepare(anecdote))
                added += 1
            }
        }
        return added
    }

    private func prepare(_ anecdote: Anecdote) async throws -> PreparedAnecdote {
        var generator = SystemRandomNumberGenerator()
        let laughter = Laughter.forAnecdote(anecdote.text, using: &generator)

        // The announcement and the laughter are narration, so both land in the
        // narrator's voice without being special-cased.
        let body = DialogueParser.parse(anecdote.text)
        let turns = [Turn(speaker: .narrator, text: AnecdoteConnector.announcement)]
            + body
            + [Turn(speaker: .narrator, text: laughter)]

        // Namespaced per anecdote: a batch of ten would otherwise write ten
        // sets of turn-0.wav into the same directory.
        let urls = try await speech.synthesize(
            caster.cast(turns), namespace: PreparedAnecdote.namespace(for: anecdote.id)
        )
        var clips: [SpokenClip] = []
        for (index, url) in urls.enumerated() {
            let lead: TimeInterval
            switch index {
            case 0: lead = 0
            case 1: lead = Self.leadFirstLine
            case urls.count - 1: lead = Self.leadLaughter
            default: lead = Self.leadBetweenLines
            }
            clips.append(SpokenClip(url: url, leadIn: lead))
        }
        return PreparedAnecdote(
            id: anecdote.id, text: anecdote.text, clips: clips, laughter: laughter
        )
    }
}

public struct AnecdoteConnector: Connector {
    public enum Failure: Error, Sendable { case nothingPrepared }

    /// A 55-frame grinning face. The catalogue's animated flag is unreliable —
    /// it marks single-frame icons animated — so the frames were counted.
    public static let laughIcon = IconRef.catalogue(66558)
    public static let nokiaJingle =
        "nokia:d=4,o=5,b=225:8e6,8d6,f#,g#,8c#6,8b,d,e,8b,8a,c#,e,2a"
    /// The clock shows this, not the joke: the joke is heard, not read.
    public static let banner = "ВНИМАНИЕ, АНЕКДОТ!"
    public static let announcement = "Внимание! Анекдот!"

    public let id = "anecdotes"
    public let displayName = "Anecdotes"
    public let defaultInterval: TimeInterval = 30 * 60

    private let queue: AnecdoteQueue
    private let preparer: AnecdotePreparer
    private let refillThreshold: Int
    private let batchSize: Int

    public init(
        queue: AnecdoteQueue,
        preparer: AnecdotePreparer,
        refillThreshold: Int = 3,
        batchSize: Int = 10
    ) {
        self.queue = queue
        self.preparer = preparer
        self.refillThreshold = refillThreshold
        self.batchSize = batchSize
    }

    public func produce() async throws -> ConnectorOutput {
        if await queue.ready() <= refillThreshold {
            try await preparer.refill(target: batchSize)
        }
        guard let anecdote = await queue.next() else { throw Failure.nothingPrepared }
        await queue.markPlayed(anecdote.id)

        return ConnectorOutput(
            text: Self.banner,
            icon: Self.laughIcon,
            jingle: Self.nokiaJingle,
            localAudio: anecdote.clips,
            holdUntilAudioEnds: true,
            color: "#FFD200"
        )
    }
}
```

- [ ] **Step 8: Run them and confirm they pass**

Run: `swift test --filter AnecdoteConnectorTests`
Expected: PASS, 9 tests.

- [ ] **Step 9: Run the full suite**

Run: `swift test`
Expected: PASS, everything from Tasks 1–9 plus the 15 added here.

- [ ] **Step 10: Commit**

```bash
git add Sources/AwtrixKit/Anecdotes Sources/AwtrixKit/Connectors Tests/AwtrixKitTests
git commit -m "feat: batch-prepared anecdote queue and connector"
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
  - `protocol AudioPlaying: Sendable { func play(_ clips: [SpokenClip]) async }`
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
    private(set) var played: [[SpokenClip]] = []
    func play(_ clips: [SpokenClip]) async { played.append(clips) }
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
    func play(_ clips: [SpokenClip]) async
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
                // The banner was held so it would last exactly as long as the
                // speech; nothing else knows when that is.
                if output.holdUntilAudioEnds {
                    try await device.dismissNotification()
                }
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

    public func play(_ clips: [SpokenClip]) async {
        for clip in clips {
            // The producer set this; the player does not know or care whether it
            // is separating two speakers or holding for a punchline.
            if clip.leadIn > 0 {
                try? await Task.sleep(for: .seconds(clip.leadIn))
            }
            let url = clip.url
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
- Already written (controller-supplied, do not redesign): `Scripts/MakeIcon.swift`

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
                // Top up BEFORE the run, never inside it. `produce()` only
                // awaits a refill when the queue is empty, so a timer that
                // never maintains turns every firing into a 70-second model
                // load on the play path — the whole reason the queue exists.
                await self.host.maintain(connectorId: id)
                await self.record(await self.host.runOnce(connectorId: id), for: id)
            }
        }
    }
}
```

**Wiring the composition root (this task owns it).** `ConnectorHost` holds no
output directory, so two wires that earlier tasks deliberately refused to invent
land here, where `outputDirectory` and `storeURL` are both chosen anyway:

- pass that same `outputDirectory` to `AnecdoteQueue` as a **required**
  `clipRoot`. Task 10's reaper proves only that a directory is NAMED for its
  anecdote; a root it can be checked against is the containment that was left
  undone, and a default value would read as a guarantee while supplying none.
- read `Connector.defaultInterval` when the store has never saved settings for
  that connector. `IntervalScale.position(for:)` already exists; what is missing
  is a `SettingsStore` read that can answer "never saved" rather than handing
  back a hardcoded 30 minutes. Two methods, not a shape to guess.

**Quit must not hang.** Cancelling a queued run stops its work but does not
release its caller, so tearing down timers on quit can wait out a playing
anecdote. Measure it; if quit is slow, that is where it gets fixed.

> **Amended by the user, after seeing it in the tray: remove the "Remove icons
> this app uploaded" button for now.** The machinery stays — `UploadedIconStore`,
> the record written at the upload site, and `AwtrixDevice.removeIcon` are all
> built and tested — only the menu item goes. Two consequences, stated rather
> than buried: the icons this app has already uploaded stay on the device with no
> user-facing way to remove them, so the global constraint "the app removes what
> it created" is **temporarily unmet by deliberate choice**, not by oversight;
> and whatever surface returns later should reuse the existing store rather than
> re-deriving what to delete, because the plain `<id>.gif` naming still makes
> "delete everything with our prefix" impossible.

**Installed icons are the only thing this app writes to device flash, and
nothing removes them.** `CatalogueIconInstaller` uploads `/ICONS/<id>.gif` and
skips ids already present; there is no caller of `removeIcon` anywhere in
`Sources/`, and the plan's own constraint says the app removes what it created.
Two facts shape the fix rather than an arbitrary choice:

- The bare `<id>.gif` name is deliberate, not an oversight. It is what lets the
  skip-by-name check reuse an icon the user already installed themselves, which
  a prefix like `awx-` would forfeit. Do not rename.
- So removal cannot be "delete everything with our prefix". Track what this app
  uploaded — the installer knows, because it only uploads on a miss — and offer
  the user an explicit action that removes exactly that set.

A menu item is the honest shape: the icons must survive quit and relaunch, so a
teardown hook would be wrong. Do not remove an icon the app found already
present.

**The app's own icon is drawn, not borrowed.** AWTRIX 3 publishes no square
logo — the only mark in its repository is a wide AI-rendered cover banner whose
wordmark is illegible below roughly 64pt, and the project is CC BY-NC-SA, so
shipping a crop of it would drag attribution and ShareAlike onto the artwork for
a worse result. `Scripts/MakeIcon.swift` therefore renders the mark from code:
the thing AWTRIX actually is, a dark slab with a 32x8 LED panel across its face.

Three details in that generator are load-bearing, so read it before changing it:

- Every lit pixel comes from a hash of its own coordinates, never from a random
  source. Two runs are byte-identical, so a diff in the art means someone
  changed the design.
- The art is drawn once at 1024 and resampled down for every other size, not
  redrawn per size. That was settled by rendering both and looking: the
  resampled wordmark still reads at 32px, while art drawn directly at 32px
  aliases into noise. `build/icon/preview-small-comparison.png` is that
  comparison, kept so nobody re-opens the question.
- The menu bar glyph is a separate, much coarser drawing, and a template image:
  macOS discards its colour and recolours the shape, so it has to read as a
  silhouette at 18pt. Online and offline are two glyphs, a panel with pixels and
  an empty one, rather than one glyph plus a badge.

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
        MenuBarExtra {
            MenuPanel(model: model, monitor: model.monitor)
        } label: {
            Image(nsImage: Self.glyph(lit: model.isDeviceOnline))
        }
        .menuBarExtraStyle(.window)
    }

    /// The menu bar mark, as a template image so macOS recolours it for light,
    /// dark and the highlighted state. Offline is the same panel with nothing
    /// lit on it.
    ///
    /// `NSImage(named:)` reads `Contents/Resources`, which only exists once
    /// `Scripts/bundle.sh` has assembled the .app — under a bare `swift run`
    /// there is no bundle and this returns nil. The SF Symbol fallback is what
    /// keeps the unbundled binary usable rather than showing an empty slot.
    private static func glyph(lit: Bool) -> NSImage {
        let name = lit ? "MenuBarIcon" : "MenuBarIconOffline"
        let image = NSImage(named: name)
            ?? NSImage(systemSymbolName: lit ? "square.grid.3x2.fill" : "square.grid.3x2",
                       accessibilityDescription: "AWTRIX")!
        image.isTemplate = true
        // 30x18, not square: the menu bar caps an item's HEIGHT at the bar's,
        // but not its width, and the glyph is a wide device. The generator
        // emits it at this aspect, so the size here must match or macOS
        // stretches it.
        image.size = NSSize(width: 30, height: 18)
        return image
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/AwtrixConnectors"

# The artwork is generated, never committed: build/ is git-ignored, so the only
# thing under version control is the code that draws it.
swift Scripts/MakeIcon.swift
iconutil -c icns build/icon/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp build/icon/MenuBarIcon*.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AwtrixConnectors</string>
  <key>CFBundleIdentifier</key><string>dev.artk0re.awtrix-connectors</string>
  <key>CFBundleName</key><string>AwtrixConnectors</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
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

Expected: the AWTRIX panel glyph appears in the menu bar with no Dock icon, and `AwtrixConnectors.app` shows the AWTRIX icon in Finder. Clicking it shows connection status against `192.168.1.72`, an Anecdotes row with a toggle and an interval slider reading `30 min`, and a "Run now" button.

- [ ] **Step 7: Verify the full suite still passes**

Run: `swift test`
Expected: PASS, all tests from Tasks 1–13.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/AwtrixConnectorsApp Scripts/bundle.sh Scripts/MakeIcon.swift
git commit -m "feat: menu bar app wiring status, connector toggles and interval slider"
```

---

### Task 15: Retry policy and offline pause

> **Ruling, after implementation, on a contradiction the implementer surfaced
> rather than silently resolving.** The formula `min(backoff, interval)` makes a
> failing connector retry *sooner* than its cadence, not later — 30s, 60s, …
> ramping back up to the interval — which reads as the opposite of "back off".
> It stands, and the framing that called it "stop hammering the feed" was wrong.
> This is a desktop app polling one RSS document; at worst it makes one request
> every thirty seconds during an outage, roughly six extra requests across a
> half-hour blip. **Correction, from Task 15's review:** requests are not what
> this policy actually spends. `produce()` pops and `retire()`s an anecdote
> *before* delivery, so a run that fails to reach the clock burns a prepared
> anecdote the user never hears — about six per half-hour outage instead of one,
> which also drops the queue below its refill threshold and buys an extra
> synthesis batch. That cost is real, and it is bounded by Task 20 rather than by
> changing this formula. What the cap actually buys is the thing that matters here: a
> feed that recovers at 10:01 shows an anecdote at 10:02 instead of at 10:30.
> `interval + backoff` would trade a load problem nobody has for a staleness
> problem every user would notice. `theBackoffNeverWaitsLongerThanTheConnectorsOwnInterval`
> is the test that encodes this, and it is deliberate, not incidental.

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
Leave `.skipped` untouched: a disabled connector has not failed. **`.cancelled`
is untouched too, and it now shares that `catch`** — a run the app itself tore
down is not evidence the feed is sick, and counting it would back off a
connector for being interrupted. Only a genuine error advances the counter.

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

### Task 17: Clips outlive the play, and expire on their own

**Files:**
- Modify: `Sources/AwtrixKit/Anecdotes/AnecdoteQueue.swift`
- Modify: `Sources/AwtrixKit/Anecdotes/PreparedAnecdote.swift`
- Test: `Tests/AwtrixKitTests/AnecdoteQueueTests.swift`

**Interfaces:**
- Produces:
  - `public struct PlayedAnecdote: Sendable, Codable, Equatable { let anecdote: PreparedAnecdote; let playedAt: Date }`
  - `AnecdoteQueue.init(storeURL:clipRoot:retention:)` — `retention: TimeInterval`, required
  - `func history() -> [PlayedAnecdote]` — newest first
  - `func reapExpired(now: Date) -> Int` — deletes expired clip trees, drops their entries, returns how many went

Two requirements arrive as one change. Clips must survive being played, because
History has nothing to replay otherwise; and they must not accumulate forever,
because nothing else bounds them once the one-behind reaper is gone. Retention
IS the bound.

**What replaces what.** `retire(_:)` currently parks the played anecdote's clip
directory in `spentClipDirectory` and deletes it on the NEXT retire. That
one-behind reaper goes. In its place `retire` appends a `PlayedAnecdote` to
`history` with the moment it played, and clips are removed only by age.

**Three constraints that decide the shape:**

- **`played` stays exactly as it is.** It is the never-repeat identity and the
  file's own comment says a played id is never forgotten. History expires;
  `played` does not. Do not fold one into the other — an anecdote that left
  History must still never play twice.
- **The store must decode old files.** Swift's synthesised `init(from:)` does
  NOT fall back to a property's default value for a missing key, which is why
  `SalvagedPlayed` exists at all. Adding `history` as a plain field would make
  every existing store fail to decode and take the played set with it. Write an
  explicit `init(from:)` for `Store` using `decodeIfPresent` for every field,
  once, so this class of break cannot recur. Old stores also carry
  `spentClipDirectory`: read it, delete that directory if it is still there and
  still inside `clipRoot`, then drop the field. Leaking it would be a silent
  regression from today's behaviour.
- **`reapExpired` takes `now` as a parameter.** A test cannot wait ten days, and
  a clock abstraction for one call site is ceremony. The caller supplies the
  instant; the app passes `Date()`.

Reaping obeys the containment rule Task 10 established and Task 14 hardened:
delete a directory only when it lies inside `clipRoot` AND is named
`PreparedAnecdote.namespace(for:)` of the entry that owns it. An entry whose
directory fails either test is dropped from history WITHOUT a delete — the
record is ours, the directory may not be.

- [ ] **Step 1: Write the failing tests**

Name them for the rules, not for the mechanism:

- `aPlayedAnecdoteKeepsItsClipsUntilTheyExpire`
- `clipsOlderThanTheRetentionWindowAreDeleted`
- `clipsInsideTheRetentionWindowSurviveAReap`
- `reapingDropsTheHistoryEntryItDeleted`
- `aHistoryEntryOutsideTheClipRootIsDroppedWithoutDeleting`
- `aHistoryEntryWhoseDirectoryIsMisnamedIsDroppedWithoutDeleting`
- `expiringFromHistoryDoesNotMakeAnAnecdotePlayableAgain`
- `aStoreWrittenBeforeHistoryExistedStillDecodes`
- `anOldStoresSpentClipDirectoryIsReclaimedOnce`
- `historyIsNewestFirst`

The boundary test matters: an entry exactly at the retention age. Pick the side
deliberately and let the test name say which.

- [ ] **Step 2: Run them and watch them fail**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Green, zero warnings, and mutate**

Mutations this task must survive, one site at a time: invert the age
comparison; drop the containment check; drop the namespace check; delete the
entry but not the directory; delete the directory but not the entry; remove a
reaped id from `played`.

- [ ] **Step 5: Commit** — `feat: keep played clips until they expire, then reap by age`

---

### Task 18: Ten ready, refreshed daily, played best-first

**Files:**
- Modify: `Sources/AwtrixKit/Anecdotes/AnecdoteSource.swift` (`Anecdote` gains `rank`)
- Modify: `Sources/AwtrixKit/Anecdotes/PreparedAnecdote.swift` (gains `rank`, `preparedAt`)
- Modify: `Sources/AwtrixKit/Anecdotes/AnecdoteQueue.swift` (play order)
- Modify: `Sources/AwtrixKit/Connectors/AnecdoteConnector.swift` (depth policy, daily refresh)
- Modify: `Sources/AwtrixConnectorsApp/AppModel.swift` (top up at launch, maintain after a run)
- Test: `Tests/AwtrixKitTests/AnecdoteQueueTests.swift`, `AnecdoteConnectorTests.swift`, `AnecdoteSourceTests.swift`

**The measured fact this task is built on.** `export_top.xml` carries no rating,
no vote count, no score — its elements are `title`, `pubDate`, `link`,
`description`, `guid` and nothing else. Fetched and inspected, not assumed. What
the feed *is*, by its own definition and by the note already in
`AnecdoteSource`, is **ranked by reader votes**. So popularity is available for
free as **position in the feed**, and only as that. Do not fetch each
anecdote's HTML page to recover a number; that is a request per anecdote against
a page whose markup nobody controls, to obtain an ordering the feed already
gave.

**Play order** is therefore two keys, in this order:

1. **Generation, newest first** — the calendar day the anecdote was prepared.
   Today's batch outranks yesterday's leftovers entirely.
2. **Feed rank, ascending** — within one generation, the most-voted plays first.

Both keys are needed and neither is optional: rank alone would let a
high-ranked leftover from last week outrank everything new forever, and
generation alone would play today's batch in arbitrary order.

**Depth policy:**

- Target **10**, threshold **5**. A run that leaves five prepared triggers a
  refill back to ten — five at a time rather than two, which is the balance the
  user asked for. It is cheap either way: `SidecarSpeechSynthesizer` runs the
  model as a long-lived `--serve` process, so the 70-second load is paid once
  per process, not once per refill.
- **At launch, top up to ten** before the first timer ever fires. Starting with
  an empty queue makes the first anecdote wait on synthesis.
- The app calls `maintain(connectorId:)` **after** every completed run, manual
  or timed, in addition to Task 14's call before each timer-driven run. A manual
  "Run now" that drains the queue must not wait for the next timer. `maintain`
  returns early above the threshold, so the extra call costs nothing.
- The refill must never block a run's completion.

**Daily refresh.** When no anecdote in the queue was prepared today, prepare a
fresh batch of ten, regardless of current depth. Yesterday's leftovers are kept
— they simply rank below everything new. This needs no timer of its own: it is
a condition `maintain` checks, and `maintain` already runs before and after
every run.

**Two consequences to handle, not discover:**

- `Anecdote` and `PreparedAnecdote` both gain fields. `PreparedAnecdote` is
  persisted, and its own file warns that one added non-optional field makes
  every existing store fail to decode. Use the tolerant `init(from:)` Task 17
  introduces — `decodeIfPresent` for the new fields, with a stored anecdote that
  predates them treated as generation "before today" and rank "worst", so old
  entries sort last instead of crashing or jumping the queue.
- Unplayed anecdotes now accumulate across days. Task 17's reaper must bound
  **pending** clips by the same retention window it applies to history, or the
  leftovers grow without limit. An unplayed anecdote older than the window goes,
  clips and all — ten days stale is not worth the disk.

- [ ] **Step 1: Write the failing tests**

- `theFeedsOrderIsCarriedThroughAsRank`
- `todaysBatchPlaysBeforeYesterdaysLeftovers`
- `withinOneGenerationTheBestRankedPlaysFirst`
- `aHighRankedLeftoverDoesNotOutrankAnythingPreparedToday`
- `aRunThatLeavesFivePreparedTriggersARefill`
- `aRunThatLeavesSixPreparedDoesNotRefill`
- `theRefillTopsUpToTenNotToTheThreshold`
- `aQueueWithNothingPreparedTodayGetsAFreshBatchEvenWhenItIsFull`
- `aQueueAlreadyRefreshedTodayIsNotRefreshedAgain`
- `theAppTopsUpToTenAtLaunch`
- `aManualRunRefillsWithoutWaitingForTheTimer`
- `theRefillDoesNotDelayTheRunsOwnCompletion`
- `aStoredAnecdoteWithoutARankSortsLastRatherThanFirst`

- [ ] **Step 2–4: fail, implement, green + mutate**

Mutations, one site at a time: swap the two sort keys; sort rank descending;
change `<=` to `<` at the threshold; refill to the threshold instead of the
target; move the refill onto the produce path; drop the post-run maintain and
keep only the pre-run one; make the daily-refresh check compare instants rather
than calendar days; treat a missing rank as best rather than worst.

- [ ] **Step 5: Commit** — `feat: ten ready, refreshed daily, played best-first`

---

### Task 19: History in the menu — replay and copy

**Files:**
- Create: `Sources/AwtrixConnectorsApp/HistoryMenu.swift`
- Modify: `Sources/AwtrixKit/Scheduling/ConnectorHost.swift`
- Modify: `Sources/AwtrixKit/Connectors/AnecdoteConnector.swift`
- Modify: `Sources/AwtrixConnectorsApp/MenuPanel.swift`, `AppModel.swift`
- Test: `Tests/AwtrixKitTests/ConnectorHostTests.swift`, `Tests/AwtrixConnectorsAppTests/`

**Interfaces:**
- Produces:
  - `ConnectorHost.deliver(_ output: ConnectorOutput) async -> RunResult`
  - `AnecdoteConnector.output(for anecdote: PreparedAnecdote) -> ConnectorOutput`

The Anecdotes row gains its **own History button**, and the history it opens
lists what is still on disk — which Task 17 already bounds to the retention
window, so nothing here needs its own limit. Each entry shows **when it played**
and offers **Play again** and **Copy text**.

The played-at time lives here and nowhere else. It is the answer to "what was
that one this morning", which is a question asked while browsing history, not
while glancing at a menu — and the panel is already carrying the *next* run's
time, which is the one worth seeing at a glance.

**The split that makes replay honest.** `runOnce` today is produce-then-deliver
welded together. Factor the second half out as `deliver(_:)` and have `runOnce`
call it. Replay is then `deliver(connector.output(for: anecdote))` — the same
banner, the same jingle, the same audio serialisation, the same failure
handling. Anything that re-implements delivery for replay will drift from it.

**Four rules the implementation must hold:**

- A replay is NOT a run. It must not touch `played`, must not advance or reset
  the failure counter Task 15 owns, and must not be counted as a run for the
  purposes of the refill in Task 18. Replaying an anecdote from a week ago
  cannot make tomorrow's schedule behave differently.
- A replay respects the same serialisation as a run. Two replays, or a replay
  during a scheduled run, queue rather than overlap — the audio path and the
  banner both assume one at a time.
- An entry whose clips are gone is still listed and still copyable, but Play
  again is disabled. `PreparedAnecdote.isPlayable` already answers this; do not
  invent a second answer.
- Copy puts the anecdote's `text` on the pasteboard — the text, not the banner,
  not the laughter marker, not a formatted dump.

- [ ] **Step 1: Write the failing tests**

- `deliverSendsTheBannerWithoutAskingTheConnectorToProduce`
- `runOnceStillDeliversWhatItProduced`
- `aReplayDoesNotAddToThePlayedSet`
- `aReplayDoesNotAdvanceTheFailureCounter`
- `aReplayWaitsForARunInFlightRatherThanOverlapping`
- `anEntryWithMissingClipsCannotBeReplayed`
- `copyingPutsTheAnecdoteTextOnThePasteboard`
- `historyListsNewestFirstAndStopsAtTheRetentionWindow`

- [ ] **Step 2–4: fail, implement, green + mutate**

Mutations: have replay write to `played`; have replay bump the failure counter;
let a replay bypass the serialisation; enable Play again for an unplayable
entry; copy the banner instead of the text.

- [ ] **Step 5: Commit** — `feat: anecdote history with replay and copy`

---

### Task 20: Pause the schedule while the device is unreachable

**Files:**
- Modify: `Sources/AwtrixConnectorsApp/AppModel.swift`
- Test: `Tests/AwtrixConnectorsAppTests/AppModelTests.swift`

Half of Task 15's title was "offline pause", the design doc asks for it, and
Task 15's six steps never mentioned it — so it was never built. That is a gap in
the plan, not in the work; this task closes it.

**This is not housekeeping — it is the bound on a policy that has already
shipped.** Task 15's review established what a retry actually costs: `produce()`
pops and `retire()`s an anecdote *before* delivery, so every retry against an
unreachable clock permanently consumes a prepared anecdote the user never hears.
With the backoff in place that is roughly six per half-hour outage rather than
one, and it drags the queue under its refill threshold, buying a synthesis batch
on top. Pausing the schedule turns six burnt anecdotes into zero runs.

The alternative — returning an undelivered anecdote to the queue — was
considered and rejected. It would mean removing an id from `played`, and
`played` is the never-repeat guarantee; a restore path that is subtly wrong
brings back repeats, which is a worse failure than losing one anecdote to a
transient error. Not running at all while the device is unreachable removes the
cost without touching that guarantee. A delivery failure that is *not* an
outage still burns one anecdote, and that is accepted.

Running a connector against a clock that is not answering costs the whole
preparation — a feed fetch, a model load, a batch of synthesis — to deliver a
banner nobody receives, and then records a failure that the retry policy takes
as evidence about the *feed*. The device being unreachable is not the feed's
fault and must not be counted against it.

**The rule:** while `DeviceMonitor` reports the device offline, the timer does
not run connectors. It keeps ticking and it keeps polling the device, so the
moment the device answers the schedule resumes; nothing about the pause is
sticky.

**Four things this must not do:**

- It must not touch the failure counter, in either direction. A pause is neither
  a failure nor a success — resuming after an outage must not reset a backoff
  that a genuinely broken feed had earned.
- It must not pause `maintain`. Preparing anecdotes needs the feed and the
  sidecar, neither of which is the clock; an outage is exactly when the queue
  should be filling, so that recovery has something to show immediately.
- It must not swallow a manual "Run now". If the user presses it while the
  device is offline, the run happens and fails honestly, with the reason on the
  panel. Silence would read as the button being broken, which is precisely the
  defect this branch already shipped once.
- It must not treat `.unknown` as offline. Before the first poll answers, the
  state is unknown, and pausing on it would mean the app never runs anything at
  launch until a poll lands.

- [ ] **Step 1: Write the failing tests**

- `theScheduleDoesNotRunConnectorsWhileTheDeviceIsOffline`
- `theScheduleResumesAsSoonAsTheDeviceAnswers`
- `anOfflinePauseDoesNotAdvanceTheFailureCounter`
- `anOfflinePauseDoesNotResetAnEarnedBackoff`
- `maintenanceStillRunsWhileTheDeviceIsOffline`
- `aManualRunStillRunsWhileTheDeviceIsOffline`
- `anUnknownDeviceStateDoesNotPauseTheSchedule`

- [ ] **Step 2–4: fail, implement, green + mutate**

Mutations: gate on `!isOnline` so `.unknown` pauses too; pause `maintain` as
well; let the pause reset the failure counter; gate the manual path too; make
the pause sticky until a run succeeds.

- [ ] **Step 5: Commit** — `feat: pause the schedule while the clock is unreachable`

---

### Task 21: The sidecar gets an environment, not the app's

**Files:**
- Modify: `Sources/AwtrixKit/Speech/SidecarSpeechSynthesizer.swift`
- Test: `Tests/AwtrixKitTests/SpeechTests.swift`

**A live defect, diagnosed and reproduced.** Pressing "Run now" in the bundled
app fails with `synthesisFailed` carrying `[Errno 2] No such file or directory:
'ffmpeg'`. The mechanism, confirmed rather than inferred:

- `speak.py` normalises every clip through `ffmpeg`, which lives in
  `/opt/homebrew/bin` on this machine.
- An app launched from Finder inherits its environment from launchd, and
  `launchctl getenv PATH` is empty — so the process gets the default
  `/usr/bin:/bin:/usr/sbin:/sbin`, with no homebrew on it.
- `SidecarSpeechSynthesizer` sets no `process.environment` at all, so the Python
  child inherits that stripped `PATH`. `subprocess.run(["ffmpeg", …])` raises
  `FileNotFoundError`, `speak.py`'s `serve` catches it and answers
  `{"ok": false, "error": "[Errno 2] …"}`, and the Swift side reports
  `synthesisFailed`.

Reproduced directly: with `PATH=/usr/bin:/bin:/usr/sbin:/sbin` the call raises
that exact string; with `/opt/homebrew/bin` on the path it exits 0.

**Why no test caught it, and what that means for the fix.** The suite runs from
a terminal, where `PATH` is whatever the developer's shell has. Any test that
merely calls the synthesizer inherits a working environment and passes. The test
for this must therefore **assert what the child is given**, not what happens to
work — the environment handed to the process, not the outcome of a synthesis.

**The fix:**

- Build the child's environment explicitly rather than inheriting it: take
  `ProcessInfo.processInfo.environment` and ensure `PATH` contains the
  directories the sidecar's own tools live in, `/opt/homebrew/bin` and
  `/usr/local/bin` among them. Prepend rather than replace: a developer running
  from a shell must keep whatever they had.
- **Fail early and by name.** Resolve `ffmpeg` at sidecar start, the way the
  script path is already checked, and throw `sidecarUnavailable("ffmpeg not
  found on PATH")` rather than letting it surface mid-synthesis as an opaque
  errno. An unresolvable tool is a startup fact, not a per-clip accident.
- Do **not** edit `speak.py`. Its JSONL contract is depended on by Swift code
  and by the prototype; the missing environment is the app's fault, not the
  script's.

- [ ] **Step 1: Write the failing tests**

- `theSidecarIsGivenAPathThatIncludesTheToolsItShellsOutTo`
- `theSidecarKeepsTheDevelopersOwnPathEntries`
- `anUnresolvableFfmpegFailsAtStartupWithItsOwnName`
- `theSidecarInheritsTheRestOfTheEnvironmentUnchanged`

- [ ] **Step 2–4: fail, implement, green + mutate**

Mutations: drop the environment assignment entirely; replace the inherited
environment instead of extending it; append the tool directories after the
inherited `PATH` rather than before; remove the startup resolution so the
failure returns to being a mid-synthesis errno.

- [ ] **Step 5: Commit** — `fix: give the speech sidecar a PATH that reaches its own tools`

---

### Task 22: Battery trajectory, warnings, and the tray glyph

**Files:**
- Create: `Sources/AwtrixKit/Device/BatteryTrajectory.swift`
- Modify: `Sources/AwtrixKit/Device/AwtrixDevice.swift` (`DeviceStats` gains `batRaw`, `uptime`)
- Modify: `Sources/AwtrixKit/Device/DeviceMonitor.swift` (feed each poll into the trajectory)
- Modify: `Sources/AwtrixConnectorsApp/AppModel.swift`, `MenuPanel.swift`
- Create: `Sources/AwtrixConnectorsApp/BatteryAlert.swift`
- Test: `Tests/AwtrixKitTests/BatteryTrajectoryTests.swift`, `Tests/AwtrixConnectorsAppTests/`

**Two facts established against the live device and a probe, before any design.**

The firmware exposes **no charging or mains-power field**. `/api/stats` on the
real clock returns `bat`, `bat_raw`, `type`, `lux`, `ldr_raw`, `ram`, `bri`,
`temp`, `hum`, `uptime`, `wifi_signal`, `messages`, `version`, `indicator1..3`,
`app`, `uid`, `matrix`, `ip_address` — and nothing else. So "is it plugged in"
is not readable; it is **inferred from the trend**, which is what the whole task
turns on.

`UNUserNotificationCenter` works from a locally built, unsigned bundle: it
resolves without throwing and reports `notDetermined`, so authorization can be
requested. System notifications are therefore real here, not theoretical.

**Inferring the state.** `bat_raw` (648 at 91%) is finer than the integer
percent, so the slope is computed on **raw** and everything the user sees uses
**percent**. Rising means charging, falling means discharging, flat holds the
previous verdict rather than flapping. Three reset conditions, each of which
would otherwise poison the estimate:

- `uptime` going backwards — the device rebooted, and a reboot is exactly when
  someone unplugs and replugs it. Discard the history.
- `uid` changing — a different clock entirely.
- A gap in sampling longer than the window — the app was asleep or quit, and the
  two samples either side of it say nothing about a rate.

**ETA.** Time to empty is percent over rate, and it is worthless from two
samples twenty seconds apart. Require a minimum observed span and a minimum raw
delta before showing a number at all; until then the panel says it is still
estimating. **Never render a confident duration derived from noise** — a clock
that claims "4 h 20 m" and means "I have two samples" is worse than one that
says nothing.

**Warnings.** Thresholds at **20% (yellow), 10%, 5%, 1% (red)**. Each fires a
dialog from the tray **and** a system notification.

- **Edge-triggered, with hysteresis.** Fire once per crossing. A device resting
  at 9% must not alert every poll — that is 180 alerts an hour. Re-arm a
  threshold only after the battery climbs back above it by a margin.
- **Only while discharging.** The user asked for warnings when the battery is
  draining; a clock charging up through 4% must not scream.
- **The in-app path must not depend on the system one.** If notification
  authorization is denied, the dialog still appears. Ask for authorization
  lazily — the first time a warning would fire, not at launch. A menu bar toy
  that demands notification permission on first run gets denied before the user
  knows what it wants.
- Trade-off flagged rather than decided away: a modal dialog steals focus, which
  is right at 5% and intrusive at 20%. Built as asked — dialog on all four — and
  worth revisiting by eye.

**The tray glyph.** The panel shows an emoji for the current state beside the
percentage and the ETA. This is the **panel**, not the menu bar item: that item
is a template image whose monochrome silhouette and offline variant are
load-bearing, and an emoji there would break both.

There is **no "battery charging" emoji in Unicode** — the battery family is
`\u{1F50B}` and `\u{1FAAB}`, and neither has a charging variant. Charging is
therefore shown with the plug, which is the closest thing that exists and reads
unambiguously next to a percentage:

| State                          | Glyph          |
| ------------------------------ | -------------- |
| Charging (raw reading rising)  | `\u{1F50C}` 🔌 |
| Discharging, 20% or above      | `\u{1F50B}` 🔋 |
| Discharging, below 20%         | `\u{1FAAB}` 🪫 |
| Discharging, below 10%         | `\u{1FAAB}` 🪫, with the text carrying the urgency |
| Not yet established            | no glyph — the percentage alone, and the ETA still estimating |

Urgency is carried by the surrounding text and colour, not by a second emoji:
there is no red variant of these glyphs, and stacking `\u{26A0}` beside them
reads as clutter rather than as escalation. The "not yet established" row is
deliberate — a glyph implying a verdict the trajectory has not reached yet is
the same lie as a confident ETA from two samples.

- [ ] **Step 1: Write the failing tests**

- `aFallingRawReadingReadsAsDischarging`
- `aRisingRawReadingReadsAsCharging`
- `aFlatReadingHoldsThePreviousVerdictRatherThanFlapping`
- `aRebootDiscardsTheHistory`
- `aDifferentDeviceDiscardsTheHistory`
- `aGapLongerThanTheWindowDiscardsTheHistory`
- `noEtaIsShownBeforeTheMinimumSpanIsObserved`
- `theEtaIsPercentOverTheObservedRate`
- `crossingTwentyPercentWarnsOnce`
- `sittingBelowAThresholdDoesNotWarnAgain`
- `recoveringAboveAThresholdRearmsIt`
- `chargingThroughAThresholdDoesNotWarn`
- `theDialogStillAppearsWhenNotificationsAreDenied`
- `theGlyphFollowsTheStateNotThePercentageAlone`

- [ ] **Step 2–4: fail, implement, green + mutate**

Mutations: level-trigger instead of edge-trigger; drop the hysteresis; warn
while charging; compute the slope on `bat` instead of `bat_raw`; keep history
across a reboot; show an ETA from two samples; make the dialog conditional on
notification authorization.

- [ ] **Step 5: Commit** — `feat: battery trajectory, threshold warnings and the tray glyph`

---

### Task 23: Stay quiet when macOS says the user is busy

**Files:**
- Create: `Sources/AwtrixConnectorsApp/FocusGate.swift`
- Modify: `Sources/AwtrixConnectorsApp/AppModel.swift`, `MenuPanel.swift`
- Test: `Tests/AwtrixConnectorsAppTests/`

This app **speaks out loud** on a thirty-minute schedule. Nothing currently
stops it telling a joke at three in the morning. A quiet window of its own would
duplicate what the system already knows, so the gate is macOS's own Focus state.

**What was established by probe, not assumed:**

- `~/Library/DoNotDisturb/DB/` — the file-based route every blog post
  recommends — is **TCC-protected**. Reading it answers `Operation not
  permitted` and would require Full Disk Access, which is an absurd ask for a
  menu bar toy. That route is closed.
- `INFocusStatusCenter` **works from an unsigned local build**: a bare binary
  reports `authorizationStatus` `notDetermined` and returns a non-nil
  `focusStatus.isFocused`. No entitlement, no signing, no Full Disk Access.

**The trap this creates, and the rule that closes it.** An unauthorized center
answers `isFocused == false` — the same answer as a genuinely idle Mac. Trusting
it would mean an app that believes no Focus is ever on and speaks at 3 a.m.
forever, silently and by construction. So:

- Request authorization once, and gate on `authorizationStatus == .authorized`.
- While not authorized, `isFocused` is **not evidence** and must not be read as
  permission to speak. Fall back to an explicit quiet window the user sets in
  the panel — hours, not guesses.
- Surface which of the two is in force. A user who denied the prompt should be
  able to see that the app is running on its own window rather than on the
  system's state.

**What the API can and cannot tell us.** `INFocusStatusCenter` reports *whether*
a Focus is active, never *which one*. Distinguishing Sleep from Work needs the
TCC-protected database, and that trade is not worth Full Disk Access. So the
rule is: **any active Focus silences the schedule.** If the user has set a
Focus at all, a clock making jokes is not what they asked for — and Sleep, the
case that prompted this, is covered by the same test.

**Four rules, the same shape as Task 20's:**

- Silence the **schedule**, not `maintain`. An outage of attention is not an
  outage of preparation, and the queue should be full when the user comes back.
- A manual "Run now" is never silenced. The user pressing a button IS the
  consent; refusing it would read as a broken button.
- The gate must not touch the failure counter in either direction.
- The state is not sticky: the moment Focus ends, the next tick runs normally.

- [ ] **Step 1: Write the failing tests**

- `anActiveFocusSilencesTheSchedule`
- `theScheduleResumesWhenFocusEnds`
- `anUnauthorizedCenterIsNotTreatedAsPermissionToSpeak`
- `theQuietWindowAppliesWhenFocusAuthorizationWasDenied`
- `aManualRunIsNeverSilenced`
- `maintenanceStillRunsDuringFocus`
- `aFocusPauseDoesNotAdvanceOrResetTheFailureCounter`
- `thePanelSaysWhichRuleIsInForce`

- [ ] **Step 2–4: fail, implement, green + mutate**

Mutations: read `isFocused` without checking authorization; silence `maintain`
too; silence the manual path; make the pause sticky until a run succeeds; treat
`.denied` as `.authorized`.

- [ ] **Step 5: Commit** — `feat: stay quiet while macOS reports a Focus`

---

### Task 24: Wait out the meeting, do not talk over it

**Files:**
- Create: `Sources/AwtrixConnectorsApp/MicrophoneGate.swift`
- Modify: `Sources/AwtrixConnectorsApp/AppModel.swift`, `MenuPanel.swift`
- Test: `Tests/AwtrixConnectorsAppTests/`

Speech and the clock's jingle both land in the room the user is talking in. If a
microphone is capturing, the app **waits** — it does not skip. A joke deferred
by twenty minutes is still a joke; one skipped is gone, and the anecdote was
already paid for in synthesis.

**`kAudioDevicePropertyDeviceIsRunningSomewhere` answers without any permission**
— we never open a stream or read a sample, so this costs no microphone access
and raises no TCC prompt. Probed and working.

**The trap the probe caught, which would otherwise have shipped as "the app
never speaks and nobody knows why".** On this machine the naive check —
*is any input device capturing* — answers **true right now, with no meeting in
progress**. Four inputs are present, and `Universal Audio Thunderbolt`, an
always-on audio interface, reports `capturing=true` permanently. A gate written
against that reading is a permanent mute.

So the rule is a **watched set of devices**, chosen by the user — not "any
device", and not "the default input" either, since a conferencing app does not
always take the default:

- Default watch set: **MacBook Pro Microphone** and **iPhone Microphone**. Those
  are the two a human actually talks into on this machine; the Thunderbolt
  interface and Serato's virtual input are excluded by construction rather than
  by a heuristic that has to be right.
- The panel lists every input the system reports, with the watched ones marked,
  so the set is visible and editable. A gate the user cannot inspect is a gate
  they will eventually fight.
- **Match by device UID, not by name.** Names are user-visible and unstable —
  "iPhone Microphone" appears and vanishes as the phone comes and goes, and two
  identical models collide. Store the UID with the name beside it for display,
  match on UID, and fall back to the name only when no UID matches.
- A watched device that is **absent** is simply not capturing. Its absence is
  not an error and must not disable the gate.
- **No launch baseline.** An earlier draft excluded devices already capturing at
  startup, to dodge the always-on interface; with an explicit watch set that
  heuristic is not only unnecessary but wrong — a watched microphone already
  capturing when the app launches means a meeting is already in progress, and
  the correct response is to hold, not to decide it is furniture.
- Show the verdict in the panel with the device that caused it. "Waiting: the
  microphone is in use (MacBook Pro Microphone)" is diagnosable; silence is not.

**Deferral, not suppression:**

- A scheduled run that arrives while the mic is hot is **held**, and released
  when capture stops — not dropped, and not counted as a failure.
- At most one run is held. A two-hour meeting must not queue four anecdotes and
  fire them in a burst the moment it ends.
- The jingle is part of the deferral. Pushing the banner without its sound, or
  the sound without the banner, is worse than waiting.
- A manual "Run now" is never held — the press is the consent, and the user can
  see the mic indicator in their own menu bar.
- `maintain` is never held: preparation makes no sound.

- [ ] **Step 1: Write the failing tests**

- `aWatchedDeviceCapturingAtLaunchIsAMeetingAlreadyInProgress`
- `anUnwatchedDeviceCapturingIsIgnoredHoweverLongItRuns`
- `aWatchedDeviceThatIsAbsentDoesNotDisableTheGate`
- `theWatchSetIsMatchedByUidNotByName`
- `aScheduledRunDuringAMeetingIsHeldNotDropped`
- `theHeldRunFiresWhenCaptureStops`
- `atMostOneRunIsHeldAcrossALongMeeting`
- `aHeldRunIsNotCountedAsAFailure`
- `aManualRunIsNeverHeld`
- `maintenanceIsNeverHeld`
- `thePanelNamesTheDeviceThatCausedTheWait`

- [ ] **Step 2–4: fail, implement, green + mutate**

Mutations: gate on every input rather than the watched set; match the watch set
by name instead of UID; treat an absent watched device as capturing; drop the
held run instead of releasing it; release more than one; count a held run as a
failure; hold the manual path.

- [ ] **Step 5: Commit** — `feat: hold speech while a microphone is capturing`

---

### Task 25: A voice per connector

**Files:**
- Modify: `Sources/AwtrixKit/Connectors/Connector.swift`, `AnecdoteConnector.swift`
- Modify: `Sources/AwtrixKit/Anecdotes/VoiceCaster.swift`
- Test: `Tests/AwtrixKitTests/VoiceCasterTests.swift`

`VoiceCaster` already assigns voices to speakers inside one anecdote. Giving
each connector its own narrator costs little and changes how the thing feels:
the weather is read by one character, a broken build announced by another.

- `Connector` gains a narrator voice, defaulting to the current one so nothing
  existing changes sound.
- The caster takes the connector's narrator as the voice for `narrator` lines,
  and keeps its existing per-speaker casting inside the text unchanged.
- The reserved female voice rule is not touched — a connector narrator must not
  steal the voice reserved for female speakers, or dialogue casting degrades.
- An unknown or missing voice falls back to the current default rather than
  failing the run. A connector naming a voice that was deleted from the pack
  directory should sound wrong, not break.

- [ ] **Step 1: Write the failing tests**

- `aConnectorsNarratorVoiceIsUsedForItsNarratorLines`
- `perSpeakerCastingInsideTheTextIsUnchanged`
- `aConnectorNarratorDoesNotConsumeTheReservedFemaleVoice`
- `anUnknownNarratorFallsBackRatherThanFailing`
- `connectorsWithoutANarratorSoundExactlyAsBefore`

- [ ] **Step 2–4: fail, implement, green + mutate**

- [ ] **Step 5: Commit** — `feat: each connector gets its own narrator`

---

### Task 26: The clock wears the weather

**Files:**
- Create: `Sources/AwtrixKit/Connectors/WeatherConnector.swift`, `Sources/AwtrixKit/Weather/OpenMeteoSource.swift`, `WeatherTheme.swift`
- Modify: `Sources/AwtrixKit/Device/AwtrixDevice.swift` (custom-app endpoint)
- Test: `Tests/AwtrixKitTests/WeatherThemeTests.swift`, `OpenMeteoSourceTests.swift`

The clock should show the weather where the user is — rain on the matrix when it
rains.

**The firmware has weather overlays built in.** `GET /api/settings` carries a
global `OVERLAY` key, and the device accepts exactly **`clear`, `rain`,
`snow`, `storm`, `thunder`, `drizzle`, `frost`** — enumerated by setting each
one on the real clock and reading it back, then restoring `clear`. An
unrecognised value is silently coerced to `clear`, so **validation is entirely
ours**: a typo produces no overlay and no error, which is the worst possible
failure to debug from the outside.

An earlier draft of this task proposed building rain out of a LaMetric catalogue
GIF plus the `Matrix` effect. That was wrong and it is recorded here so nobody
rebuilds it: the effects list (`Fade`, `MovingLine`, `Pacifica`, `Matrix` and
sixteen others, from `GET /api/effects`) is decorative and belongs to custom
apps, while `OVERLAY` is the real, literal, device-wide weather layer that
draws over everything on screen. Rain is one setting, not an animation we ship.

**`OVERLAY` is global device state, and that has consequences the task must
handle.** It is not scoped to an app, so this connector is writing a setting the
user can also change by hand:

- Read and remember the value that was there **before** the connector first set
  it, and restore it when the connector is disabled or the app quits. The plan's
  own constraint — the app removes what it created — covers settings as much as
  flash.
- Never write it when the weather has not changed. A repeated identical write is
  a needless flash cycle on a device that lives on a shelf for years.
- A user who sets an overlay by hand while the connector is on will have it
  overwritten at the next poll. Say so in the panel rather than letting it read
  as a bug.

**Temperature still wants a custom app** — the overlay draws weather, not
numbers — and that is where the effects list and a catalogue icon are legitimate.
Keep the two separate: the overlay is the weather, the custom app is the reading.

**The source: Open-Meteo, verified live.** No key, no signup, no account, no
dependency — a plain `URLSession` GET returning WMO `weather_code`, `is_day`,
`precipitation`, `temperature_2m`, `wind_speed_10m`. WeatherKit was not chosen
because it needs a paid developer account and a signed app, neither of which
this build has.

- `is_day` splits clear-sky into two themes; a clear night rendered as bright
  sun is the kind of wrongness that gets noticed immediately.
- The response's own `interval` is **900 seconds**. Poll every fifteen minutes
  and no faster — this is a free public API and the weather does not move
  quicker than its own update cadence.

**Location.** A desk clock does not travel, so coordinates in settings are the
default and CoreLocation is an optional convenience that fills them in once. The
framework and its permission prompt are not required for a value the user can
type, and asking for location access on first launch of a menu bar toy is how an
app gets denied everything.

**Where it renders.** A **custom app** in the clock's own loop, not a
notification: weather is ambient, and the loop is exactly the mechanism for
something that should be there when you glance at it. Notifications from the
anecdote connector overlay the loop and the two coexist without arbitration.

- [ ] **Step 1: Write the failing tests**

- `eachWmoGroupMapsToOneOfTheSixOverlaysTheFirmwareAccepts`
- `anUnknownWmoCodeFallsBackToClearRatherThanToAnInvalidOverlay`
- `theOverlayIsNotRewrittenWhenTheWeatherHasNotChanged`
- `thePriorOverlayIsRestoredWhenTheConnectorIsDisabled`
- `thePriorOverlayIsRestoredOnQuit`
- `clearSkyByDayAndByNightAreDifferentThemes`
- `theSourceIsNotPolledFasterThanItsOwnInterval`
- `aFailedWeatherFetchLeavesThePreviousOverlayInPlace`

- [ ] **Step 2–4: fail, implement, green + mutate**

Mutations: send an overlay name the firmware does not accept (it coerces to
`clear`, so only our own validation can catch it); ignore `is_day`; poll faster
than the interval; rewrite the overlay on every poll; forget the prior value so
nothing is restored; clear the overlay on a failed fetch.

- [ ] **Step 5: Commit** — `feat: mirror the local weather on the clock`

---

### Task 27: Restore the prototype's casting

**Files:**
- Modify: `Sources/AwtrixKit/Anecdotes/VoiceCaster.swift`
- Modify: `Sources/AwtrixKit/Connectors/AnecdoteConnector.swift` (composition)
- Test: `Tests/AwtrixKitTests/VoiceCasterTests.swift`

**A regression the user heard before anyone measured it: the app casts worse
than the prototype it was ported from.** Diagnosed against both sides.

Five voices are installed — `acolyte`, `arthas`, `batrak`, `crystal`, `peon`.
The prototype narrates with `arthas`, **reserves `crystal` for speakers it
detects as female**, and draws the remaining three plus the narrator for
everyone else. `Voice` in Swift declares **two** — `arthas` and `peon` — and the
default pool is `[.arthas, .peon]`.

Three consequences, all audible:

- Women speak in an orc grunt. The female rule was built, corpus-validated and
  approved by ear in the prototype, and never ported.
- Every third speaker wraps back to the narrator's own voice, so distinct
  characters sound like the same person.
- Three of the five installed voices never play at all.

The synthesis parameters are **not** implicated and should not be touched: both
sides send exactly `{"voice","text","out"}` and run on `speak.py`'s own
`INFERENCE` defaults. `SpeechText.prepare` is an improvement over the prototype,
not a regression — it fixes the trailing-stop tail. The casting is the whole
defect.

**The acceptance set already exists.** `prototype/test_gender.py` holds thirteen
cases pinning the female rule, including the traps that made it hard: `Я сила!`
(a noun that looks like a past-tense verb), `У меня сила воли` (the same noun in
a phrase), and a feminine verb describing a third person rather than the
speaker. Port those thirteen, do not invent new ones, and do not weaken any of
them — they are what the rule was validated against.

**The rule itself**, from the prototype: a speaker is female when, within two
tokens of a first-person pronoun, they use a feminine past-tense form (`-ла`,
`-лась`) that is not in the known-noun exclusion list. **A line carrying both a
feminine and a masculine signal decides nothing** — that is reported speech, and
guessing from it was a defect the prototype already fixed once.

**What was checked and is NOT broken, so this task does not go looking there.**
The pacing is faithful: `LEAD_ANNOUNCEMENT` 0.0, `LEAD_FIRST_LINE` 0.7,
`LEAD_BETWEEN_LINES` 0.25, `LEAD_LAUGHTER` 0.7 on both sides, and the Swift
`switch` produces the same sequence as the prototype's list assembly for every
body length, including the two-clip case where both readings happen to give
0.7. The laughter is faithful too — the same thresholds (12 words, 14 repeats,
breathing at 9), the same `4 + words / 8`, the same detached three-`ХА` tail,
the same three short variants chosen at random.

**The one piece never compared: the dialogue parser.** If the Swift parser
splits a joke into a different number of turns than `parse_turns` does, then
every pause constant can be identical and the pauses will still land in the
wrong places — indistinguishable by ear from broken pacing. This task settles it
with a parity check rather than by reading both implementations: take a corpus
of real anecdotes, run both parsers over it, and diff the turn splits. Any
divergence is either a defect to fix or a deliberate improvement to write down
— but it must not stay unknown, because it is the last place the port could have
silently changed how the thing sounds.

- [ ] **Step 1: Write the failing tests**

Port the thirteen from `prototype/test_gender.py`, plus:

- `theReservedFemaleVoiceIsNeverDrawnForAMaleOrUnknownSpeaker`
- `everyInstalledVoiceIsReachable`
- `aThirdSpeakerDoesNotReuseTheNarratorsVoiceWhileAnotherIsFree`
- `castingIsStableAcrossOneAnecdote`
- `theSwiftParserSplitsARealCorpusExactlyAsTheProtoypeDoes` (parity, driven from
  a fixture of real anecdotes; a divergence fails with both splits printed)

- [ ] **Step 2–4: fail, implement, green + mutate**

Mutations: put `crystal` back in the general pool; drop the two-token proximity
window; let a line with both signals decide; shrink the pool to two; make the
exclusion list empty.

- [ ] **Step 5: Commit** — `fix: cast the way the prototype does, female voice included`

---

### Task 28: Settings behind a gear, not in the way

**Files:**
- Modify: `Sources/AwtrixConnectorsApp/MenuPanel.swift`
- Create: `Sources/AwtrixConnectorsApp/SettingsSheet.swift`
- Modify: `Sources/AwtrixConnectorsApp/AppModel.swift` if the sheet needs state
- Test: `Tests/AwtrixConnectorsAppTests/`

The panel that opens on a click is for the two things a user reaches for daily —
is the clock alive, and run something now. Everything set once and forgotten
belongs behind a gear.

**What moves out of the panel:**

- **The device address field.** It saves as it is typed; there is nothing to
  confirm and nothing to press, so it has no business occupying a row in a menu
  that opens dozens of times a day.
- **"Remove icons this app uploaded."** An action taken once in the life of an
  installation, sitting next to one taken constantly.

**What replaces them:** a **gear button in the bottom-right corner of the
panel, with no label** — the icon alone. Clicking it opens the settings, and
the settings hold exactly those two things.

**Also in the panel: when the next anecdote is due, to the right of "Run
now".** The user asked for a time; the honest version is harder than a time.

By the time this ships, four separate mechanisms can hold or move the next run:
Task 15's failure backoff shortens the wait, Task 20 pauses the schedule while
the clock is unreachable, Task 23 silences it during a macOS Focus, and Task 24
holds it while a microphone is capturing. A label reading "next at 14:30" while
any of those is in force is a lie the user will act on.

So the label reports the **actual next attempt**, and when the schedule is held
it says what is holding it rather than naming an hour that will not arrive. It
follows the same clock the scheduler sleeps on — not a separately computed
guess, which would drift the moment a backoff engages.

**Four rules, because a settings surface is where UI defects hide:

- The address still **saves as it is typed**, exactly as it does today. Moving a
  control must not quietly add a save step the user has to discover.
- The panel must not grow taller for the gear. It goes in the corner of what is
  already there, not on a row of its own.
- Opening the settings must not stop the schedule, the poll, or a run in
  flight. A settings sheet is a view, not a mode.
- Removing icons keeps its confirmation and its result line **inside the
  settings**, not thrown back to the panel the user has just left.

This supersedes the earlier amendment that removed the icon action outright.
The machinery — `UploadedIconStore`, the record written at the upload site,
`AwtrixDevice.removeIcon` — was never deleted, so this is a relocation, and the
global constraint "the app removes what it created" is met again once it lands.

- [ ] **Step 1: Write the failing tests**

- `theMainPanelHoldsNeitherTheAddressFieldNorTheIconAction`
- `theGearOpensTheSettings`
- `theSettingsHoldTheAddressFieldAndTheIconAction`
- `theAddressStillSavesAsItIsTyped`
- `openingTheSettingsDoesNotDisturbAScheduledRun`
- `theIconRemovalResultIsShownInTheSettings`
- `thePanelSaysWhenTheNextAnecdoteIsDue`
- `theDueTimeFollowsABackoffRatherThanTheNominalInterval`
- `aHeldScheduleSaysWhatIsHoldingItInsteadOfNamingATime`
- `aDisabledConnectorNamesNoNextTime`

- [ ] **Step 2–4: fail, implement, green + mutate**

Mutations: leave the field in the panel as well; make the address save only on
submit; let the gear tear down the schedule; report the removal result to the
panel instead of the settings.

- [ ] **Step 5: Commit** — `feat: put the address and the icon action behind a gear`

---

### Task 29: The menu opens on the panel, and a replay says something

**Files:**
- Modify: `Sources/AwtrixConnectorsApp/AppModel.swift`, `MenuPanel.swift`
- Test: `Tests/AwtrixConnectorsAppTests/`

Two consequences of Tasks 28 and 19 that only became visible once both existed.

**The menu no longer reliably opens on the panel.** `settingsIsOpen` and
`historyIsOpen` both survive the window closing, so clicking away while in
History and clicking back returns to History. The two surfaces are consistent
with each other, which is how it got here — and consistent is not the same as
right. A menu bar item is clicked to answer "is the clock alive, and what is
next"; returning to a list of old jokes answers a question nobody asked. Both
surfaces reset when the window closes, so the first screen is always the panel.

**A replay is silent.** `deliver`'s result is discarded on purpose — the run
line must not be written to, because a replay is not a run and Task 15's counter
must not move. But that leaves "Play again" against an unreachable clock doing
nothing at all, with no explanation. **This branch has already shipped that exact
defect once**: the user pressed "Run now", saw nothing for 37 seconds, and
reported the button as broken. Do not ship it twice.

So a replay reports its own outcome, **in the History surface**, not in the
panel's run line. Whatever shape it takes, the discarded-result decision stays:
the run line and the failure counter are untouched.

- [ ] **Step 1: Write the failing tests**

- `closingTheWindowReturnsTheMenuToThePanel`
- `theHistorySurfaceDoesNotSurviveAWindowClose`
- `theSettingsSurfaceDoesNotSurviveAWindowClose`
- `aReplayReportsItsOutcomeInTheHistory`
- `aFailedReplayIsVisibleRatherThanSilent`
- `aReplayOutcomeNeverReachesTheRunLine`
- `aReplayStillDoesNotMoveTheFailureCounter`

- [ ] **Step 2–4: fail, implement, green + mutate**

Mutations: keep either flag across the close; write the replay outcome to the
run line; drop the outcome entirely; let a failed replay advance the counter.

- [ ] **Step 5: Commit** — `fix: open on the panel, and say how a replay went`

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
