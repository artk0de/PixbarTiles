// Tests/PixbarKitTests/UlanziPushDedupeTests.swift
import Foundation
import Testing
@testable import PixbarKit

/// A one-frame scene told apart on the wire by its frame duration.
private func scene(_ tag: Int) -> UlanziScene {
    var canvas = PixelCanvas()
    canvas.fill(.white)
    return UlanziScene(frames: [UlanziFrame(duration: tag, draw: [canvas.drawCommands()])])
}

private let okEnvelope = Data(#"{"code":200,"message":"ok"}"#.utf8)
private let refusal = Data(#"{"code":500,"message":"busy"}"#.utf8)

/// A page whose body is byte-identical to what the clock already carries is
/// not sent again: the TC002 decodes and replaces a 90 KB GIF on every upsert,
/// and a 60 s tile re-pushing the same GIF was 95% of everything on the wire.
@Suite struct UlanziPushDedupeTests {
    let recorder = RecordingTransport()
    let record = MemoryAppRecord()

    init() { recorder.body = okEnvelope }

    func makeSession() -> UlanziClockSession {
        let device = UlanziDevice(host: "192.168.1.72", transport: recorder)
        return UlanziClockSession(
            device: device,
            custody: UlanziCustody(device: device, record: record, clockId: "clock-1"),
            sleep: { _ in }
        )
    }

    func posts(_ page: String) -> Int {
        recorder.requests.filter {
            $0.httpMethod == "POST" && $0.url?.query == "name=\(page)" && !($0.httpBody ?? Data()).isEmpty
        }.count
    }

    @Test func anIdenticalSecondPushIsSkipped() async {
        let session = makeSession()

        let first = await session.deliver(UlanziDelivery(scene: scene(11)), toTile: "github")
        let second = await session.deliver(UlanziDelivery(scene: scene(11)), toTile: "github")

        #expect(first == .delivered)
        // The page shows it: the delivery has landed as far as anyone waiting
        // on it is concerned.
        #expect(second == .delivered)
        #expect(posts("pbt-github") == 1)
    }

    @Test func aChangedBodyIsPushed() async {
        let session = makeSession()

        _ = await session.deliver(UlanziDelivery(scene: scene(11)), toTile: "github")
        _ = await session.deliver(UlanziDelivery(scene: scene(12)), toTile: "github")

        #expect(posts("pbt-github") == 2)
    }

    @Test func theSameBodyOnAnotherPageIsNotADuplicate() async {
        let session = makeSession()

        _ = await session.deliver(UlanziDelivery(scene: scene(11)), toTile: "github")
        _ = await session.deliver(UlanziDelivery(scene: scene(11)), toTile: "weather")

        #expect(posts("pbt-github") == 1)
        #expect(posts("pbt-weather") == 1)
    }

    /// A failed push says nothing reliable about what the page shows, so the
    /// next identical body goes out.
    @Test func aFailedPushForgetsThePageSoTheNextPushGoesOut() async {
        let session = makeSession()
        _ = await session.deliver(UlanziDelivery(scene: scene(11)), toTile: "github")

        recorder.body = refusal
        _ = await session.deliver(UlanziDelivery(scene: scene(12)), toTile: "github")
        recorder.body = okEnvelope
        _ = await session.deliver(UlanziDelivery(scene: scene(11)), toTile: "github")
        _ = await session.deliver(UlanziDelivery(scene: scene(11)), toTile: "github")

        // 11, the refused 12, 11 again (the refusal forgot the page), and no
        // fourth: that one is a duplicate again.
        #expect(posts("pbt-github") == 3)
    }

    @Test func anIdleMarkTwiceIsPushedOnce() async {
        let session = makeSession()

        _ = await session.markIdle(tileId: "zai")
        _ = await session.markIdle(tileId: "zai")

        #expect(posts("pbt-zai") == 1)
    }

    /// A removed page is gone from the clock; the same body delivered to a
    /// re-added tile of that name has to re-create it.
    @Test func aRemovedPageIsForgotten() async {
        let session = makeSession()
        _ = await session.deliver(UlanziDelivery(scene: scene(11)), toTile: "github")

        await session.tileRemoved("github")
        _ = await session.deliver(UlanziDelivery(scene: scene(11)), toTile: "github")

        #expect(posts("pbt-github") == 2)
    }

    /// A celebration changes the page, and so does its restore: both go out
    /// even though the ambient page itself never changed.
    @Test func aCelebrationAndItsRestoreStillPush() async throws {
        let session = makeSession()
        _ = await session.deliver(UlanziDelivery(scene: scene(11)), toTile: "github")

        _ = await session.deliver(
            UlanziDelivery(
                scene: scene(11),
                interruptions: [Interruption(scene: scene(21), scope: .ownPage, duration: 5)]
            ),
            toTile: "github"
        )

        let durations: () -> [Int] = {
            recorder.requests.compactMap { request in
                guard let body = request.httpBody, !body.isEmpty,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                else { return nil }
                return json["duration"] as? Int
            }
        }
        let deadline = Date().addingTimeInterval(waitBudget(nil))
        while Date() < deadline, durations().last != 11 || durations().count < 3 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        // The celebration, then the page's own frame back.
        #expect(durations().suffix(2) == [21, 11])
    }

    /// After a celebration the page is back on its ambient frame; the next
    /// identical ambient push is a duplicate of what is ON the device.
    @Test func afterTheRestoreTheSameAmbientIsADuplicate() async throws {
        let session = makeSession()
        _ = await session.deliver(
            UlanziDelivery(
                scene: scene(11),
                interruptions: [Interruption(scene: scene(21), scope: .ownPage, duration: 5)]
            ),
            toTile: "github"
        )
        let deadline = Date().addingTimeInterval(waitBudget(nil))
        while Date() < deadline, posts("pbt-github") < 3 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let settled = posts("pbt-github")

        _ = await session.deliver(UlanziDelivery(scene: scene(11)), toTile: "github")

        #expect(posts("pbt-github") == settled)
    }
}
