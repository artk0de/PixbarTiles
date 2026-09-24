// Tests/PixbarKitTests/ClockDiscoveryTests.swift
import Foundation
import Testing
@testable import PixbarKit

// The merged discovery: the AWTRIX browse and the TC002 broadcasts answering
// one question — which clocks are advertising themselves — through one list.
// Each half is tested where it lives; what is under test here is the merge,
// the shape of the rows it publishes, and the life they have between start
// and stop.

/// A sighting stream a test hands out and feeds, standing in for the socket.
@MainActor
private func makeSightings() -> (
    make: @MainActor () -> AsyncStream<UlanziSighting>,
    feed: AsyncStream<UlanziSighting>.Continuation
) {
    let (stream, continuation) = AsyncStream<UlanziSighting>.makeStream()
    return ({ stream }, continuation)
}

/// Polls until the condition holds or the wait runs out. Returns rather than
/// asserting, so the failure is reported by the expectation that named the
/// rule. The budget is `pollingBudget`, for the same reason its twin in
/// `DeviceDiscoveryTests` says.
@discardableResult
@MainActor
private func waitUntil(
    _ condition: @MainActor () -> Bool, limit: TimeInterval? = nil
) async -> Bool {
    let deadline = Date().addingTimeInterval(waitBudget(limit))
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

private func sighting(
    _ line: String = "Ulanzi TC002 9b9a:ccc4b2779b9a:B0D32I008U3671403:false",
    from host: String = "192.168.1.72"
) -> UlanziSighting {
    UlanziSighting(announcement: UlanziAnnouncement.parse(line)!, host: host)
}

@MainActor
private func makeSubject(
    _ browsing: FakeBonjourBrowser,
    sightings: @escaping @MainActor () -> AsyncStream<UlanziSighting>
) -> ClockDiscovery {
    ClockDiscovery(
        browse: DeviceBrowser(browsing: { browsing }, sleep: { _ in }),
        sightings: sightings
    )
}

@MainActor @Suite struct ClockDiscoveryTests {
    // The row a broadcast earns carries the device's own address — the thing
    // the line does not say and "Add" cannot act without.
    @Test func aBroadcastBecomesARowAtTheAddressItArrivedFrom() async {
        let (sightings, feed) = makeSightings()
        let subject = makeSubject(FakeBonjourBrowser(), sightings: sightings)
        subject.start()

        feed.yield(sighting())

        #expect(await waitUntil {
            subject.found == [
                DiscoveredClock(name: "TC002 9b9a", model: "TC002", address: "192.168.1.72")
            ]
        })
        subject.stop()
    }

    // The name distinguishes two TC002s the same way the AWTRIX instance name
    // distinguishes two of those — by the tail of the MAC.
    @Test func theRowNameCarriesTheMacsTailSoTwoClocksCanBeToldApart() async {
        let (sightings, feed) = makeSightings()
        let subject = makeSubject(FakeBonjourBrowser(), sightings: sightings)
        subject.start()

        feed.yield(sighting("Ulanzi TC002 ff01:ccc4b277ff01:B0D32I008U3671403:false"))

        #expect(await waitUntil { subject.found.first?.name == "TC002 ff01" })
        subject.stop()
    }

    // A browse hit names the firmware's own address: the instance name is
    // exactly what the firmware answers to under `.local` (measured,
    // `DeviceDiscovery`'s own record).
    @Test func aBrowseHitBecomesARowAtTheAddressTheFirmwareAnswers() async {
        let browsing = FakeBonjourBrowser()
        let subject = makeSubject(browsing, sightings: makeSightings().make)
        subject.start()

        browsing.emit(.results(["awtrix_a07f9c"]))

        #expect(await waitUntil {
            subject.found == [
                DiscoveredClock(
                    name: "awtrix_a07f9c", model: "AWTRIX 3", address: "awtrix_a07f9c.local"
                )
            ]
        })
        subject.stop()
    }

    // Both models on one network, one list — the list the Clocks section
    // exists to show.
    @Test func bothModelsLandInTheSameList() async {
        let browsing = FakeBonjourBrowser()
        let (sightings, feed) = makeSightings()
        let subject = makeSubject(browsing, sightings: sightings)
        subject.start()

        browsing.emit(.results(["awtrix_a07f9c"]))
        feed.yield(sighting())

        #expect(await waitUntil { subject.found.count == 2 })
        // Deterministic order, so the section never reshuffles between draws.
        #expect(
            subject.found.map(\.address) == ["192.168.1.72", "awtrix_a07f9c.local"]
        )
        subject.stop()
    }

    // One device, one row: a re-sighting is the same clock saying hello again
    // — possibly from a moved address — not a second clock.
    @Test func aReSightingUpdatesTheRowRatherThanAddingOne() async {
        let (sightings, feed) = makeSightings()
        let subject = makeSubject(FakeBonjourBrowser(), sightings: sightings)
        subject.start()
        feed.yield(sighting(from: "192.168.1.72"))
        #expect(await waitUntil { !subject.found.isEmpty })

        feed.yield(sighting(from: "192.168.1.90"))

        #expect(await waitUntil {
            subject.found == [
                DiscoveredClock(name: "TC002 9b9a", model: "TC002", address: "192.168.1.90")
            ]
        })
        subject.stop()
    }

    // Started means both halves are asked: the browse is up, and broadcasts
    // are being read.
    @Test func startingStartsBothHalves() async {
        let browsing = FakeBonjourBrowser()
        let (sightings, feed) = makeSightings()
        let subject = makeSubject(browsing, sightings: sightings)
        subject.start()

        #expect(browsing.starts == 1)
        feed.yield(sighting())
        #expect(await waitUntil { !subject.found.isEmpty })
        subject.stop()
    }

    // The same evidence rule the browse keeps about its own findings: stopped,
    // the list is what nobody can see any more, and showing it would be a
    // list outliving its own evidence.
    @Test func stoppingForgetsWhatItSaw() async {
        let (sightings, feed) = makeSightings()
        let subject = makeSubject(FakeBonjourBrowser(), sightings: sightings)
        subject.start()
        feed.yield(sighting())
        #expect(await waitUntil { !subject.found.isEmpty })

        subject.stop()

        #expect(await waitUntil { subject.found.isEmpty && subject.state == .idle })
        // And a sighting that lands after the stop is nobody's: the stream's
        // consumer is gone, so the row must not come back.
        feed.yield(sighting(from: "10.0.0.9"))
        #expect(await waitUntil({ !subject.found.isEmpty }, limit: 0.1) == false)
    }

    // The panel's status line reads this state; the browse's own answer is
    // what it says, including the answers only a browse can give.
    @Test func theBrowseAnswerPassesThrough() async {
        let browsing = FakeBonjourBrowser()
        let subject = makeSubject(browsing, sightings: makeSightings().make)
        subject.start()

        browsing.emit(.denied)

        #expect(await waitUntil { subject.state == .denied })
        subject.stop()
    }
}
