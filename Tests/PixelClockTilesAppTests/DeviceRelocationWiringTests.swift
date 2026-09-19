import PixelClockKit
import Foundation
import Testing
@testable import PixelClockTilesApp

// MARK: - Doubles

/// Stands in for the browse-and-probe the shipped app runs, and records what it
/// was asked to look for.
///
/// A closure seam rather than a protocol, matching how every other clock and
/// sleeper reaches this model: what the app needs from a relocation is one
/// answer, and a type with one method is a protocol nobody gains anything from.
@MainActor
final class SpyRelocation {
    private(set) var asked: [String?] = []
    private let answer: String?

    init(answering answer: String?) {
        self.answer = answer
    }

    var relocate: AppModel.RelocatingHost {
        { [self] remembered in
            asked.append(remembered)
            return answer
        }
    }
}

/// A clock that cannot be reached, however it is asked.
private func unreachable() -> StubTransport {
    StubTransport(failure: URLError(.cannotConnectToHost))
}

/// Defaults of this test's own, so that what one test writes down about a clock
/// is not what the next one reads back.
private func temporaryDefaults() -> UserDefaults {
    UserDefaults(suiteName: "relocation-\(UUID().uuidString)")!
}

// MARK: - Knowing which clock is ours

// The identity the whole feature turns on. Without it, "exactly one clock is
// advertising" is the only rule available, and that rule moves this app onto a
// neighbour's device the first time ours is unplugged.
@Test @MainActor func theClockThatAnswersIsRememberedByTheNameItGivesItself() async {
    let poll = Metronome()
    let defaults = temporaryDefaults()
    let subject = testModel(
        transport: StubTransport(body: onlineStats), defaults: defaults, pollSleep: poll.sleep
    )

    subject.start()
    #expect(await waitUntil { subject.isDeviceOnline })

    #expect(ClockStore(defaults: defaults).all().first?.hardwareIdentity == "abc")
    await subject.teardown()
}

// Learned and needed in the same launch. The name is written to the record for
// the next launch, but this one keeps its own copy of the clock, and a copy that
// never heard the name would search for "whichever clock is advertising" — the
// rule that finds a neighbour's.
@Test @MainActor func aNameLearnedThisLaunchIsWhatThisLaunchLooksFor() async {
    let poll = Metronome()
    let clock = SwitchableTransport(answering: true)
    let relocation = SpyRelocation(answering: nil)
    let subject = testModel(
        transport: clock, defaults: temporaryDefaults(), pollSleep: poll.sleep,
        relocate: relocation.relocate
    )
    subject.start()
    #expect(await waitUntil { subject.isDeviceOnline })
    #expect(await waitUntil { poll.parked == 1 })

    clock.nowFails()
    poll.tick()

    #expect(await waitUntil { relocation.asked.isEmpty == false })
    #expect(relocation.asked == ["abc"])
    await subject.teardown()
}

// A clock that is answering is where it says it is, and looking for it would
// put multicast on the network to confirm what the poll just said.
@Test @MainActor func nothingIsLookedForWhileTheClockIsAnswering() async {
    let poll = Metronome()
    let relocation = SpyRelocation(answering: "awtrix_a07f9c.local")
    let subject = testModel(
        transport: StubTransport(body: onlineStats), pollSleep: poll.sleep,
        relocate: relocation.relocate
    )

    subject.start()
    #expect(await waitUntil { subject.isDeviceOnline })

    #expect(relocation.asked.isEmpty)
    await subject.teardown()
}

// MARK: - Moving after it

// The defect, end to end: the lease moved, the poll failed, and the app finds
// the clock again by the name it has been advertising the whole time — without
// anybody opening the panel or typing an address.
@Test @MainActor func aClockThatStoppedAnsweringIsLookedForAndMovedOnto() async {
    let poll = Metronome()
    let defaults = temporaryDefaults()
    let relocation = SpyRelocation(answering: "awtrix_a07f9c.local")
    let subject = testModel(
        transport: unreachable(), defaults: defaults, pollSleep: poll.sleep,
        hardwareIdentity: "awtrix_a07f9c", relocate: relocation.relocate
    )

    subject.start()
    #expect(await waitUntil { subject.deviceHost == "awtrix_a07f9c.local" })

    // Asked for OUR clock, not for whatever is out there.
    #expect(relocation.asked == ["awtrix_a07f9c"])
    await subject.teardown()
}

// The address survives the launch that found it. This is the half the user
// chose: a name written down once, after which a moving lease is not something
// this app has to notice again.
@Test @MainActor func theAddressTheAppMovedOntoIsWrittenDownForNextTime() async {
    let poll = Metronome()
    let defaults = temporaryDefaults()
    let relocation = SpyRelocation(answering: "awtrix_a07f9c.local")
    let subject = testModel(
        transport: unreachable(), defaults: defaults, pollSleep: poll.sleep,
        relocate: relocation.relocate
    )

    subject.start()
    #expect(await waitUntil { subject.deviceHost == "awtrix_a07f9c.local" })

    #expect(ClockStore(defaults: defaults).all().first?.address == "awtrix_a07f9c.local")
    await subject.teardown()
}

// The field is what somebody opens the gear to read, and a field still showing
// the address that stopped answering invites them to fix what is already fixed.
// The note beside it stays empty on purpose: "Saved — takes effect at next
// launch" is what a person's own typing earns, and it is false twice over here,
// since nobody typed and it took effect at once.
@Test @MainActor func theFieldShowsTheAddressTheAppMovedOntoWithoutClaimingASave() async {
    let poll = Metronome()
    let relocation = SpyRelocation(answering: "awtrix_a07f9c.local")
    let subject = testModel(
        transport: unreachable(), defaults: temporaryDefaults(), pollSleep: poll.sleep,
        relocate: relocation.relocate
    )

    subject.start()
    #expect(await waitUntil { subject.deviceHost == "awtrix_a07f9c.local" })

    #expect(subject.typedHost == "awtrix_a07f9c.local")
    #expect(subject.hostNote == nil)
    await subject.teardown()
}

// The clock is where it always was and simply not answering — a reboot, a
// firmware update, a web interface switched off. Writing the address back over
// itself would republish the field and rewrite a defaults key for no change at
// all.
@Test @MainActor func anAnswerThatIsTheAddressAlreadyInUseChangesNothing() async {
    let poll = Metronome()
    let defaults = temporaryDefaults()
    let relocation = SpyRelocation(answering: "10.0.0.5")
    let subject = testModel(
        transport: unreachable(), defaults: defaults, pollSleep: poll.sleep,
        deviceHost: "10.0.0.5", relocate: relocation.relocate
    )

    subject.start()
    #expect(await waitUntil { relocation.asked.isEmpty == false })

    #expect(subject.deviceHost == "10.0.0.5")
    #expect(ClockStore(defaults: defaults).all().isEmpty)
    await subject.teardown()
}

// The rationing is reset by a clock that ANSWERS, never by a move that merely
// happened. A move onto an address that turns out to be wrong would otherwise
// put the counter back to zero, making the next poll due, and the one after
// that — a browse per poll for the length of the outage, which is the storm the
// schedule exists to prevent, rebuilt out of an optimistic reset.
@Test @MainActor func aMoveDoesNotResetTheRationing() async {
    let poll = Metronome()
    let relocation = SpyRelocation(answering: "awtrix_a07f9c.local")
    let subject = testModel(
        transport: unreachable(), defaults: temporaryDefaults(), pollSleep: poll.sleep,
        relocate: relocation.relocate
    )

    subject.start()
    // One failure: due, and it moves.
    #expect(await waitUntil { subject.deviceHost == "awtrix_a07f9c.local" })
    #expect(await waitUntil { poll.parked == 1 })
    poll.tick()

    // Two failures: still a doubling, so still due.
    #expect(await waitUntil { relocation.asked.count == 2 })
    #expect(await waitUntil { poll.parked == 1 })
    poll.tick()

    // Three is not a doubling. Had the move reset the count, this poll would be
    // the second failure and therefore due — which is exactly what this asserts
    // does not happen.
    #expect(await waitUntil({ relocation.asked.count > 2 }, limit: 0.05) == false)
    await subject.teardown()
}

// A relocation that found nothing leaves everything exactly as it was. The
// clock being unplugged is the ordinary outage, and it is not a reason to
// change the address somebody set.
@Test @MainActor func findingNothingLeavesTheAddressAlone() async {
    let poll = Metronome()
    let defaults = temporaryDefaults()
    let relocation = SpyRelocation(answering: nil)
    let subject = testModel(
        transport: unreachable(), defaults: defaults, pollSleep: poll.sleep,
        deviceHost: "192.168.1.72", relocate: relocation.relocate
    )

    subject.start()
    #expect(await waitUntil { relocation.asked.isEmpty == false })

    #expect(subject.deviceHost == "192.168.1.72")
    #expect(ClockStore(defaults: defaults).all().isEmpty)
    await subject.teardown()
}
