import Foundation
import Testing
@testable import AwtrixKit

// The weather end to end: what the connector produces, and what the host does
// to the device with it.
//
// `OVERLAY` is GLOBAL device state — not scoped to an app, written to flash,
// and changeable by hand from the device's own web interface — so the rules
// here are about borrowing rather than about drawing. Read what was there
// first, write only on a change, and put it back.

// MARK: - Doubles

/// Answers the weather service and the clock from one door, because the app
/// has one: `Transport` is the only way either is reached.
private final class SkyAndClock: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var sky: Data
    private var skyStatus = 200
    private var settingsWriteStatus = 200
    /// What the clock's `OVERLAY` setting currently holds. Written by a POST,
    /// answered by a GET — as it is on the device.
    private var overlayOnDevice: String

    init(sky: Data = weatherBody(), overlayOnDevice: String = "clear") {
        self.sky = sky
        self.overlayOnDevice = overlayOnDevice
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    /// Every request that reached the clock's settings, in order, with the
    /// overlay each one carried — nil for the read.
    var overlayWrites: [String] {
        requests
            .filter { $0.url?.path == "/api/settings" && $0.httpMethod == "POST" }
            .compactMap {
                (try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data()))
                    .flatMap { $0 as? [String: Any] }?["OVERLAY"] as? String
            }
    }

    var customAppPosts: [[String: Any]] {
        requests
            .filter { $0.url?.path == "/api/custom" }
            .map {
                ((try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data()))
                    as? [String: Any]) ?? [:]
            }
    }

    /// What the clock's overlay setting holds right now.
    var currentOverlay: String { lock.withLock { overlayOnDevice } }

    func changeSky(to body: Data) { lock.withLock { sky = body } }
    func breakTheSky(status: Int = 503) { lock.withLock { skyStatus = status } }
    func mendTheSky() { lock.withLock { skyStatus = 200 } }
    /// Refuses writes to the settings, and changes nothing when it does.
    func refuseSettingsWrites() { lock.withLock { settingsWriteStatus = 500 } }
    func acceptSettingsWrites() { lock.withLock { settingsWriteStatus = 200 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (body, status) = lock.withLock { () -> (Data, Int) in
            recorded.append(request)
            guard request.url?.host != "api.open-meteo.com" else { return (sky, skyStatus) }
            guard request.url?.path == "/api/settings" else { return (Data("OK".utf8), 200) }
            // A written overlay is what the next read answers with, because
            // that is what the device does — `OVERLAY` is one setting in flash,
            // not a value per caller. A double that kept answering the ORIGINAL
            // would let a custody that read the prior value AFTER writing over
            // it pass every test in this file, while on real hardware the value
            // it promised to put back was already gone.
            if request.httpMethod == "POST" {
                guard settingsWriteStatus == 200 else {
                    // A refused write changes nothing, which is the whole point
                    // of posing one.
                    return (Data("no".utf8), settingsWriteStatus)
                }
                let written = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()))
                    .flatMap { $0 as? [String: Any] }?["OVERLAY"] as? String
                if let written { overlayOnDevice = written }
                return (Data("OK".utf8), 200)
            }
            return (Data(#"{"BRI":2,"SOUND":true,"OVERLAY":"\#(overlayOnDevice)"}"#.utf8), 200)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (body, response)
    }
}

private func weatherBody(code: Int = 61, isDay: Int = 1, temperature: Double = 4.2) -> Data {
    Data("""
    {"current":{"time":"2026-08-19T02:45","interval":900,"weather_code":\(code),
      "is_day":\(isDay),"precipitation":0.4,"temperature_2m":\(temperature),
      "wind_speed_10m":9.0}}
    """.utf8)
}

private let desk = Coordinates(latitude: 55.7558, longitude: 37.6173)

/// A clock a test turns by hand, so the source's own interval can be stepped
/// over without waiting fifteen minutes for it.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var moment = Date(timeIntervalSince1970: 1_700_000_000)

    var now: @Sendable () -> Date { { self.lock.withLock { self.moment } } }
    func advance(_ seconds: TimeInterval) {
        lock.withLock { moment = moment.addingTimeInterval(seconds) }
    }
}

private func weatherHost(
    transport: SkyAndClock,
    clock: Clock = Clock(),
    store: any SettingsStore = InMemorySettingsStore(),
    /// Handed in so a test can outlive the host that wrote it — which is how a
    /// relaunch is posed here: a second host over the same store and the same
    /// device, with nothing in between.
    borrowedOverlays: any BorrowedOverlayStore = InMemoryBorrowedOverlayStore()
) -> (host: ConnectorHost, connector: WeatherConnector) {
    let connector = WeatherConnector(
        source: OpenMeteoSource(transport: transport, now: clock.now),
        location: { desk }
    )
    let registry = ConnectorRegistry()
    registry.register(connector)
    let host = ConnectorHost(
        device: AwtrixDevice(host: "10.0.0.5", transport: transport),
        registry: registry,
        store: store,
        audio: SilentAudio(),
        iconInstaller: PassThroughIcons(),
        borrowedOverlays: borrowedOverlays
    )
    return (host, connector)
}

private struct SilentAudio: AudioPlaying {
    func play(_ clips: [SpokenClip]) async {}
}

private struct PassThroughIcons: IconInstalling {
    func ensureInstalled(_ ref: IconReference) async throws -> String {
        switch ref {
        case let .installed(name): return name
        case let .catalogue(id): return String(id)
        }
    }
}

// MARK: - What the connector produces

@Test func theWeatherIsDrawnInTheClocksOwnLoopRatherThanOverIt() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 61, temperature: 4.2))
    let connector = WeatherConnector(
        source: OpenMeteoSource(transport: transport), location: { desk }
    )

    let output = try await connector.produce()

    // An app, not a notification. Weather is ambient: it should be there when
    // you glance at the clock, not interrupt what is on it.
    #expect(output.surface == .app(WeatherConnector.appName))
    #expect(output.overlay == .rain)
    #expect(output.text == "4°")
    #expect(output.color == WeatherTheme.rain.colour)
    // Nothing is spoken and nothing is held: an app has no banner to release.
    #expect(output.localAudio.isEmpty)
    #expect(output.holdUntilAudioEnds == false)
}

@Test func theTemperatureIsRoundedToWholeDegreesEitherSideOfZero() async throws {
    for (reading, shown) in [(4.2, "4°"), (4.6, "5°"), (-3.4, "-3°"), (-3.6, "-4°"), (0.2, "0°")] {
        let transport = SkyAndClock(sky: weatherBody(temperature: reading))
        let connector = WeatherConnector(
            source: OpenMeteoSource(transport: transport), location: { desk }
        )

        #expect(try await connector.produce().text == shown)
    }
}

// MARK: - Borrowing the overlay

@Test func theOverlayTheWeatherAsksForIsWrittenToTheDevice() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 71))
    let (host, _) = weatherHost(transport: transport)

    #expect(await host.runOnce(connectorId: "weather") == .delivered)

    #expect(transport.overlayWrites == ["snow"])
    #expect(transport.customAppPosts.count == 1)
    // The reading goes in the loop; nothing goes over it. And the order is
    // load-bearing rather than incidental: the overlay draws over everything on
    // screen, so setting it after the app has appeared is a visible flicker of
    // the old weather under the new number. Read, write, then show.
    #expect(transport.requests.compactMap { $0.url?.path }.filter { $0.hasPrefix("/api/") }
        == ["/api/settings", "/api/settings", "/api/custom"])
}

// A restore the clock refused is still owed. Forgetting on failure would drop
// the only record of what the device had — the next quit would find nothing to
// put back, and the user's own overlay would be gone for good.
@Test func aRestoreTheClockRefusedIsStillOwedAtTheNextOne() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 61), overlayOnDevice: "snow")
    let (host, _) = weatherHost(transport: transport)

    #expect(await host.runOnce(connectorId: "weather") == .delivered)
    transport.refuseSettingsWrites()
    await host.restoreDeviceState(borrowedBy: nil)
    #expect(transport.currentOverlay == "rain")

    transport.acceptSettingsWrites()
    await host.restoreDeviceState(borrowedBy: nil)

    #expect(transport.overlayWrites == ["rain", "snow", "snow"])
    #expect(transport.currentOverlay == "snow")
}

@Test func theOverlayIsNotRewrittenWhenTheWeatherHasNotChanged() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 61))
    let clock = Clock()
    let (host, _) = weatherHost(transport: transport, clock: clock)

    #expect(await host.runOnce(connectorId: "weather") == .delivered)
    // Past the source's own interval, so the second run really does fetch and
    // really does decide — a cached reading would make this pass for the wrong
    // reason entirely.
    clock.advance(1_000)
    #expect(await host.runOnce(connectorId: "weather") == .delivered)

    #expect(transport.requests.filter { $0.url?.host == "api.open-meteo.com" }.count == 2)
    // One write, not two. The setting is in flash on a device that lives on a
    // shelf for years, and an identical rewrite buys nothing at all.
    #expect(transport.overlayWrites == ["rain"])
    // The app in the loop IS rewritten, and that is not the same question: it
    // lives in RAM, so a clock that reboots comes back without it and a
    // skip-if-unchanged would never put it back.
    #expect(transport.customAppPosts.count == 2)
}

@Test func theOverlayIsRewrittenWhenTheWeatherChanges() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 61))
    let clock = Clock()
    let (host, _) = weatherHost(transport: transport, clock: clock)

    #expect(await host.runOnce(connectorId: "weather") == .delivered)
    transport.changeSky(to: weatherBody(code: 95))
    clock.advance(1_000)
    #expect(await host.runOnce(connectorId: "weather") == .delivered)

    #expect(transport.overlayWrites == ["rain", "thunder"])
}

@Test func theOverlayThatWasThereBeforeIsWhatIsPutBack() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 61), overlayOnDevice: "snow")
    let (host, _) = weatherHost(transport: transport)

    #expect(await host.runOnce(connectorId: "weather") == .delivered)
    await host.restoreDeviceState(borrowedBy: nil)

    // Not `clear`: what is put back is what the device actually had, which the
    // user may well have set by hand.
    #expect(transport.overlayWrites == ["rain", "snow"])
}

// A value this app does not know is still the user's. Restoring `clear` over a
// name a newer firmware understands would destroy the setting rather than
// return it.
@Test func anOverlayNameThisAppDoesNotKnowIsStillPutBackVerbatim() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 61), overlayOnDevice: "aurora")
    let (host, _) = weatherHost(transport: transport)

    #expect(await host.runOnce(connectorId: "weather") == .delivered)
    await host.restoreDeviceState(borrowedBy: nil)

    #expect(transport.overlayWrites == ["rain", "aurora"])
    #expect(DeviceOverlay.namesTheFirmwareAccepts.contains("aurora") == false)
}

// MARK: - Across an unclean exit

// The launch that borrows is not always the launch that gives back. A force
// quit, a logout, a crash, or a teardown that outruns the 15-second quit budget
// while a synthesis is wedged all end a launch with the overlay still on loan
// and `restoreDeviceState` never reached.
//
// With the record in memory only, the next launch read the device, found this
// app's own `rain` sitting there, and wrote it down as what the user had —
// after which every clean quit restored `rain` and the real setting was
// recoverable from nowhere. Weather ships enabled at a 900-second cadence, so
// this armed itself within fifteen minutes of a first launch.
@Test func aLaunchAfterAnUncleanExitStillPutsBackTheOverlayTheUserHad() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 61), overlayOnDevice: "clear")
    // The one thing that survives the process below.
    let borrowed = InMemoryBorrowedOverlayStore()

    let first = weatherHost(transport: transport, borrowedOverlays: borrowed)
    #expect(await first.host.runOnce(connectorId: "weather") == .delivered)
    #expect(transport.currentOverlay == "rain")
    // The process dies here. No teardown, no restore — `first` is simply gone.

    let second = weatherHost(transport: transport, borrowedOverlays: borrowed)
    #expect(await second.host.runOnce(connectorId: "weather") == .delivered)
    await second.host.restoreDeviceState(borrowedBy: nil)

    #expect(transport.currentOverlay == "clear")
    // And the relaunch rewrote nothing: the device already held `rain`, which
    // is a flash write saved as well as a correctness claim.
    #expect(transport.overlayWrites == ["rain", "clear"])
}

// The precise mechanism, read off the record rather than off the outcome: what
// a relaunch writes down as the displaced value is the USER's, never the one
// this app put there. An unclean exit is the only way the two differ, and it is
// the ordinary way this app ends.
@Test func theOverlayThisAppWroteIsNeverRecordedAsTheOneItDisplaced() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 61), overlayOnDevice: "snow")
    let borrowed = InMemoryBorrowedOverlayStore()

    let first = weatherHost(transport: transport, borrowedOverlays: borrowed)
    #expect(await first.host.runOnce(connectorId: "weather") == .delivered)

    // Relaunch into weather that has since changed, so the second run really
    // does write and really does decide what it displaced.
    transport.changeSky(to: weatherBody(code: 71))
    let second = weatherHost(transport: transport, borrowedOverlays: borrowed)
    #expect(await second.host.runOnce(connectorId: "weather") == .delivered)

    #expect(
        borrowed.borrowedOverlay()
            == BorrowedOverlay(before: "snow", applied: "snow", borrower: "weather")
    )
}

// A restore that got through clears the record, or the launch after it would
// write a stale overlay back over whatever the user has set since.
@Test func anOverlayGivenBackIsNoLongerOnLoan() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 61), overlayOnDevice: "clear")
    let borrowed = InMemoryBorrowedOverlayStore()
    let (host, _) = weatherHost(transport: transport, borrowedOverlays: borrowed)

    #expect(await host.runOnce(connectorId: "weather") == .delivered)
    #expect(borrowed.borrowedOverlay() != nil)
    await host.restoreDeviceState(borrowedBy: nil)

    #expect(borrowed.borrowedOverlay() == nil)
}

// A refused restore keeps the record, on the durable store as much as on the
// actor: dropping it there is the same defect as dropping it here, one launch
// later.
@Test func aRefusedRestoreLeavesTheBorrowOnTheRecord() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 61), overlayOnDevice: "snow")
    let borrowed = InMemoryBorrowedOverlayStore()
    let (host, _) = weatherHost(transport: transport, borrowedOverlays: borrowed)

    #expect(await host.runOnce(connectorId: "weather") == .delivered)
    transport.refuseSettingsWrites()
    await host.restoreDeviceState(borrowedBy: nil)

    #expect(
        borrowed.borrowedOverlay()
            == BorrowedOverlay(before: "snow", applied: "rain", borrower: "weather")
    )
}

// The record has to survive the process, and the store that ships is the only
// one that can. Written by one instance, read by another over the same
// defaults — which is what two launches are.
@Test func aBorrowedOverlaySurvivesTheProcessThatWroteItDown() throws {
    let suite = "borrowed-overlay-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let borrowed = BorrowedOverlay(before: "aurora", applied: "rain", borrower: "weather")

    UserDefaultsBorrowedOverlayStore(defaults: defaults).record(borrowed)

    #expect(UserDefaultsBorrowedOverlayStore(defaults: defaults).borrowedOverlay() == borrowed)
    UserDefaultsBorrowedOverlayStore(defaults: defaults).forget()
    #expect(UserDefaultsBorrowedOverlayStore(defaults: defaults).borrowedOverlay() == nil)
}

// A half-written record is no record. Reading a `before` with nothing beside it
// would restore a value without being able to tell whether this app is the one
// that displaced it.
@Test func aPartialRecordReadsAsNothingOnLoan() throws {
    let suite = "borrowed-overlay-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(["before": "snow"], forKey: "borrowedOverlay")

    #expect(UserDefaultsBorrowedOverlayStore(defaults: defaults).borrowedOverlay() == nil)
}

@Test func restoringSomethingThatWasNeverTakenWritesNothing() async throws {
    let transport = SkyAndClock()
    let (host, _) = weatherHost(transport: transport)

    await host.restoreDeviceState(borrowedBy: nil)

    #expect(transport.requests.isEmpty)
}

@Test func restoringTwiceOverWritesTheDeviceOnce() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 61), overlayOnDevice: "snow")
    let (host, _) = weatherHost(transport: transport)

    #expect(await host.runOnce(connectorId: "weather") == .delivered)
    await host.restoreDeviceState(borrowedBy: nil)
    await host.restoreDeviceState(borrowedBy: nil)

    #expect(transport.overlayWrites == ["rain", "snow"])
}

// The overlay is one global setting, so it has one borrower. Switching off a
// connector that never touched it must not put back an overlay another one is
// still using.
@Test func aConnectorThatNeverTookTheOverlayDoesNotGiveItBack() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 61), overlayOnDevice: "snow")
    let (host, _) = weatherHost(transport: transport)

    #expect(await host.runOnce(connectorId: "weather") == .delivered)
    await host.restoreDeviceState(borrowedBy: "anecdotes")

    #expect(transport.overlayWrites == ["rain"])
}

// Anything the app added to the loop goes with it: the constraint is that the
// app removes what it created, and a stale reading left in the rotation for
// ever is exactly what that forbids.
@Test func theAppTheConnectorAddedToTheLoopIsRemovedOnRestore() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 61))
    let (host, _) = weatherHost(transport: transport)

    #expect(await host.runOnce(connectorId: "weather") == .delivered)
    await host.restoreDeviceState(borrowedBy: nil)

    let removals = transport.requests.filter {
        $0.url?.path == "/api/custom" && ($0.httpBody ?? Data()).isEmpty
    }
    #expect(removals.count == 1)
    #expect(removals.first?.url?.query == "name=\(WeatherConnector.appName)")
}

@Test func aFailedWeatherFetchLeavesThePreviousOverlayInPlace() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 71))
    let clock = Clock()
    let (host, _) = weatherHost(transport: transport, clock: clock)

    #expect(await host.runOnce(connectorId: "weather") == .delivered)
    transport.breakTheSky()
    clock.advance(1_000)
    let result = await host.runOnce(connectorId: "weather")

    #expect(result == .failed(String(describing: WeatherError.http(status: 503))))
    // Still `snow`, and nothing after it. An outage is not a change in the
    // weather, and clearing the overlay on one would wipe the clock every time
    // the wifi hiccupped.
    #expect(transport.overlayWrites == ["snow"])
}

// Whatever else goes wrong, the one thing that must never reach the device is a
// name outside the six: it is answered 200, silently coerced to `clear`, and
// there is nothing anywhere to say the overlay was rejected.
@Test func everyOverlayEverWrittenIsOneTheFirmwareAccepts() async throws {
    let clock = Clock()
    let transport = SkyAndClock(sky: weatherBody(code: 0))
    let (host, _) = weatherHost(transport: transport, clock: clock)

    for code in [0, 3, 48, 51, 61, 71, 80, 85, 95, 96, 4_242] {
        transport.changeSky(to: weatherBody(code: code))
        clock.advance(1_000)
        #expect(await host.runOnce(connectorId: "weather") == .delivered)
    }

    #expect(transport.overlayWrites.isEmpty == false)
    for written in transport.overlayWrites {
        #expect(DeviceOverlay.namesTheFirmwareAccepts.contains(written), "sent \(written)")
    }
}

// The connector is a source of content and nothing else. It reaches the
// weather service, and the device is the host's business — so a produce with
// nothing behind the clock still asks nobody about the overlay.
@Test func theConnectorItselfNeverTalksToTheDevice() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 61))
    let connector = WeatherConnector(
        source: OpenMeteoSource(transport: transport), location: { desk }
    )

    _ = try await connector.produce()

    #expect(transport.requests.allSatisfy { $0.url?.host == "api.open-meteo.com" })
}

// Nothing this connector produces can be heard, and it says so. The two quiet
// rules — a macOS Focus, and the window that stands in for it — exist to stop
// the app SPEAKING; holding a drawing through the shipped 23:00–08:00 default
// froze the temperature on the matrix for nine hours a night, and left the sky
// raining until morning if it had been raining at 22:55.
@Test func theWeatherIsSilentAndSaysSo() async throws {
    let transport = SkyAndClock(sky: weatherBody(code: 61))
    let connector = WeatherConnector(
        source: OpenMeteoSource(transport: transport), location: { desk }
    )

    #expect(connector.isAudible == false)
    // And the claim is honest about the output: no clips, no jingle. A
    // connector that declared silence and then spoke would be silenced by
    // nothing at three in the morning.
    let output = try await connector.produce()
    #expect(output.localAudio.isEmpty)
    #expect(output.jingle == nil)
}

// The cadence the schedule offers by default is the source's own, so a user who
// never touches the slider polls a free public service at exactly the rate it
// updates.
@Test func theWeatherConnectorDefaultsToTheSourcesOwnCadence() {
    let connector = WeatherConnector(
        source: OpenMeteoSource(transport: SkyAndClock()), location: { desk }
    )

    #expect(connector.defaultInterval == OpenMeteoSource.defaultInterval)
    #expect(connector.defaultInterval == 900)
}
