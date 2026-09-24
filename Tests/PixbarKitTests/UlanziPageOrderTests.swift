// Tests/PixbarKitTests/UlanziPageOrderTests.swift
import Foundation
import Testing
@testable import PixbarKit

private func scene(_ tag: Int) -> UlanziScene {
    var canvas = PixelCanvas()
    canvas.fill(.white)
    return UlanziScene(frames: [UlanziFrame(duration: tag, draw: [canvas.drawCommands()])])
}

/// The TC002's DIY pages run in the order they were CREATED, and nothing else
/// orders them. Measured on appVer 1.1.1, 2026-09-24: `probe-order-b`, `-a`,
/// `-c` pushed in that order listed as b, a, c (not sorted); an upsert of b
/// kept its place; b deleted and pushed again moved to the end. There is no
/// order API — so the app's tile order is put on the clock by re-creating the
/// pages that stand out of it, from the first one out of place onwards.
@Suite struct UlanziPageOrderTests {
    let transport = ScriptedUlanziTransport()
    let record = MemoryAppRecord()

    func makeSession() -> UlanziClockSession {
        let device = UlanziDevice(host: "192.168.1.72", transport: transport)
        return UlanziClockSession(
            device: device,
            custody: UlanziCustody(device: device, record: record, clockId: "clock-1"),
            sleep: { _ in }
        )
    }

    func deliver(_ tiles: [String], to session: UlanziClockSession) async {
        for tile in tiles {
            _ = await session.deliver(UlanziDelivery(scene: scene(1)), toTile: tile)
        }
    }

    /// Every request after `from`, as the clock sees it: the list read, a
    /// page's delete (empty body), a page's upsert.
    func wire(after from: Int) -> [String] {
        transport.requests.dropFirst(from).map { request in
            if request.url?.path == "/api/customList" { return "list" }
            let name = request.url?.query.map { String($0.dropFirst("name=".count)) } ?? "?"
            return (request.httpBody ?? Data()).isEmpty ? "delete \(name)" : "push \(name)"
        }
    }

    @Test func aReorderReCreatesThePagesFromTheFirstOneOutOfPlace() async {
        let session = makeSession()
        await deliver(["a", "b", "c"], to: session)
        transport.list = ["pbt-a", "pbt-b", "pbt-c"]
        let before = transport.requests.count

        await session.arrange(order: ["a", "c", "b"])

        // a is already first; from c onwards each page is deleted and pushed
        // again, which puts it last — in the app's order.
        #expect(wire(after: before) == [
            "list", "delete pbt-c", "push pbt-c", "delete pbt-b", "push pbt-b",
        ])
    }

    @Test func aClockAlreadyInOrderCostsOnlyTheListRead() async {
        let session = makeSession()
        await deliver(["a", "b", "c"], to: session)
        transport.list = ["pbt-a", "pbt-b", "pbt-c"]
        let before = transport.requests.count

        await session.arrange(order: ["a", "b", "c"])

        #expect(wire(after: before) == ["list"])
    }

    /// Somebody else's page between ours does not make ours out of order.
    @Test func aForeignPageIsNoneOfTheOrdersBusiness() async {
        let session = makeSession()
        await deliver(["a", "b"], to: session)
        transport.list = ["pbt-a", "probe-x", "pbt-b"]
        let before = transport.requests.count

        await session.arrange(order: ["a", "b"])

        #expect(wire(after: before) == ["list"])
    }

    /// The re-creation pushes what the page carries — so a page whose content
    /// this run has not put there yet is left where it is, and the next check
    /// after its first push places it.
    @Test func aPageWithUnknownContentIsNotReCreated() async {
        let session = makeSession()
        await deliver(["a", "c"], to: session)
        transport.list = ["pbt-b", "pbt-c", "pbt-a"]
        let before = transport.requests.count

        await session.arrange(order: ["a", "b", "c"])

        #expect(wire(after: before) == [
            "list", "delete pbt-a", "push pbt-a", "delete pbt-c", "push pbt-c",
        ])
    }

    /// The order the start-up sweep registers — the tiles record's — is the
    /// one the reachability poll's check keeps the clock in.
    @Test func thePollsCheckKeepsTheSweptOrder() async {
        let session = makeSession()
        transport.list = []
        await session.sweep(liveTiles: ["a", "b"])
        await deliver(["b", "a"], to: session)
        transport.list = ["pbt-b", "pbt-a"]
        let before = transport.requests.count

        await session.verifyPages()

        #expect(wire(after: before) == [
            "list", "delete pbt-a", "push pbt-a", "delete pbt-b", "push pbt-b",
        ])
    }

    /// A clock that stops answering mid-way is an outage: the rest is left to
    /// the recovery sweep rather than pushed into a clock that is not there.
    @Test func anOutageMidWayStopsTheReCreation() async {
        let session = makeSession()
        await deliver(["a", "b", "c"], to: session)
        transport.list = ["pbt-c", "pbt-b", "pbt-a"]
        transport.timeouts = ["pbt-a"]
        let before = transport.requests.count

        await session.arrange(order: ["a", "b", "c"])

        #expect(wire(after: before) == ["list", "delete pbt-a"])
    }

    /// A missing page is pushed back first; that push lands at the end, so the
    /// order is left to the next check, which reads a list that includes it.
    @Test func aMissingPageIsPutBackBeforeAnythingIsReordered() async {
        let session = makeSession()
        await deliver(["a", "b", "c"], to: session)
        transport.list = ["pbt-c", "pbt-a"]
        let before = transport.requests.count

        await session.arrange(order: ["a", "b", "c"])

        #expect(wire(after: before) == ["list", "push pbt-b"])
    }
}
