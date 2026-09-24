// Tests/PixelClockKitTests/UlanziDeviceTests.swift
import Foundation
import Testing
@testable import PixelClockKit

/// Builds a device over a recorder pre-loaded with one canned answer.
private func makeDevice(status: Int, body: Data) -> (UlanziDevice, RecordingTransport) {
    let transport = RecordingTransport()
    transport.status = status
    transport.body = body
    return (UlanziDevice(host: "192.168.1.72", transport: transport), transport)
}

@Suite struct UlanziDeviceSendTests {
    let ok = Data(#"{"code":200,"message":"ok"}"#.utf8)

    @Test func showAppPostsNamedCustomWithDbBody() async throws {
        var canvas = PixelCanvas()
        canvas.fill(.white)
        let frame = UlanziFrame(duration: 5, draw: [canvas.drawCommands()])
        let (device, recorder) = makeDevice(status: 200, body: ok)
        try await device.showApp(frame, named: "pct-weather")

        let request = try #require(recorder.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/custom")
        #expect(request.url?.query == "name=pct-weather")
        // The body is the frame JSON — draw[] carries the single db command.
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["duration"] as? Int == 5)
        #expect((json["draw"] as? [[String: Any]])?.count == 1)
        let bitmap = try #require((json["draw"] as? [[String: Any]])?[0]["db"] as? [Any])
        #expect(bitmap.count == 5)  // [x, y, w, h, [pixels]]
        #expect((bitmap[4] as? [Int])?.count == 52 * 16)
    }

    @Test func removeAppPostsEmptyBody() async throws {
        let (device, recorder) = makeDevice(status: 200, body: ok)
        try await device.removeApp(named: "pct-weather")

        let request = try #require(recorder.requests.last)
        #expect(request.url?.query == "name=pct-weather")
        // AWTRIX-family delete: an EMPTY body. The absence of a body IS the
        // contract — the send test pins it (research §2.2).
        #expect(request.httpBody ?? Data() == Data())
        #expect(request.httpBodyStream == nil)
    }

    @Test func bodyCodeOtherThanTwoHundredIsAFailure() async {
        // HTTP 200, body code 101 → failure (D8)
        do {
            let (device, _) = makeDevice(
                status: 200, body: Data(#"{"code":101,"message":"busy"}"#.utf8)
            )
            try await device.showApp(UlanziScene.idle.frames[0], named: "pct-x")
            Issue.record("expected throw")
        } catch let error as UlanziError {
            #expect(error == .deviceRejected(code: 101, message: "busy"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func httpFailureIsAFailure() async {
        do {
            let (device, _) = makeDevice(status: 500, body: ok)
            try await device.showApp(UlanziScene.idle.frames[0], named: "pct-x")
            Issue.record("expected throw")
        } catch let error as UlanziError {
            #expect(error == .unexpectedStatus(500))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    /// The one captured `customList` answer this suite stands on. The research
    /// capture it mirrors is the payload the decoder must survive; the exact
    /// schema is re-confirmed on hardware before release (Task 11 checklist).
    static let customListBody = Data(
        #"{"code":200,"message":"ok","data":["ani_partly_cloudy","weather","pct-weather"]}"#.utf8
    )

    @Test func customListDecodesTheCapturedBody() async throws {
        let (device, recorder) = makeDevice(status: 200, body: Self.customListBody)
        let names = try await device.customApps()
        #expect(recorder.requests.first?.url?.path == "/api/customList")
        #expect(!names.isEmpty)
        #expect(names.contains("pct-weather"))
    }

    /// What appVer 1.1.1 actually answers, captured from the clock on
    /// 2026-09-24: the names under `apps`, a count, and NO `code` envelope.
    /// The sweep and the page-switch check both read this list, so a decoder
    /// that demanded the envelope failed every one of them on hardware.
    @Test func customListDecodesTheBodyTheClockAnswersBare() async throws {
        let (device, _) = makeDevice(
            status: 200,
            body: Data(#"{"apps":["pct-claude","pct-weather","pct-zai"],"count":3}"#.utf8)
        )
        #expect(try await device.customApps() == ["pct-claude", "pct-weather", "pct-zai"])
    }

    /// An envelope that does come back with a failing code is still a refusal.
    @Test func customListWithAFailingCodeIsRejected() async {
        do {
            let (device, _) = makeDevice(
                status: 200, body: Data(#"{"code":101,"message":"busy"}"#.utf8)
            )
            _ = try await device.customApps()
            Issue.record("expected throw")
        } catch let error as UlanziError {
            #expect(error == .deviceRejected(code: 101, message: "busy"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    /// A body with no names in it is not a failure to reach the device — the
    /// list is simply empty, which the sweep reads as "nothing of ours there".
    @Test func customListWithNoNamesIsEmpty() async throws {
        let (device, _) = makeDevice(status: 200, body: Data(#"{"code":200,"message":"ok"}"#.utf8))
        #expect(try await device.customApps() == [])
    }

    @Test func identityDecodesTheCapturedBase() async throws {
        let base = Data(
            #"{"devSn":"B0D32I008U3671403","ssid":"home","ip":"192.168.1.72","mac":"ccc4b2779b9a","mcuVer":"V1.0.17","appVer":"1.1.1"}"#
                .utf8
        )
        let (device, recorder) = makeDevice(status: 200, body: base)
        let identity = try await device.identity()
        #expect(recorder.requests.first?.url?.path == "/getBase")
        #expect(identity.serial == "B0D32I008U3671403")
        #expect(identity.mac == "ccc4b2779b9a")
        #expect(identity.mcuVersion == "V1.0.17")
        #expect(identity.ip == "192.168.1.72")
        #expect(identity.appVersion == "1.1.1")
    }

    /// `/getBase` answers the identity bare — no `code` envelope — so a body
    /// the identity cannot be read from is malformed rather than rejected.
    @Test func unparseableIdentityIsMalformed() async {
        do {
            let (device, _) = makeDevice(status: 200, body: Data("not json".utf8))
            _ = try await device.identity()
            Issue.record("expected throw")
        } catch let error as UlanziError {
            #expect(error == .malformed("/getBase did not answer an identity"))
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }
}

@Suite struct UlanziDeviceTests {
    /// An address pasted with its scheme is normalised the way every other
    /// device actor normalises it, so a device built from the panel's field
    /// asks the clock rather than a host named `http`.
    @Test func aPastedAddressIsNormalisedIntoTheHost() async throws {
        let transport = RecordingTransport()
        transport.body = Data(
            #"{"devSn":"S","ssid":"x","ip":"10.0.0.5","mac":"m","mcuVer":"1","appVer":"1"}"#.utf8
        )
        let device = UlanziDevice(host: "http://10.0.0.5/", transport: transport)

        _ = try await device.identity()

        #expect(transport.requests.first?.url?.host == "10.0.0.5")
        #expect(transport.requests.first?.url?.absoluteString == "http://10.0.0.5/getBase")
    }
}
