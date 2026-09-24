// Tests/PixbarKitTests/UlanziRebootDetectionTests.swift
import Foundation
import Testing
@testable import PixbarKit

private func scene(_ tag: Int) -> UlanziScene {
    var canvas = PixelCanvas()
    canvas.fill(.white)
    return UlanziScene(frames: [UlanziFrame(duration: tag, draw: [canvas.drawCommands()])])
}

/// A clock that rebooted between two pushes answers the next one as if
/// nothing happened — and has lost every page. The session hears about it from
/// the reachability poll instead: the clock coming back from unreachable, or
/// the page list it answers (a 0.1 KB read) missing a page the app put there.
@Suite struct UlanziRebootDetectionTests {
    let transport = ScriptedUlanziTransport()
    let clock = TestClock()
    let record = MemoryAppRecord()

    func makeSession() -> UlanziClockSession {
        let device = UlanziDevice(host: "192.168.1.72", transport: transport)
        return UlanziClockSession(
            device: device,
            custody: UlanziCustody(device: device, record: record, clockId: "clock-1"),
            sleep: { _ in },
            now: { [clock] in clock.now }
        )
    }

    func boardOfThree(_ session: UlanziClockSession) async {
        for tile in ["a", "b", "c"] {
            _ = await session.deliver(UlanziDelivery(scene: scene(1)), toTile: tile)
        }
    }

    @Test func theClockReturningSweepsEveryPageOnce() async {
        let session = makeSession()
        await boardOfThree(session)

        await session.clockReturned()

        for page in ["pbt-a", "pbt-b", "pbt-c"] {
            #expect(transport.posts(page) == 2)
        }
        // And the pages are known again: the next identical push is skipped.
        _ = await session.deliver(UlanziDelivery(scene: scene(1)), toTile: "a")
        #expect(transport.posts("pbt-a") == 2)
    }

    @Test func aPageMissingFromTheListIsTheOnlyOneRePushed() async {
        let session = makeSession()
        await boardOfThree(session)
        transport.list = ["pbt-a", "pbt-c", "somebody-else"]

        await session.verifyPages()

        #expect(transport.posts("pbt-a") == 1)
        #expect(transport.posts("pbt-b") == 2)
        #expect(transport.posts("pbt-c") == 1)
    }

    @Test func aFullListPushesNothing() async {
        let session = makeSession()
        await boardOfThree(session)
        transport.list = ["pbt-a", "pbt-b", "pbt-c"]
        let before = transport.requests.count

        await session.verifyPages()

        #expect(transport.listReads == 1)
        #expect(transport.requests.count == before + 1)
    }

    /// Nothing of ours on the clock yet: there is nothing to find missing, and
    /// the read is not made.
    @Test func noPagesYetReadsNothing() async {
        let session = makeSession()

        await session.verifyPages()

        #expect(transport.listReads == 0)
    }

    /// A sweep already owed covers every page: the check runs it rather than
    /// reading the list.
    @Test func anOwedSweepRunsInsteadOfTheListRead() async {
        let session = makeSession()
        await boardOfThree(session)
        transport.down = true
        _ = await session.deliver(UlanziDelivery(scene: scene(2)), toTile: "a")
        transport.down = false

        await session.verifyPages()

        #expect(transport.listReads == 0)
        #expect(transport.posts("pbt-b") == 2)
        #expect(transport.posts("pbt-c") == 2)
    }

    /// A page the app took back is meant to be missing.
    @Test func aRemovedTilesPageIsNotReCreated() async {
        let session = makeSession()
        await boardOfThree(session)
        await session.tileRemoved("b")
        transport.list = ["pbt-a", "pbt-c"]

        await session.verifyPages()

        #expect(transport.posts("pbt-b") == 1)
    }
}
