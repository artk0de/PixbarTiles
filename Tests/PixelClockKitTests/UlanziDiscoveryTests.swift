// Tests/PixelClockKitTests/UlanziDiscoveryTests.swift
import Foundation
import Testing
@testable import PixelClockKit

@Suite struct UlanziAnnouncementTests {
    @Test func parsesTheCapturedBroadcastLine() {
        let line = "Ulanzi TC002 9b9a:ccc4b2779b9a:B0D32I008U3671403:false"
        let announcement = UlanziAnnouncement.parse(line)
        #expect(announcement?.model == "TC002")
        #expect(announcement?.mac == "ccc4b2779b9a")
        #expect(announcement?.serial == "B0D32I008U3671403")
        #expect(announcement?.flag == "false")   // meaning unverified (research A1)
    }

    @Test func malformedLinesAreDropped() {
        #expect(UlanziAnnouncement.parse("") == nil)
        #expect(UlanziAnnouncement.parse("garbage") == nil)
        #expect(UlanziAnnouncement.parse("Ulanzi TC002 nope") == nil)
        #expect(UlanziAnnouncement.parse("Ulanzi TC002 one:two:three") == nil)
    }
}

@Suite struct UlanziProbeTests {
    /// `/api/stats` answers a body the AWTRIX stats shape decodes — an AWTRIX
    /// clock, whatever status it answered the TC002 path with.
    @Test func statsDecodingWinsMeansOtherDevice() async {
        let transport = RecordingTransport()
        transport.body = Data(
            #"{"bat":83,"ram":139112,"version":"0.98","uid":"awtrix_a07f9c","ip_address":"192.168.1.72"}"#
                .utf8
        )

        let detection = await UlanziProbe.detect(host: "10.0.0.5", transport: transport)

        #expect(detection == .otherDevice)
    }

    /// `/getBase` answers the captured identity — a TC002 (research A2).
    @Test func baseDecodingWinsMeansUlanzi() async {
        let transport = RecordingTransport()
        transport.body = Data(
            #"{"devSn":"B0D32I008U3671403","ssid":"home","ip":"192.168.1.72","mac":"ccc4b2779b9a","mcuVer":"V1.0.17","appVer":"1.1.1"}"#
                .utf8
        )

        let detection = await UlanziProbe.detect(host: "10.0.0.5", transport: transport)

        #expect(
            detection == .ulanzi(
                UlanziIdentity(
                    serial: "B0D32I008U3671403", mac: "ccc4b2779b9a", ip: "192.168.1.72",
                    mcuVersion: "V1.0.17", appVersion: "1.1.1"
                )
            )
        )
    }

    @Test func neitherDecodesMeansUndetermined() async {
        // the host is down or answers nothing decodable; statuses never decide
        let transport = RecordingTransport()
        transport.body = Data("<html>redirect</html>".utf8)

        let detection = await UlanziProbe.detect(host: "10.0.0.5", transport: transport)

        #expect(detection == .undetermined)
    }
}
