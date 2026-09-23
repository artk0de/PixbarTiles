# TC002 Battery Over Root ADB Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or dinopowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Draw a real battery line (charge, charging state, discharge ETA) for a TC002 clock by reading the firmware's own battery figures out of the `zkgui` process memory over the device's open root ADB backdoor.

**Architecture:** A minimal ADB-over-TCP client (`ADBClient`) framed over an injected byte stream pushes a hand-built static ARMv7 helper (`pct-batt`) that reads a window of `/proc/<pid>/mem` and streams it back. `UlanziBattery` resolves the `zkgui` pid and the `libzkgui.so` load base each poll, runs the helper, parses three `int32`s (charging / percent / millivolts) and plausibility-gates them into an `UlanziBatterySample`. A percent-native `UlanziBatteryTrajectory` — **not** the raw-ADC `BatteryTrajectory` — turns the sample series into a `BatteryReading` (direction straight off the charging flag, ETA from a percent-slope fit). `UlanziClockHealth` owns the poll; `AppModel.batteryLine` renders it through the existing `BatteryLine`.

**Tech Stack:** Swift 6.2, SwiftPM, macOS 26, `Network.framework` (`NWConnection`) for the real TCP stream, Python 3 (host-only) for the ELF generator.

**Spec:** `docs/superpowers/specs/2026-09-23-tc002-battery-over-adb-design.md` — the plan argues from it; executors read both. **Note:** the spec's original unit 4 ("reuse the existing `BatteryTrajectory`") was falsified against the code and corrected in the spec — TC002 gets its own percent-native trajectory (units 4 and 5 below). The code, not the spec's first draft, is the authority here.

## Global Constraints

Every task's requirements implicitly include these — copied verbatim from the spec and the project rules:

- **Read-only on the device.** No memory writes, no register pokes, no config changes, no touching the `usb_device` / `usb_host` / `usb_null` sysfs files. The helper only `open`/`lseek`/`read`/`write(stdout)`/`exit`.
- **Degrade to no line, never a wrong one.** Every failure branch — port unreachable, unknown `appVer`, pid/base not found, helper push/run fails, values fail the gate — yields `nil`, and the panel shows the last-known charge per the existing rule. A wrong number is worse than none.
- **No voltage→percent curve for the TC002.** The cell has different characteristics; the firmware's computed percent is the only honest number. We never map millivolts to percent.
- **`appVer` gating.** Offsets are build-specific. Only firmware `appVer` `1.1.1` has a known offset (`+0x732ee8`); any other version yields `nil`.
- **Plausibility gate.** Percent in `0...100`, millivolts in `2000...4500`, else no reading.
- **Field layout (appVer 1.1.1), libzkgui load-relative:** `+0x732ee8` charging/on-USB (`1`/`0`), `+0x732eec` percent, `+0x732ef0` millivolts. Three adjacent little-endian `int32`s; read as a single 12-byte window. Load base = the start address of the `r-xp … libzkgui.so` line in `/proc/<pid>/maps`.
- **Swift 6.2, macOS 26, SwiftPM.** Bundle via `Scripts/bundle.sh [debug|release]`.
- **Commit messages in English**, each ending with:

  ```text
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```

### tea-rags impact enrichment (rerank: blastRadius)

| File | Owner | Churn | Age | Bugs | Role |
|---|---|---|---|---|---|
| `Sources/PixelClockTilesApp/AppModel.swift` | artk0de (100%) | 16 commits | 0d | healthy | 3106-line / 109-method **god module** — touch ONLY `batteryLine` (fanIn 2, leaf); keep new code OUT of `poll` (fanOut 7, hotspot) |
| `Sources/PixelClockTilesApp/UlanziClockHealth.swift` | artk0de (100%) | 1 commit | quiet | — | the correct poll seam |
| `Sources/PixelClockKit/Device/BatteryTrajectory.swift` | artk0de (100%) | 1 commit | 2d | — | houses `BatteryReading` (reused unchanged); the raw-ADC `BatteryTrajectory` is **not** reused |
| `Sources/PixelClockTilesApp/ClockStatusBlock.swift` | artk0de (100%) | 4 commits | 2d | — | `BatteryLine` text/glyph/colour (reused unchanged) |
| NEW: `Sources/PixelClockKit/Ulanzi/ADBClient.swift` | — (new) | — | — | — | leaf, testable over a fake stream |
| NEW: `Sources/PixelClockKit/Ulanzi/UlanziBattery.swift` | — (new) | — | — | — | testable over a fake `ADB` |
| NEW: `Sources/PixelClockKit/Ulanzi/UlanziBatteryTrajectory.swift` | — (new) | — | — | — | pure value logic |
| NEW: `Scripts/make_pct_batt.py`, `Sources/PixelClockKit/Resources/pct-batt` | — (new) | — | — | — | generator + prebuilt ELF |

Sequencing consequence: leaf/testable units first (ADBClient, generator, UlanziBattery, trajectory), the thin wiring into the god module last and confined to `batteryLine` + a mirror of the existing `makeUlanziDevice` factory. No task edits `AppModel.poll`.

---

## File Structure

- `Sources/PixelClockKit/Ulanzi/ADBClient.swift` — `ADB` protocol, `ADBClient`, `ADBStream` protocol, wire-frame codec, and the `NWConnection`-backed `NWADBStream`.
- `Sources/PixelClockKit/Ulanzi/UlanziBattery.swift` — `UlanziBatterySample`, `UlanziBattery` (pid/base resolution, helper run, parse, gate, offset table).
- `Sources/PixelClockKit/Ulanzi/UlanziBatteryTrajectory.swift` — `UlanziBatteryTrajectory` (sample series → `BatteryReading`).
- `Scripts/make_pct_batt.py` — the ELF generator (productized `mkelf_mem.py`), reading params from a request file.
- `Sources/PixelClockKit/Resources/pct-batt` — the committed prebuilt ELF bytes (ships inside `PixelClockTiles_PixelClockKit.bundle`; `bundle.sh` already copies that bundle).
- `Sources/PixelClockTilesApp/UlanziClockHealth.swift` — gains the battery poll and `lastKnownBattery`.
- `Sources/PixelClockTilesApp/AppModel.swift` — a `makeUlanziBattery` factory (mirrors `makeUlanziDevice`) and a two-line change to `batteryLine`. Nothing else.
- Tests: `Tests/PixelClockKitTests/ADBClientTests.swift`, `UlanziBatteryTests.swift`, `UlanziBatteryTrajectoryTests.swift`, `PctBattResourceTests.swift`; `Tests/PixelClockTilesAppTests/UlanziClockHealthBatteryTests.swift`, and the `batteryLine` case in the existing AppModel suite.
- Host test for the generator: `Scripts/tests/test_make_pct_batt.py` (pytest-free, plain `assert` + `python3 -m unittest` runnable).

---

### Task 1: `ADBClient` — ADB wire framing over an injected byte stream

The protocol is proven in the spike (`adbsh.py`, `adbpush.py`); this productizes the framing so it is testable with a fake stream and never touches a device in tests. Per-operation connect (fresh `CNXN` each `shell`/`push`) mirrors the spike exactly and sidesteps stream multiplexing.

**Files:**
- Create: `Sources/PixelClockKit/Ulanzi/ADBClient.swift`
- Test: `Tests/PixelClockKitTests/ADBClientTests.swift`

**Interfaces:**
- Produces:
  - `public protocol ADBStream: Sendable { func write(_ bytes: Data) async throws; func readExactly(_ count: Int) async throws -> Data; func close() async }`
  - `public protocol ADB: Sendable { func shell(_ command: String) async throws -> Data; func push(_ bytes: Data, to path: String, mode: Int) async throws }`
  - `public struct ADBClient: ADB { public init(connect: @escaping @Sendable () async throws -> ADBStream) }`
  - `public enum ADBError: Error, Equatable { case handshakeRefused, remoteClosed, syncFailed(String) }`
- Consumes: nothing (leaf).

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import PixelClockKit

/// A fully scripted byte stream: hands back canned device bytes on read, and
/// records everything the client writes so the frames can be asserted.
private actor ScriptedStream: ADBStream {
    private var toRead: Data
    private(set) var written = Data()
    init(_ canned: Data) { self.toRead = canned }
    func write(_ bytes: Data) async throws { written.append(bytes) }
    func readExactly(_ count: Int) async throws -> Data {
        guard toRead.count >= count else { throw ADBError.remoteClosed }
        let head = toRead.prefix(count)
        toRead.removeFirst(count)
        return Data(head)
    }
    func close() async {}
    func writtenBytes() -> Data { written }
}

/// Builds one ADB frame the way the device would: 24-byte header
/// (cmd, arg0, arg1, len, payload-checksum, cmd^0xFFFFFFFF) + payload.
private func frame(_ cmd: UInt32, _ a0: UInt32, _ a1: UInt32, _ payload: Data = Data()) -> Data {
    var d = Data()
    func le(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    let checksum = payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
    le(cmd); le(a0); le(a1); le(UInt32(payload.count)); le(checksum); le(cmd ^ 0xFFFFFFFF)
    d.append(payload)
    return d
}

private let A_CNXN: UInt32 = 0x4E58_4E43
private let A_OKAY: UInt32 = 0x5941_4B4F
private let A_WRTE: UInt32 = 0x4554_5257
private let A_CLSE: UInt32 = 0x4553_4C43

@Test func shellCollectsWriteFramesUntilClose() async throws {
    // Device answers: CNXN (handshake), then two WRTE chunks, then CLSE.
    var canned = frame(A_CNXN, 0x0100_0000, 256 * 1024, Data("device::\0".utf8))
    canned += frame(A_WRTE, 1, 1, Data("Battery: ".utf8))
    canned += frame(A_WRTE, 1, 1, Data("90%\n".utf8))
    canned += frame(A_CLSE, 1, 1)
    let stream = ScriptedStream(canned)
    let client = ADBClient(connect: { stream })

    let out = try await client.shell("echo hi")

    #expect(String(decoding: out, as: UTF8.self) == "Battery: 90%\n")
    // The client must have opened the shell service by name.
    let written = await stream.writtenBytes()
    #expect(written.range(of: Data("shell:echo hi\0".utf8)) != nil)
    // And sent a CNXN first (the handshake precedes the OPEN).
    #expect(written.prefix(4) == withUnsafeBytes(of: A_CNXN.littleEndian) { Data($0) })
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ADBClientTests`
Expected: FAIL — `ADBClient`, `ADB`, `ADBStream`, `ADBError` are not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

public protocol ADBStream: Sendable {
    func write(_ bytes: Data) async throws
    /// Reads exactly `count` bytes, or throws `ADBError.remoteClosed` if the
    /// stream ends first.
    func readExactly(_ count: Int) async throws -> Data
    func close() async
}

public protocol ADB: Sendable {
    func shell(_ command: String) async throws -> Data
    func push(_ bytes: Data, to path: String, mode: Int) async throws
}

public enum ADBError: Error, Equatable {
    case handshakeRefused
    case remoteClosed
    case syncFailed(String)
}

/// A minimal ADB-over-TCP client. One fresh connection per operation: connect,
/// `CNXN` handshake, one service `OPEN`, drive it, close. This is exactly what
/// the spike proved against the TC002's open, AUTH-less adbd, and it keeps the
/// framing a pure function of the byte stream so tests script it.
public struct ADBClient: ADB {
    private static let cnxn: UInt32 = 0x4E58_4E43
    private static let open: UInt32 = 0x4E45_504F
    private static let okay: UInt32 = 0x5941_4B4F
    private static let clse: UInt32 = 0x4553_4C43
    private static let wrte: UInt32 = 0x4554_5257
    private static let auth: UInt32 = 0x4855_5441
    private static let maxData: UInt32 = 256 * 1024

    private let connect: @Sendable () async throws -> ADBStream

    public init(connect: @escaping @Sendable () async throws -> ADBStream) {
        self.connect = connect
    }

    public func shell(_ command: String) async throws -> Data {
        let stream = try await connect()
        defer { Task { await stream.close() } }
        try await handshake(stream)
        try await send(stream, Self.open, 1, 0, Data("shell:\(command)\0".utf8))
        return try await collect(stream)
    }

    public func push(_ bytes: Data, to path: String, mode: Int) async throws {
        let stream = try await connect()
        defer { Task { await stream.close() } }
        try await handshake(stream)
        try await send(stream, Self.open, 1, 0, Data("sync:\0".utf8))
        let (cmd, remoteId, _, _) = try await recv(stream)
        guard cmd == Self.okay else { throw ADBError.syncFailed("sync not acked") }

        var sync = Data()
        let arg = Data("\(path),\(mode)".utf8)
        sync += Data("SEND".utf8) + le32(UInt32(arg.count)) + arg
        for chunk in bytes.chunked(65536) {
            sync += Data("DATA".utf8) + le32(UInt32(chunk.count)) + chunk
        }
        sync += Data("DONE".utf8) + le32(UInt32(Date().timeIntervalSince1970))
        try await send(stream, Self.wrte, 1, remoteId, sync)

        // The sync-layer response arrives as a WRTE frame: "OKAY" or "FAIL".
        var status = Data()
        while status.count < 8 {
            let (c, _, _, payload) = try await recv(stream)
            if c == Self.wrte {
                status += payload
                try await send(stream, Self.okay, 1, remoteId)
            } else if c == Self.clse {
                break
            }
        }
        guard status.prefix(4) == Data("OKAY".utf8) else {
            throw ADBError.syncFailed(String(decoding: status, as: UTF8.self))
        }
    }

    // MARK: framing

    private func handshake(_ stream: ADBStream) async throws {
        try await send(stream, Self.cnxn, 0x0100_0000, Self.maxData, Data("host::\0".utf8))
        let (cmd, _, _, _) = try await recv(stream)
        if cmd == Self.auth { throw ADBError.handshakeRefused }
        guard cmd == Self.cnxn else { throw ADBError.handshakeRefused }
    }

    /// Collects WRTE payloads until CLSE, acking each with the adb-layer OKAY.
    private func collect(_ stream: ADBStream) async throws -> Data {
        var out = Data()
        while true {
            let (cmd, arg0, _, payload) = try await recv(stream)
            if cmd == Self.wrte {
                out += payload
                try await send(stream, Self.okay, 1, arg0)
            } else if cmd == Self.clse {
                return out
            }
        }
    }

    private func send(
        _ stream: ADBStream, _ cmd: UInt32, _ a0: UInt32, _ a1: UInt32, _ payload: Data = Data()
    ) async throws {
        let checksum = payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        var header = le32(cmd) + le32(a0) + le32(a1)
        header += le32(UInt32(payload.count)) + le32(checksum) + le32(cmd ^ 0xFFFF_FFFF)
        try await stream.write(header + payload)
    }

    private func recv(_ stream: ADBStream) async throws -> (UInt32, UInt32, UInt32, Data) {
        let header = try await stream.readExactly(24)
        let cmd = header.le32(at: 0)
        let a0 = header.le32(at: 4)
        let a1 = header.le32(at: 8)
        let length = Int(header.le32(at: 12))
        let payload = length > 0 ? try await stream.readExactly(length) : Data()
        return (cmd, a0, a1, payload)
    }

    private func le32(_ v: UInt32) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }
}

extension Data {
    fileprivate func le32(at offset: Int) -> UInt32 {
        self[startIndex + offset ..< startIndex + offset + 4]
            .reduce(into: (UInt32(0), UInt32(0))) { acc, byte in
                acc.0 |= UInt32(byte) << (8 * acc.1); acc.1 += 1
            }.0
    }
    fileprivate func chunked(_ size: Int) -> [Data] {
        stride(from: startIndex, to: endIndex, by: size).map {
            Data(self[$0 ..< Swift.min($0 + size, endIndex)])
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ADBClientTests`
Expected: PASS.

- [ ] **Step 5: Add the real `NWConnection` stream (integration, not unit-tested)**

Append to `ADBClient.swift`. This is the only device-touching code in the file; the framing above is what the tests pin.

```swift
import Network

/// The real byte stream: a TCP connection with a receive buffer so
/// `readExactly` can serve arbitrary lengths from NWConnection's chunked
/// deliveries. Not unit-tested — validated on-device (Task 3's smoke test
/// exercises it end to end).
public actor NWADBStream: ADBStream {
    private let connection: NWConnection
    private var buffer = Data()
    private var closed = false

    public static func connect(host: String, port: UInt16 = 5555) async throws -> NWADBStream {
        let stream = NWADBStream(host: host, port: port)
        try await stream.start()
        return stream
    }

    private init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    private func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: cont.resume()
                case .failed(let error): cont.resume(throwing: error)
                default: break
                }
            }
            connection.start(queue: .global())
        }
    }

    public func write(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    public func readExactly(_ count: Int) async throws -> Data {
        while buffer.count < count {
            if closed { throw ADBError.remoteClosed }
            let chunk = try await receiveChunk()
            if chunk.isEmpty { closed = true } else { buffer.append(chunk) }
        }
        let head = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(head)
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
                data, _, isComplete, error in
                if let error { cont.resume(throwing: error) }
                else if let data { cont.resume(returning: data) }
                else if isComplete { cont.resume(returning: Data()) }
                else { cont.resume(returning: Data()) }
            }
        }
    }

    public func close() async { connection.cancel() }
}
```

- [ ] **Step 6: Run the whole kit suite to confirm nothing regressed**

Run: `swift test --filter PixelClockKitTests`
Expected: PASS (the new `NWADBStream` compiles; framing tests still green).

- [ ] **Step 7: Commit**

```bash
git add Sources/PixelClockKit/Ulanzi/ADBClient.swift Tests/PixelClockKitTests/ADBClientTests.swift
git commit -m "feat: ADB-over-TCP client for the TC002 root backdoor

CNXN/OPEN/WRTE/OKAY/CLSE framing plus the sync SEND push, over an
injected byte stream so the framing is tested without a device. The
real NWConnection stream is the only device-touching code.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `pct-batt` — the on-device memory reader (static ARMv7 ELF)

Productizes the spike's `mkelf_mem.py`. The one change from the proven spike: parameters (address, length, `/proc/<pid>/mem` path) are read from a request file `/tmp/pct-req` at run time instead of baked in at build time, so the single shipped binary serves any pid, any load address. The `open(path)`/`lseek`/`read`/`write`/`exit` core is byte-identical to the spike that dumped 24590 bytes off the live device.

**Files:**
- Create: `Scripts/make_pct_batt.py`
- Create: `Sources/PixelClockKit/Resources/pct-batt` (generated, committed)
- Test: `Scripts/tests/test_make_pct_batt.py`

**Interfaces:**
- Produces: the request-file contract consumed by Task 3 — `/tmp/pct-req` is `u32 address` (LE) + `u32 length` (LE) + NUL-terminated path; the helper writes exactly `length` bytes of that path's contents from `address` to stdout.
- Consumes: nothing.

**Request-file layout the ELF parses (Task 3 must write exactly this):**

```text
offset 0: u32 address   (little-endian, the absolute VA to lseek to)
offset 4: u32 length    (little-endian, bytes to read; 12 for the battery window)
offset 8: path bytes... NUL-terminated  ("/proc/<pid>/mem")
```

- [ ] **Step 1: Write the failing generator test**

```python
# Scripts/tests/test_make_pct_batt.py
# Run: python3 -m unittest Scripts.tests.test_make_pct_batt
import struct, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GEN = ROOT / "Scripts" / "make_pct_batt.py"


class MakePctBatt(unittest.TestCase):
    def _build(self):
        with tempfile.NamedTemporaryFile(suffix=".elf", delete=False) as f:
            out = Path(f.name)
        subprocess.run([sys.executable, str(GEN), str(out)], check=True)
        return out.read_bytes()

    def test_elf32_arm_header(self):
        elf = self._build()
        self.assertEqual(elf[:4], b"\x7fELF")          # magic
        self.assertEqual(elf[4], 1)                      # ELFCLASS32
        self.assertEqual(elf[5], 1)                      # little-endian
        e_type, e_machine = struct.unpack_from("<HH", elf, 16)
        self.assertEqual(e_type, 2)                      # ET_EXEC
        self.assertEqual(e_machine, 40)                  # EM_ARM

    def test_opens_the_request_file_path(self):
        elf = self._build()
        self.assertIn(b"/tmp/pct-req\x00", elf)

    def test_syscall_immediates_present(self):
        # __NR_open(5), lseek(19), read(3), write(4), exit(1) loaded into r7.
        elf = self._build()
        for nr in (5, 19, 3, 4, 1):
            insn = struct.pack("<I", 0xE3A07000 | nr)    # mov r7, #nr
            self.assertIn(insn, elf, f"missing mov r7,#{nr}")

    def test_committed_bytes_match_generator(self):
        # The shipped artifact must be exactly what the generator emits, so a
        # stale prebuilt binary is caught in CI.
        shipped = (ROOT / "Sources/PixelClockKit/Resources/pct-batt").read_bytes()
        self.assertEqual(shipped, self._build())


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 -m unittest Scripts.tests.test_make_pct_batt`
Expected: FAIL — `Scripts/make_pct_batt.py` does not exist.

- [ ] **Step 3: Write the generator**

Port `mkelf_mem.py` (job tmp `adb/mkelf_mem.py`) verbatim for the ELF header, the `mov_imm`/`cmp_imm`/`add_imm`/`movw`/`movt`/`svc` encoders (the bit25 immediate-form fix is already correct there), and the `open`/`lseek`/`read`/`write`/`exit` core. Replace the baked-parameter prologue with a request-file prologue: `open("/tmp/pct-req", O_RDONLY)` → `read` into a bss scratch → load `address` from `[buf]`, `length` from `[buf+4]`, compute the path pointer `buf+8` — then run the identical open/lseek/read/write loop against those registers.

```python
#!/usr/bin/env python3
"""Emit the static ARMv7 ELF `pct-batt`.

It reads three parameters from /tmp/pct-req — u32 address, u32 length, a
NUL-terminated path — then open(path), lseek(address), read(length),
write(stdout), exit. No toolchain: hand-encoded A32 + a hand-built ELF32
header, exactly as the spike's mkelf_mem.py proved on the device. The only
change from that spike is the request-file prologue: parameters are read at
run time so one shipped binary serves any pid and any load address.

Usage: make_pct_batt.py OUT
"""
import struct
import sys

BASE = 0x10000
EHSIZE, PHSIZE = 52, 32
CODE_OFF = EHSIZE + PHSIZE
ENTRY = BASE + CODE_OFF
REQBUF = BASE + 0x1000          # bss: request file is read here
DATABUF = BASE + 0x2000         # bss: the memory window is read here


def mov_imm(rd, imm12): return 0xE3A00000 | (rd << 12) | (imm12 & 0xFFF)
def add_imm(rd, rn, imm12): return 0xE2800000 | (rn << 16) | (rd << 12) | (imm12 & 0xFFF)
def mov_reg(rd, rm): return (0xE << 28) | (0x1A << 20) | (rd << 12) | rm
def movw(rd, imm16): return 0xE3000000 | ((imm16 >> 12) << 16) | (rd << 12) | (imm16 & 0xFFF)
def movt(rd, imm16): return 0xE3400000 | ((imm16 >> 12) << 16) | (rd << 12) | (imm16 & 0xFFF)
def ldr_imm(rt, rn, off12): return 0xE5900000 | (rn << 16) | (rt << 12) | (off12 & 0xFFF)
def svc(): return 0xEF000000


def load32(rd, value):
    return [movw(rd, value & 0xFFFF), movt(rd, (value >> 16) & 0xFFFF)]


def main():
    out = sys.argv[1]
    req_path = b"/tmp/pct-req\0"
    insns = []

    # open("/tmp/pct-req", O_RDONLY) — path address patched after layout.
    open_req_index = len(insns)
    insns.append(None)                       # add r0, pc, #(reqpath - pc)
    insns.append(mov_imm(1, 0))              # O_RDONLY
    insns.append(mov_imm(7, 5))              # __NR_open
    insns.append(svc())
    insns.append(mov_reg(6, 0))              # r6 = req fd

    # read(req_fd, REQBUF, 256)
    insns.append(mov_reg(0, 6))
    insns += load32(1, REQBUF)
    insns.append(mov_imm(2, 0x100))          # 256 bytes is ample
    insns.append(mov_imm(7, 3))              # __NR_read
    insns.append(svc())

    # r4 = address = [REQBUF+0]; r5 = length = [REQBUF+4]; r9 = &path = REQBUF+8
    insns += load32(3, REQBUF)
    insns.append(ldr_imm(4, 3, 0))           # r4 = address
    insns.append(ldr_imm(5, 3, 4))           # r5 = length
    insns.append(add_imm(9, 3, 8))           # r9 = path pointer

    # open(path, O_RDONLY)
    insns.append(mov_reg(0, 9))
    insns.append(mov_imm(1, 0))
    insns.append(mov_imm(7, 5))
    insns.append(svc())
    insns.append(mov_reg(6, 0))              # r6 = mem fd

    # lseek(mem_fd, address, SEEK_SET)
    insns.append(mov_reg(0, 6))
    insns.append(mov_reg(1, 4))              # offset = address
    insns.append(mov_imm(2, 0))              # SEEK_SET
    insns.append(mov_imm(7, 19))             # __NR_lseek
    insns.append(svc())

    # read(mem_fd, DATABUF, length)
    insns.append(mov_reg(0, 6))
    insns += load32(1, DATABUF)
    insns.append(mov_reg(2, 5))              # count = length
    insns.append(mov_imm(7, 3))
    insns.append(svc())

    # write(1, DATABUF, r0)  — r0 is the byte count read
    insns.append(mov_reg(2, 0))
    insns.append(mov_imm(0, 1))              # stdout
    insns += load32(1, DATABUF)
    insns.append(mov_imm(7, 4))              # __NR_write
    insns.append(svc())

    # exit(0)
    insns.append(mov_imm(0, 0))
    insns.append(mov_imm(7, 1))              # __NR_exit
    insns.append(svc())

    n = len(insns)
    reqpath_off = n * 4                       # request-file path sits after code
    # Patch the adr: add r0, pc, #(reqpath - (entry + open_req_index*4 + 8))
    adr_pc = open_req_index * 4 + 8
    insns[open_req_index] = add_imm(0, 15, reqpath_off - adr_pc)

    code = b"".join(struct.pack("<I", w) for w in insns) + req_path
    filesz = CODE_OFF + len(code)
    memsz = 0x3000                            # code + two bss scratch pages

    ehdr = struct.pack(
        "<16sHHIIIIIHHHHHH",
        b"\x7fELF\x01\x01\x01\x00" + b"\x00" * 8,
        2, 40, 1, ENTRY, EHSIZE, 0, 0x5000400, EHSIZE, PHSIZE, 1, 0, 0, 0,
    )
    phdr = struct.pack("<IIIIIIII", 1, 0, BASE, BASE, filesz, memsz, 7, 0x1000)
    with open(out, "wb") as f:
        f.write(ehdr + phdr + code)
    print(f"wrote {out}: {filesz}B")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Generate the committed artifact**

Run: `python3 Scripts/make_pct_batt.py Sources/PixelClockKit/Resources/pct-batt`
Expected: prints `wrote …: NB`; the file exists.

- [ ] **Step 5: Run the generator test to verify it passes**

Run: `python3 -m unittest Scripts.tests.test_make_pct_batt`
Expected: PASS (all four cases, including `test_committed_bytes_match_generator`).

- [ ] **Step 6: On-device smoke test (REQUIRED — host CI cannot execute ARMv7)**

This is the acceptance gate for the hand-assembled reader: the golden-byte test proves the generator is stable, but only the device proves the machine code runs. With the TC002 reachable (adb at `192.168.1.72:5555`) and its Battery tool on screen so the fields are populated, from the job's spike tooling:

```text
# push the helper and a request reading the 12-byte battery window
python3 Scripts/make_pct_batt.py /tmp/pct-batt
adbpush.py 192.168.1.72 /tmp/pct-batt /tmp/pct-batt 100755
# resolve pid + libzkgui r-xp base by hand, build /tmp/pct-req = addr,len,path,
# push it, then:
adbsh.py 192.168.1.72 '/tmp/pct-batt' --raw | xxd
```

Expected: 12 bytes whose three little-endian `int32`s are a plausible `charging`, `percent` (0–100), `millivolts` (2000–4500), matching the on-screen `Battery: N%, V:Mmv` and flipping the charging word when USB is unplugged. If the bytes are wrong, the machine code — not the Swift — is at fault; fix `make_pct_batt.py`, regenerate, re-run Step 5, and repeat. Record the observed bytes in the commit message.

- [ ] **Step 7: Commit**

```bash
git add Scripts/make_pct_batt.py Scripts/tests/test_make_pct_batt.py Sources/PixelClockKit/Resources/pct-batt
git commit -m "feat: pct-batt, a param-driven /proc/pid/mem reader for ARMv7

Static ELF built with no toolchain (hand-encoded A32 + ELF32 header).
Reads address/length/path from /tmp/pct-req so one binary serves any pid
and load address. Golden bytes pin the generator; validated on-device
against the live battery window.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `UlanziBattery` — pid/base resolution, run, parse, gate

The testable brain. Given an `ADB` and the helper bytes, one poll resolves the pid and load base, pushes the helper and a request, runs it, and gates the 12 bytes into a sample. All text work in Swift; the offset table is keyed by `appVer`.

**Files:**
- Create: `Sources/PixelClockKit/Ulanzi/UlanziBattery.swift`
- Test: `Tests/PixelClockKitTests/UlanziBatteryTests.swift`

**Interfaces:**
- Consumes: `ADB` (Task 1).
- Produces:
  - `public struct UlanziBatterySample: Sendable, Equatable { public let percent: Int; public let charging: Bool; public let millivolts: Int; public let at: Date }`
  - `public struct UlanziBattery: Sendable { public init(adb: ADB, helper: Data); public func read(appVersion: String?, at now: Date) async -> UlanziBatterySample? }`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import PixelClockKit

/// A fake ADB that answers scripted shell output by command substring and
/// records pushes. No device, no framing.
private actor FakeADB: ADB {
    var shellAnswers: [(match: String, out: Data)]
    private(set) var pushed: [(path: String, bytes: Data)] = []
    init(_ answers: [(String, Data)]) { self.shellAnswers = answers.map { ($0.0, $0.1) } }
    func shell(_ command: String) async throws -> Data {
        for a in shellAnswers where command.contains(a.match) { return a.out }
        return Data()
    }
    func push(_ bytes: Data, to path: String, mode: Int) async throws {
        pushed.append((path, bytes))
    }
    func pushes() -> [(path: String, bytes: Data)] { pushed }
}

/// 12 reader bytes: charging=1, percent=90, mV=3149.
private func window(charging: UInt32, percent: UInt32, mv: UInt32) -> Data {
    var d = Data()
    for v in [charging, percent, mv] { withUnsafeBytes(of: v.littleEndian) { d.append(Data($0)) } }
    return d
}

private let procList = Data("/proc/1\n/init\u{0}\n\n/proc/812\n/bin/zkgui\u{0}\n\n".utf8)
private let maps = Data("""
43e87000-445b4000 r-xp 00000000 b3:07 1207  /res/lib/libzkgui.so
445b4000-445ba000 rw-p 0072d000 b3:07 1207  /res/lib/libzkgui.so
""".utf8)

@Test func readsGatedSampleFromResolvedPidAndBase() async throws {
    let adb = FakeADB([
        ("/proc/", procList),               // the pid sweep
        ("maps", maps),                      // cat /proc/812/maps
        ("/tmp/pct-batt", window(charging: 1, percent: 90, mv: 3149)),
    ])
    let battery = UlanziBattery(adb: adb, helper: Data("ELF-BYTES".utf8))
    let at = Date(timeIntervalSince1970: 1_000)

    let sample = await battery.read(appVersion: "1.1.1", at: at)

    #expect(sample == UlanziBatterySample(percent: 90, charging: true, millivolts: 3149, at: at))
    // The request must ask for base(0x43e87000) + 0x732ee8 = 0x445b9ee8, len 12.
    let req = await adb.pushes().first { $0.path == "/tmp/pct-req" }!.bytes
    #expect(req.prefix(4) == Data([0xF4, 0x9E, 0x5B, 0x44]))        // address LE
    #expect(req[4..<8] == Data([0x0C, 0x00, 0x00, 0x00]))          // length 12 LE
    #expect(req.range(of: Data("/proc/812/mem\0".utf8)) != nil)
}

@Test func unknownFirmwareYieldsNoReading() async {
    let adb = FakeADB([])
    let battery = UlanziBattery(adb: adb, helper: Data())
    #expect(await battery.read(appVersion: "2.0.0", at: Date()) == nil)
    #expect(await battery.read(appVersion: nil, at: Date()) == nil)
}

@Test func implausibleValuesAreRejected() async {
    func read(_ w: Data) async -> UlanziBatterySample? {
        let adb = FakeADB([("/proc/", procList), ("maps", maps), ("/tmp/pct-batt", w)])
        return await UlanziBattery(adb: adb, helper: Data()).read(appVersion: "1.1.1", at: Date())
    }
    #expect(await read(window(charging: 0, percent: 101, mv: 3000)) == nil)   // percent > 100
    #expect(await read(window(charging: 0, percent: 50, mv: 1500)) == nil)    // mV < 2000
    #expect(await read(Data([0x01, 0x02])) == nil)                            // short read
}

@Test func missingProcessYieldsNoReading() async {
    let adb = FakeADB([("/proc/", Data("/proc/1\n/init\u{0}\n\n".utf8))])   // no zkgui
    #expect(await UlanziBattery(adb: adb, helper: Data()).read(appVersion: "1.1.1", at: Date()) == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter UlanziBatteryTests`
Expected: FAIL — `UlanziBattery`, `UlanziBatterySample` undefined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

public struct UlanziBatterySample: Sendable, Equatable {
    public let percent: Int
    public let charging: Bool
    public let millivolts: Int
    public let at: Date

    public init(percent: Int, charging: Bool, millivolts: Int, at: Date) {
        self.percent = percent
        self.charging = charging
        self.millivolts = millivolts
        self.at = at
    }
}

/// Reads the TC002's firmware battery figures out of the zkgui process memory
/// over ADB. Read-only: it pushes a reader and a request, runs the reader, and
/// parses three int32s. Every failure returns nil — a wrong number is worse
/// than none.
public struct UlanziBattery: Sendable {
    /// libzkgui load-relative offset of the charging int32, per firmware
    /// appVer. percent is +4, millivolts +8; the window is 12 bytes. Offsets
    /// are build-specific, so an unlisted version reads nothing.
    static let offsets: [String: UInt32] = ["1.1.1": 0x0073_2EF4]
    private static let windowLength = 12

    private let adb: any ADB
    private let helper: Data

    public init(adb: any ADB, helper: Data) {
        self.adb = adb
        self.helper = helper
    }

    public func read(appVersion: String?, at now: Date) async -> UlanziBatterySample? {
        guard let appVersion, let offset = Self.offsets[appVersion] else { return nil }
        do {
            guard let pid = try await resolvePid() else { return nil }
            guard let base = try await resolveBase(pid: pid) else { return nil }
            let address = base &+ offset

            try await adb.push(helper, to: "/tmp/pct-batt", mode: 0o755)
            try await adb.push(request(address: address, path: "/proc/\(pid)/mem"),
                               to: "/tmp/pct-req", mode: 0o644)
            let out = try await adb.shell("/tmp/pct-batt")
            guard out.count >= Self.windowLength else { return nil }

            let charging = le32(out, 0) != 0
            let percent = Int(le32(out, 4))
            let millivolts = Int(le32(out, 8))
            guard (0...100).contains(percent), (2000...4500).contains(millivolts) else { return nil }
            return UlanziBatterySample(
                percent: percent, charging: charging, millivolts: millivolts, at: now
            )
        } catch {
            return nil
        }
    }

    /// The pid whose cmdline names zkgui. mksh + stripped busybox: no grep/head,
    /// so the sweep echoes each /proc/N path then its cmdline (NUL-joined argv),
    /// and the matching is done here.
    private func resolvePid() async throws -> Int? {
        let out = try await adb.shell("for d in /proc/[0-9]*; do echo $d; cat $d/cmdline; echo; done")
        var pid: Int?
        for line in out.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let text = String(decoding: line, as: UTF8.self)
            if text.hasPrefix("/proc/") {
                pid = Int(text.dropFirst("/proc/".count))
            } else if text.contains("zkgui"), let found = pid {
                return found
            }
        }
        return nil
    }

    /// The start address of the r-xp libzkgui.so mapping — the load base the
    /// offset is relative to.
    private func resolveBase(pid: Int) async throws -> UInt32? {
        let out = try await adb.shell("cat /proc/\(pid)/maps")
        for line in String(decoding: out, as: UTF8.self).split(separator: "\n") {
            guard line.contains("libzkgui.so"), line.contains("r-xp") else { continue }
            let start = line.split(separator: "-").first.map(String.init) ?? ""
            if let base = UInt32(start, radix: 16) { return base }
        }
        return nil
    }

    private func request(address: UInt32, path: String) -> Data {
        var d = Data()
        withUnsafeBytes(of: address.littleEndian) { d.append(Data($0)) }
        withUnsafeBytes(of: UInt32(Self.windowLength).littleEndian) { d.append(Data($0)) }
        d.append(Data(path.utf8))
        d.append(0)
        return d
    }

    private func le32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[base + $1]) << (8 * $1)) }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter UlanziBatteryTests`
Expected: PASS (all four tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PixelClockKit/Ulanzi/UlanziBattery.swift Tests/PixelClockKitTests/UlanziBatteryTests.swift
git commit -m "feat: UlanziBattery reads the firmware battery from zkgui memory

Resolves the zkgui pid and libzkgui r-xp base over ADB, runs pct-batt
against base+0x732ee8, and gates the three int32s (0..100 percent,
2000..4500 mV). appVer-keyed offsets; any other firmware reads nothing.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `UlanziBatteryTrajectory` — sample series → `BatteryReading`

The percent-native trajectory. Direction comes straight off the explicit charging flag (no rise/fall inference, no half-hour lag), `shownPercent` is the firmware percent unchanged (already smoothed — no ADC ratchet to defend against), and the discharge ETA is a least-squares slope over the trailing discharging run, extrapolated to 0%. The raw-ADC `BatteryTrajectory` is deliberately **not** reused — it stores `BatterySample.raw`, maps it with `map(raw, 475, 665, …)`, and infers direction because AWTRIX has no charging field.

**Files:**
- Create: `Sources/PixelClockKit/Ulanzi/UlanziBatteryTrajectory.swift`
- Test: `Tests/PixelClockKitTests/UlanziBatteryTrajectoryTests.swift`

**Interfaces:**
- Consumes: `UlanziBatterySample` (Task 3), `BatteryReading` / `BatteryDirection` (existing, `BatteryTrajectory.swift`).
- Produces:
  - `public struct UlanziBatteryTrajectory: Sendable { public init(); public mutating func accept(_ sample: UlanziBatterySample); public var reading: BatteryReading? { get } }`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import PixelClockKit

private func sample(_ percent: Int, _ charging: Bool, _ minutes: Double) -> UlanziBatterySample {
    UlanziBatterySample(percent: percent, charging: charging, millivolts: 3800,
                        at: Date(timeIntervalSince1970: minutes * 60))
}

@Test func directionComesStraightOffTheFlag() {
    var t = UlanziBatteryTrajectory()
    t.accept(sample(90, true, 0))
    #expect(t.reading?.direction == .charging)
    #expect(t.reading?.shownPercent == 90)
    #expect(t.reading?.timeRemaining == nil)          // no countdown while charging
}

@Test func dischargeUnderMinimumSpanHasNoEstimate() {
    var t = UlanziBatteryTrajectory()
    t.accept(sample(80, false, 0))
    t.accept(sample(79, false, 5))                     // 5 min < minimum span
    #expect(t.reading?.direction == .discharging)
    #expect(t.reading?.timeRemaining == nil)
}

@Test func steadyDischargeEstimatesTimeToEmpty() {
    var t = UlanziBatteryTrajectory()
    // 2% lost per hour, watched for two hours: from 76% that is 38 h to empty.
    t.accept(sample(80, false, 0))
    t.accept(sample(78, false, 60))
    t.accept(sample(76, false, 120))
    let remaining = t.reading?.timeRemaining
    #expect(remaining != nil)
    #expect(abs(remaining! - 38 * 3600) < 30 * 60)     // within half an hour
    #expect(t.reading?.direction == .discharging)
    #expect(t.reading?.shownPercent == 76)
}

@Test func plugInClearsTheEstimateAndTheDischargeRun() {
    var t = UlanziBatteryTrajectory()
    t.accept(sample(80, false, 0))
    t.accept(sample(78, false, 60))
    t.accept(sample(78, true, 120))                    // plugged in
    #expect(t.reading?.direction == .charging)
    #expect(t.reading?.timeRemaining == nil)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter UlanziBatteryTrajectoryTests`
Expected: FAIL — `UlanziBatteryTrajectory` undefined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Turns a series of TC002 battery samples into the panel's reading.
///
/// Percent-native, because the TC002 hands over the firmware's own computed
/// percent and an explicit charging flag — strictly better data than the
/// AWTRIX raw ADC, which is why none of `BatteryTrajectory`'s raw-curve or
/// direction-inference machinery is wanted here. Direction is the flag; the
/// only thing fitted is the discharge rate.
public struct UlanziBatteryTrajectory: Sendable {
    /// How long a discharge must be watched before a rate is put on it. Below
    /// this, an estimate is two points wearing a number.
    static let minimumSpan: TimeInterval = 15 * 60
    /// How long samples are kept.
    static let retention: TimeInterval = 24 * 60 * 60

    private var samples: [UlanziBatterySample] = []

    public init() {}

    public mutating func accept(_ sample: UlanziBatterySample) {
        samples.append(sample)
        let cutoff = sample.at.addingTimeInterval(-Self.retention)
        samples.removeAll { $0.at < cutoff }
    }

    public var reading: BatteryReading? {
        guard let latest = samples.last else { return nil }
        let direction: BatteryDirection = latest.charging ? .charging : .discharging
        return BatteryReading(
            percent: latest.percent,
            shownPercent: latest.percent,
            direction: direction,
            timeRemaining: direction == .discharging ? estimate(to: latest) : nil
        )
    }

    /// Seconds to 0%, from a least-squares fit over the trailing discharging
    /// run, or nil while too little has been watched or the trend is not a
    /// fall. Charging → nil upstream.
    private func estimate(to latest: UlanziBatterySample) -> TimeInterval? {
        // The run since the battery was last on a charger.
        let run = trailingDischargeRun()
        guard let first = run.first, run.count >= 2 else { return nil }
        let span = latest.at.timeIntervalSince(first.at)
        guard span >= Self.minimumSpan else { return nil }

        // slope = d(percent)/d(second), fitted; a discharge is negative.
        let xs = run.map { $0.at.timeIntervalSince(first.at) }
        let ys = run.map { Double($0.percent) }
        let n = Double(run.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        let cov = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let varX = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        guard varX > 0 else { return nil }
        let slope = cov / varX
        guard slope < 0 else { return nil }             // not actually falling
        return Double(latest.percent) / -slope
    }

    /// Samples from just after the last charging reading to the end — the
    /// current discharge, uncontaminated by the charge that preceded it.
    private func trailingDischargeRun() -> [UlanziBatterySample] {
        if let lastCharge = samples.lastIndex(where: { $0.charging }) {
            return Array(samples[(lastCharge + 1)...])
        }
        return samples
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter UlanziBatteryTrajectoryTests`
Expected: PASS (all four tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/PixelClockKit/Ulanzi/UlanziBatteryTrajectory.swift Tests/PixelClockKitTests/UlanziBatteryTrajectoryTests.swift
git commit -m "feat: percent-native battery trajectory for the TC002

Direction straight off the firmware charging flag, shownPercent the
firmware percent unchanged, discharge ETA a least-squares slope to 0%.
Does not reuse the raw-ADC BatteryTrajectory, whose curve and direction
inference exist only because AWTRIX reports no charging state.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Wire the poll into `UlanziClockHealth` and the panel

The thin wiring, landing last and confined to the seam. `UlanziClockHealth` gains the poll and exposes `lastKnownBattery`; `AppModel` gains a `makeUlanziBattery` factory (a mirror of the existing `makeUlanziDevice`) and a two-line `batteryLine` change. Nothing touches `AppModel.poll`. The ELF ships inside the kit resource bundle, which `bundle.sh` already copies — no `bundle.sh` change; a resource-resolution test guards it.

**Files:**
- Modify: `Sources/PixelClockTilesApp/UlanziClockHealth.swift`
- Modify: `Sources/PixelClockTilesApp/AppModel.swift:500` (add stored `makeUlanziBattery`), `:681`/`:720` (init param + assignment), `:741` and `:2539` (pass `battery:`), `:1021` (wire the factory), `:1604-1611` (`batteryLine`)
- Create: `Tests/PixelClockTilesAppTests/UlanziClockHealthBatteryTests.swift`
- Create: `Tests/PixelClockKitTests/PctBattResourceTests.swift`
- Add a `batteryLine`-for-TC002 case to the existing AppModel suite.

**Interfaces:**
- Consumes: `UlanziBattery`, `UlanziBatteryTrajectory`, `UlanziBatterySample` (Tasks 3–4), `ADBClient` / `NWADBStream` (Task 1), `BatteryReading` / `BatteryLine` (existing).
- Produces:
  - `UlanziClockHealth.init(clockId:name:device:battery:)` — now takes `battery: UlanziBattery?`.
  - `UlanziClockHealth.lastKnownBattery: BatteryReading?`.
  - `AppModel`'s `makeUlanziBattery: @MainActor (ClockRecord) -> UlanziBattery?` injected factory.

- [ ] **Step 1: Write the failing resource test**

```swift
// Tests/PixelClockKitTests/PctBattResourceTests.swift
import Foundation
import Testing
@testable import PixelClockKit

@Test func pctBattShipsInTheKitBundleAsAnElf() throws {
    let url = try #require(
        KitResources.bundle.url(forResource: "pct-batt", withExtension: nil),
        "pct-batt is not in the kit resource bundle — check .process copied it"
    )
    let bytes = try Data(contentsOf: url)
    #expect(bytes.prefix(4) == Data([0x7F, 0x45, 0x4C, 0x46]))     // \x7fELF
    #expect(bytes.count > 100)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter PctBattResourceTests`
Expected: FAIL — the resource is not yet resolvable (or, if `.process` mangled a no-extension binary, the magic assert fails; in that case switch the target to a `.copy("Resources/pct-batt")` rule in `Package.swift` and re-run).

- [ ] **Step 3: Confirm the resource resolves**

`Sources/PixelClockKit/Resources/pct-batt` already exists from Task 2 and the target already declares `resources: [.process("Resources")]`. Run the test:

Run: `swift test --filter PctBattResourceTests`
Expected: PASS. (If it does not, apply the `.copy` fallback noted in Step 2, then re-run.)

- [ ] **Step 4: Write the failing health test**

```swift
// Tests/PixelClockTilesAppTests/UlanziClockHealthBatteryTests.swift
import Foundation
import Testing
import PixelClockKit
@testable import PixelClockTilesApp

/// A transport that answers /getBase with a fixed appVer, so the health's
/// identity poll succeeds and hands the version to the battery read.
private struct StubTransport: Transport {
    let appVer: String
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = Data("{\"appVer\":\"\(appVer)\",\"devSn\":\"TC-1\"}".utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

/// A fake ADB feeding one plausible battery window so the trajectory produces
/// a reading through the health.
private actor OneShotADB: ADB {
    func shell(_ command: String) async throws -> Data {
        if command.contains("/proc/") && command.contains("cmdline") {
            return Data("/proc/812\n/bin/zkgui\u{0}\n\n".utf8)
        }
        if command.contains("maps") {
            return Data("43e87000-445b4000 r-xp 0 b3:07 1 /res/lib/libzkgui.so\n".utf8)
        }
        // the reader: charging=0, percent=73, mV=3600
        return Data([0, 0, 0, 0, 73, 0, 0, 0, 0x10, 0x0E, 0, 0])
    }
    func push(_ bytes: Data, to path: String, mode: Int) async throws {}
}

@MainActor
@Test func aTc002HealthReadsABatteryReadingThroughItsPoll() async {
    let device = UlanziDevice(host: "192.168.1.72", transport: StubTransport(appVer: "1.1.1"))
    let battery = UlanziBattery(adb: OneShotADB(), helper: Data("ELF".utf8))
    let health = UlanziClockHealth(
        clockId: UUID(), name: "Desk", device: device, battery: battery)

    _ = await health.poll(at: Date(timeIntervalSince1970: 1_000))

    #expect(health.isOnline)
    #expect(health.lastKnownBattery?.shownPercent == 73)
    #expect(health.lastKnownBattery?.direction == .discharging)
}
```

- [ ] **Step 5: Run to verify it fails**

Run: `swift test --filter UlanziClockHealthBatteryTests`
Expected: FAIL — `UlanziClockHealth.init` has no `battery:` and no `lastKnownBattery`.

- [ ] **Step 6: Extend `UlanziClockHealth`**

```swift
@MainActor
final class UlanziClockHealth: @unchecked Sendable {
    enum Answering: Equatable {
        case notAsked
        case answering
        case unreachable
    }

    let clockId: UUID
    let name: String
    private(set) var answering: Answering = .notAsked
    private let device: UlanziDevice
    private let battery: UlanziBattery?
    private var trajectory = UlanziBatteryTrajectory()

    init(clockId: UUID, name: String, device: UlanziDevice, battery: UlanziBattery?) {
        self.clockId = clockId
        self.name = name
        self.device = device
        self.battery = battery
    }

    var isOnline: Bool { answering == .answering }

    /// The battery as the last poll left it — nil until a poll has read one, or
    /// for a firmware/adb path that never answers. The panel keeps showing the
    /// last known charge across a blip, so this is not cleared on a failed read.
    private(set) var lastKnownBattery: BatteryReading?

    /// One poll: identity, then — if the firmware version is one whose battery
    /// offset is known — a battery read fed into the trajectory. Read-only,
    /// and every battery failure is silent: the line just does not update.
    func poll(at now: Date) async -> BatteryWarning? {
        do {
            let identity = try await device.identity()
            answering = .answering
            if let battery,
               let sample = await battery.read(appVersion: identity.appVersion, at: now) {
                trajectory.accept(sample)
                lastKnownBattery = trajectory.reading
            }
        } catch {
            answering = .unreachable
        }
        return nil
    }
}
```

- [ ] **Step 7: Wire the factory and the panel in `AppModel`**

Add the stored factory beside `makeUlanziDevice` (near line 500):

```swift
    private let makeUlanziBattery: @MainActor (ClockRecord) -> UlanziBattery?
```

Add the init parameter (beside the `makeUlanziDevice` parameter, ~line 681) and its assignment (~line 720):

```swift
        makeUlanziBattery: @MainActor @escaping (ClockRecord) -> UlanziBattery?,
```
```swift
        self.makeUlanziBattery = makeUlanziBattery
```

Pass `battery:` at both construction sites (lines 741 and 2539):

```swift
                    ulanziHealths[clock.id] = UlanziClockHealth(
                        clockId: clock.id, name: clock.name, device: device,
                        battery: makeUlanziBattery(clock)
                    )
```

Wire the real factory at the composition root (beside `makeUlanziDevice`, ~line 1021):

```swift
            makeUlanziBattery: { clock in
                guard
                    let helperURL = KitResources.bundle.url(
                        forResource: "pct-batt", withExtension: nil),
                    let helper = try? Data(contentsOf: helperURL)
                else { return nil }
                let host = clock.address
                let adb = ADBClient(connect: { try await NWADBStream.connect(host: host) })
                return UlanziBattery(adb: adb, helper: helper)
            },
```

Change `batteryLine` (lines 1604–1611) to consult the TC002 health first — a clock is in exactly one of the two health maps, so this is a fall-through, not a merge:

```swift
    func batteryLine(of clock: ClockRecord) -> String? {
        if let ulanzi = ulanziHealths[clock.id] {
            return BatteryLine.text(for: ulanzi.lastKnownBattery)
        }
        return BatteryLine.text(for: healths[clock.id]?.monitor.lastKnownBattery)
    }
```

Every other place that constructs `AppModel` for a test must pass the new
factory. The minimal default is `makeUlanziBattery: { _ in nil }` — the TC002
battery line stays nil, exactly today's behaviour, so existing tests are
unaffected. Grep the app tests for `makeUlanziDevice:` and add
`makeUlanziBattery:` beside each.

- [ ] **Step 8: Add a `batteryLine`-renders-the-TC002-reading case**

In the existing AppModel suite (beside the current `batteryLine` coverage), assert that a TC002 clock whose health has a reading renders through `BatteryLine`. Construct `AppModel` with `makeUlanziBattery` returning a `UlanziBattery` over the `OneShotADB`-style fake, poll, then:

```swift
    #expect(model.batteryLine(of: tc002Clock) == "73%")   // discharging, no ETA yet
```

(Percent-only tail because a single sample is under the minimum span — the honest transient. The exact string tracks `BatteryLine.text`; if a trend has accrued it reads `"73% · estimating…"`, so drive it with one sample for determinism.)

- [ ] **Step 9: Run the full suite**

Run: `swift test`
Expected: PASS — the new tests green, the existing AWTRIX battery / status / reachability suites untouched and still passing.

- [ ] **Step 10: Build the bundle and confirm the helper ships**

Run: `./Scripts/bundle.sh debug`
Then: `ls build/PixelClockTiles.app/Contents/Resources/PixelClockTiles_PixelClockKit.bundle/pct-batt`
Expected: the file exists inside the copied kit bundle (no `bundle.sh` change was needed).

- [ ] **Step 11: On-device acceptance (REQUIRED)**

Point the running app at the TC002 (`192.168.1.72`), enable the Battery tool on the clock, and confirm the panel draws a percent and a charging glyph, that unplugging USB flips the glyph within a poll or two, and that a discharge ETA appears once the minimum span has been watched. This is the end-to-end gate the unit tests cannot cover (real ADB, real memory, real firmware).

- [ ] **Step 12: Commit**

```bash
git add Sources/PixelClockTilesApp/UlanziClockHealth.swift Sources/PixelClockTilesApp/AppModel.swift \
        Tests/PixelClockTilesAppTests/UlanziClockHealthBatteryTests.swift \
        Tests/PixelClockKitTests/PctBattResourceTests.swift
git commit -m "feat: draw the TC002 battery line from the ADB memory read

UlanziClockHealth polls UlanziBattery, feeds the percent-native
trajectory, and exposes lastKnownBattery; AppModel.batteryLine renders
it through the existing BatteryLine. A makeUlanziBattery factory mirrors
makeUlanziDevice; nothing touches AppModel.poll. The helper ships in the
kit bundle bundle.sh already copies.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- ADBClient (spec unit 1) → Task 1.
- pct-batt reader + generator + committed bytes (spec unit 2) → Task 2.
- UlanziBattery pid/base/parse/gate + appVer table (spec unit 3) → Task 3.
- Percent-native trajectory → BatteryReading (spec unit 4, corrected) → Task 4.
- Wiring into UlanziClockHealth + AppModel.batteryLine (spec unit 5) → Task 5.
- Degradation branches (spec "Error handling") → Task 3 gate tests + Task 5 default `nil` factory.
- Read-only, appVer gating, plausibility gate (Global Constraints) → enforced in Tasks 2–3, tested in Task 3.
- Ships without a `bundle.sh` change (kit resource bundle) → Task 5 Steps 1–3, 10.

**Placeholder scan:** No TBD/TODO; every code step carries real code; the two on-device steps (Task 2 Step 6, Task 5 Step 11) are explicit manual gates, named as such because host CI cannot execute ARMv7 or reach the device.

**Type consistency:** `ADB`/`ADBStream`/`ADBClient` (Task 1) consumed unchanged in Tasks 3, 5. `UlanziBatterySample` produced in Task 3, consumed in Task 4. `UlanziBatteryTrajectory.reading: BatteryReading?` consumed by `UlanziClockHealth.lastKnownBattery` in Task 5. `UlanziClockHealth.init(clockId:name:device:battery:)` signature matches both AppModel construction sites and the health test. Offset `0x732ee8` and window length `12` consistent across spec, Task 2 request layout, Task 3 arithmetic, and the Task 3 address assertion (`0x445b9ee8`).
