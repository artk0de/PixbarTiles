# TC002 battery over root adb — design

Status: design · 2026-09-23

## Problem

The panel draws a battery line for every clock that reports one. The TC002
reports none: its stock HTTP API has no battery endpoint (confirmed against the
device and the atomicstack HTTP-API notes), so `AppModel.batteryLine` returns
nil for a TC002 and the clock shows no charge, no charging state, no estimate.

The TC002 does have a 3600 mAh cell, and the firmware reads and displays it. The
value is simply not exposed over the network.

## What was measured (2026-09-23, device at 192.168.1.72, firmware appVer 1.1.1)

Every claim here was seen on the device, not inferred.

- `adbd` answers on TCP `5555` as **root with no AUTH handshake** — the open
  backdoor documented by atomicstack. A hand-built ADB `CNXN`/`OPEN`/`WRTE`/
  `OKAY` client connected and ran shells; the `sync:` SEND service pushed files.
- There is **no** `/sys/class/power_supply`. The SoC SAR ADC
  (`/sys/class/mstar/sar`) reads four channels (258 / 332 / 1 / 45) that do **not**
  track the battery — the value comes from the LED micro-controller over the
  `/dev/ttyS1` UART, owned by `zkgui` (`McuManager::queryBatteryPower`).
- The firmware's own reading, from `logcat` while the Battery tool was on screen:
  `Battery: 90%, V:3149mv, bars=4, charging=1 (USB=1)`. 3149 mV at 90% is not a
  Li-ion curve — this cell has different characteristics, so **no voltage→percent
  curve of ours can be correct**. The firmware's computed percent is the only
  honest number.
- The reading lives in **`libzkgui.so`'s writable segment** (static storage, not
  the heap), as three adjacent `int32`s, right before the `"/dev/ttyS1"` string —
  i.e. inside `McuManager`'s own state:

  | Address (this boot) | libzkgui load-relative offset | field | value |
  | --- | --- | --- | --- |
  | `0x445b9ef4` | `+0x732ef4` | charging / on-USB (1/0) | 1 |
  | `0x445b9ef8` | `+0x732ef8` | percent | 90 |
  | `0x445b9efc` | `+0x732efc` | millivolts | 3149 |

  The load-relative offset is the stable fact; the absolute address depends on
  where the loader mapped the library.
- The field is **live off-screen**: unplugging USB flipped `+0x732ef4` from 1 to
  0 while nothing but our reader touched the process. `McuManager` /
  `BatteryMonitor` update it continuously (they drive the low-battery LED and
  auto-sleep, which cannot depend on a tool being on screen). So a background poll
  reads fresh data.
- `/proc/<pid>/mem` is **readable by root without `PTRACE_ATTACH`** on this
  kernel — a plain `lseek`+`read` returned the pages.
- `/tmp` is a 16 MB tmpfs, wiped on reboot. The `zkgui` pid and the libzkgui load
  address are **not** stable across reboots and must be resolved at run time.

## Non-goals

- No voltage→percent curve for the TC002 (wrong by construction — different
  cell). We read the firmware's percent.
- No writes to the device's memory or registers, ever. Read-only.
- No second UART client. `/dev/ttyS1` is owned by `zkgui`; a competing reader
  risks the MCU-update protocol that shares it.
- No firmware flashing, no persistence on the device beyond a throwaway `/tmp`
  helper.

## Architecture

Five units, each independently testable.

### 1. `ADBClient` (PixelClockKit)

A minimal ADB-over-TCP client — the protocol is already proven in the spike.

- `connect(host:)` — TCP to `<host>:5555`, `CNXN` handshake. No AUTH path (the
  device never asks; if it does, fail cleanly and the feature disables).
- `shell(_ command:) -> Data` — `OPEN shell:<cmd>`, collect `WRTE` until `CLSE`.
- `push(_ bytes:to:mode:)` — the `sync:` SEND stream (SEND / DATA / DONE / OKAY).
- Pure framing over an injected byte transport, so tests drive it with a fake
  socket and never touch a device.

Interface: given a host and bytes/commands, returns bytes. Depends on: a
`Transport` (real `NWConnection`/socket in the app, a fake in tests).

### 2. `pct-batt` — the on-device reader (a static ARMv7 ELF)

Deliberately dumb, so it is stable across firmware the offset table still
matches. It reads its parameters from a request file rather than argv (argv
parsing in hand-written machine code is where bugs live):

- Request file `/tmp/pct-req`: `u32 address`, `u32 length`, then a
  NUL-terminated path (`/proc/<pid>/mem`).
- The reader: `open("/tmp/pct-req")` → read → `open(path)` → `lseek(address)` →
  `read(length)` → write to stdout → exit.

It is emitted by `Scripts/make_pct_batt.py` (raw ELF + hand-encoded A32; no
toolchain — the host has only arm64 Apple clang). The committed artifact is the
generator **and** the prebuilt `Resources/pct-batt` bytes, so the app bundles a
binary it does not build. The reader carries no offsets and no pid — all of that
is computed by unit 3 and handed in through the request file, so the same binary
serves any pid, any load address, any field layout.

### 3. `UlanziBattery` (PixelClockKit) — the read logic

The testable brain. Given an `ADBClient`, for one poll:

1. Resolve the `zkgui` pid: shell `ls -d /proc/[0-9]*`, read each `cmdline`,
   match `/bin/zkgui`. (Text work in Swift, not asm.)
2. Resolve the libzkgui load base: shell `cat /proc/<pid>/maps`, take the
   `r-xp … libzkgui.so` line's start address.
3. Compute `address = base + 0x732ef4`, `length = 12`.
4. Ensure `pct-batt` is present (push if a probe run fails — `/tmp` is volatile),
   then write `/tmp/pct-req` and run it.
5. Parse the 12 bytes → `charging: Bool`, `percent: Int`, `millivolts: Int`.
6. **Plausibility gate**: `0…100` percent, `2000…4500` mV, else treat as no
   reading. A wrong number is worse than none.

Offsets live in one table keyed by firmware `appVer`; `1.1.1` is the only entry.
Any other version → no reading (the panel says nothing rather than a lie). The
`appVer` comes from the existing `/getBase` identity call.

Interface: `read() async -> UlanziBatterySample?` — one poll's raw fact
(`percent`, `charging`, `millivolts`, `at`), not a rendered reading. It is
deliberately NOT a `BatteryReading`: the firmware percent is a point sample, and
a discharge estimate is a function of the SERIES, which is unit 4's job.
Depends on: `ADBClient`, the offset table.

### 4. `UlanziBatteryTrajectory` (PixelClockKit) — series → reading

The AWTRIX `BatteryTrajectory` is **not reused**, and the code is why. It is
built on the raw ADC: it stores `BatterySample.raw`, maps it with the firmware's
`map(raw, 475, 665, 0, 100)` (`rawAtEmpty = 475`), and INFERS the direction from
rise/fall windows — the whole trend machine exists precisely because the AWTRIX
`/api/stats` carries no charging field. Its `record(_:at:)` takes a `DeviceStats`
that has no `percent`-native, charging-bearing shape to hand it. Feeding a
firmware percent in as a raw would corrupt every threshold and the 0% floor.

TC002 has strictly better data — a firmware-computed percent and an EXPLICIT
charging flag — so it gets a small percent-native trajectory instead:

- `accept(_ sample: UlanziBatterySample)` appends to a bounded, thinned series.
- `reading -> BatteryReading?` builds the panel's reading:
  - `direction` = `sample.charging ? .charging : .discharging` — from the flag,
    no inference, no half-hour lag.
  - `shownPercent` = `percent` unchanged (the firmware already smooths; there is
    no ADC ratchet to defend against).
  - `timeRemaining` = a least-squares percent-slope fit over the trailing
    discharging run, extrapolated to 0%, or nil until a minimum span is watched.
    Charging → nil (no countdown for something filling up), exactly as
    `BatteryLine.trend` already expects.

`BatteryReading` and `BatteryLine` are reused untouched — the reading enters the
same rendering the AWTRIX line does, so the percentage, the charging glyph and
the `~N h left` tail all come from the existing code. `AppModel.batteryLine`
stops being nil for a TC002 whose series has produced a reading.

### 5. Wiring into the panel

`UlanziClockHealth` (not `AppModel.poll` — the hotspot god-method) owns a
`UlanziBattery` and a `UlanziBatteryTrajectory`. Each poll calls
`UlanziBattery.read()`, feeds any sample to the trajectory, and holds
`trajectory.reading`. `AppModel.batteryLine` consults the TC002 health's reading
for a `.ulanziTC002` clock, falling through to the AWTRIX health otherwise —
a minimal change confined to that leaf method, out of `AppModel.poll`.

## Data flow

```text
UlanziClockHealth.poll
  └─ UlanziBattery.read()
       ├─ ADBClient.shell(find pid, read maps)        → pid, libzkgui base
       ├─ ADBClient.push(pct-batt) [only if missing]
       ├─ ADBClient.push(/tmp/pct-req = addr,len,path)
       ├─ ADBClient.shell(/tmp/pct-batt)              → 12 bytes
       └─ parse + plausibility gate                    → UlanziBatterySample?
  └─ UlanziBatteryTrajectory.accept(sample)
       └─ reading  (direction from flag, ETA from percent-slope fit) → BatteryReading?
  └─ AppModel.batteryLine(clock)                       → panel line
```

## Error handling and degradation

Every failure degrades to "no battery line", never to a wrong one:

- adb port unreachable / connect fails → no reading.
- `appVer` ≠ a known offset entry → no reading (feature off for that firmware).
- pid or libzkgui base not found → no reading.
- helper push or run fails → no reading; retried next poll.
- parsed values fail the plausibility gate → no reading.
- The last-known charge still shows per the existing rule (a battery that blips
  out on one failed poll is not redrawn as empty).

## Security and honesty

- The feature stands on an **open root adb backdoor**. That is the firmware's
  choice, not ours; we only read. This is documented here and in the code so it
  is a deliberate, visible dependency, not a buried one.
- Read-only: no memory writes, no register pokes, no config changes on the
  device. The `usb_device` / `usb_host` / `usb_null` sysfs files (reading one
  switches the USB role) are never touched.
- If a firmware update closes adb or moves the offset, the feature disables
  itself; nothing breaks and no wrong number appears.

## Testing

- `ADBClient`: framing over a fake transport — handshake, shell collect, sync
  SEND — no device.
- `UlanziBattery`: a fake `ADBClient` returns canned `maps`, `cmdline`, and the
  12 reader bytes; assert pid/base resolution, address arithmetic, parse, and
  every degradation branch. The plausibility gate gets its own cases (101%,
  1500 mV, short read).
- Offset table: `1.1.1` present; an unknown version yields nil.
- `UlanziBatteryTrajectory`: canned sample series assert direction straight off
  the flag, `shownPercent` = `percent`, ETA nil under the minimum span, and a
  known slope yielding a known `~N h left` through `BatteryLine`; a charging
  series yields nil ETA.
- `make_pct_batt.py`: a host-side test assembles the ELF and checks the header
  and the three syscall sequences; the machine code itself is pinned by golden
  bytes so an accidental re-encode is caught.
- The existing `BatteryReading` / `BatteryLine` suites already cover the panel
  behaviour and are untouched — the TC002 reading enters the same types.

## Risks

- **Firmware update.** Offsets are build-specific; `appVer` gating contains the
  blast radius to "feature silently off until the table learns the new version".
- **ASLR.** Handled: base is read from `maps` each poll, never baked.
- **adb contention.** If the user's own tooling holds `5555`, our connect fails
  and we degrade; polls are infrequent and short.
- **`/dev/ttyS1` contention.** Avoided entirely — we read `zkgui`'s memory, we do
  not open the UART.

## Reconnaissance artifacts

The spike's throwaway tooling (Python ADB client, the ELF generators, the memory
dumps) lives under the job's tmp dir and is not part of the codebase. The
committed generator `Scripts/make_pct_batt.py` is the productized descendant of
`mkelf_mem.py`.
