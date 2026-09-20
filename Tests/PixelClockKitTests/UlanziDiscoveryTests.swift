// Tests/PixelClockKitTests/UlanziDiscoveryTests.swift
import Foundation
import Network
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

// A sighting is the announcement together with the address it arrived from —
// the one thing the line itself does not carry and the one thing "Add" needs.
// The datagram's source is the device's own, which is what makes the pair
// enough to add a clock from.
@Suite struct UlanziSightingTests {
    /// A datagram from the device on the desk renders as the bare address.
    @Test func theDatagramsSourceAddressBecomesTheHost() throws {
        let v4 = try #require(IPv4Address("192.168.1.72"))
        let from = NWEndpoint.hostPort(host: .ipv4(v4), port: 41_952)
        #expect(UlanziBroadcastListener.host(of: from) == "192.168.1.72")
    }

    /// A name-carrying endpoint hands its name over unchanged — the app talks
    /// to hosts it was given, and rewriting one here would be inventing data.
    @Test func aNamedEndpointHandsItsNameOverUnchanged() {
        let from = NWEndpoint.hostPort(
            host: .name("ulanzi.local", nil), port: 41_952
        )
        #expect(UlanziBroadcastListener.host(of: from) == "ulanzi.local")
    }

    /// An endpoint without an address has nothing to add a clock from, and a
    /// sighting without an address is dropped upstream of the list rather than
    /// becoming a row "Add" cannot act on.
    @Test func anEndpointWithoutAnAddressYieldsNoHost() {
        let service = NWEndpoint.service(
            name: "ulanzi", type: "_http._tcp", domain: "", interface: nil
        )
        #expect(UlanziBroadcastListener.host(of: service) == nil)
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
