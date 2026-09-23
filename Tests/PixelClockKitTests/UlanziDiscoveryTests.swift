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

// A sighting is the announcement together with the address it arrived from —
// the one thing the line itself does not carry and the one thing "Add" needs.
// The datagram's source is the device's own, which is what makes the pair
// enough to add a clock from.
@Suite struct UlanziSightingTests {
    /// A datagram from the device on the desk renders as the bare address.
    /// `s_addr` is network byte order: the octets go in wire order, highest
    /// value shifted highest.
    @Test func theDatagramsSourceAddressBecomesTheHost() {
        var from = sockaddr_in()
        from.sin_family = sa_family_t(AF_INET)
        from.sin_addr.s_addr = in_addr_t(72 << 24 | 1 << 16 | 168 << 8 | 192)

        #expect(UlanziBroadcastListener.host(of: from) == "192.168.1.72")
    }

    /// An address that cannot be rendered has nothing to add a clock from,
    /// and a sighting without an address is dropped upstream of the list
    /// rather than becoming a row "Add" cannot act on.
    @Test func anUnrenderableAddressYieldsNoHost() {
        var from = sockaddr_in()
        from.sin_family = sa_family_t(AF_INET6)  // not the family the receiver reads
        from.sin_addr = in_addr(s_addr: INADDR_ANY)

        #expect(UlanziBroadcastListener.host(of: from) == nil)
    }
}

// The read thread's handoff contract. The buffer a datagram lands in is the
// loop's own and is reused for the next datagram the moment the loop turns —
// so whatever the handoff produces must be a COPY the receiver owns, built at
// read time, never a view of bytes the loop is about to overwrite. A race
// here is not deterministically testable; the ownership contract is.

@Suite struct UlanziHandoffTests {
    /// One receive buffer, the shape the loop owns for its whole life.
    private func filledBuffer(
        _ payload: String, capacity: Int = 2048
    ) -> UnsafeMutableRawBufferPointer {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 1)
        // Zeroed first: the handoff test's count reaches one byte past the
        // payload, and an uninitialised byte there is heap garbage — invalid
        // UTF-8 whenever the allocator hands back a dirty block, which a full
        // serial run does.
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        let bytes = Array(payload.utf8)
        bytes.withUnsafeBytes { buffer.copyBytes(from: $0) }
        return buffer
    }

    @Test func theHandoffCopiesTheBytesRatherThanViewingThem() {
        let buffer = filledBuffer(
            "Ulanzi TC002 9b9a:ccc4b2779b9a:B0D32I008U3671403:false"
        )
        defer { buffer.deallocate() }

        let sighting = UlanziBroadcastListener.sighting(
            from: UnsafeRawBufferPointer(buffer), count: 55, host: "192.168.1.72"
        )
        #expect(sighting?.announcement.mac == "ccc4b2779b9a")
        #expect(sighting?.host == "192.168.1.72")

        // The loop turns and the buffer is reused for the next datagram —
        // every received byte of it overwritten. What was handed on is the
        // receiver's own copy and cannot change with it.
        let reuse = [UInt8](repeating: 0x2A, count: 2048)
        reuse.withUnsafeBytes { buffer.copyBytes(from: $0) }
        #expect(sighting?.announcement.mac == "ccc4b2779b9a")
        #expect(sighting?.announcement.serial == "B0D32I008U3671403")
        #expect(sighting?.announcement.model == "TC002")
    }

    // The count is the kernel's word about what it wrote; a count beyond the
    // buffer it wrote into cannot be sliced, it is refused.
    @Test func aCountBeyondTheBufferIsRefused() {
        let buffer = filledBuffer("Ulanzi TC002 9b9a:ccc4b2779b9a:B0D32I008U3671403:false")
        defer { buffer.deallocate() }

        #expect(
            UlanziBroadcastListener.sighting(
                from: UnsafeRawBufferPointer(buffer), count: 2049, host: "192.168.1.72"
            ) == nil
        )
        #expect(
            UlanziBroadcastListener.sighting(
                from: UnsafeRawBufferPointer(buffer), count: 0, host: "192.168.1.72"
            ) == nil
        )
    }

    // A datagram that does not decode is no sighting — same rule as parse.
    @Test func undecodableBytesYieldNoSighting() {
        let buffer = filledBuffer("<html>redirect</html>")
        defer { buffer.deallocate() }

        #expect(
            UlanziBroadcastListener.sighting(
                from: UnsafeRawBufferPointer(buffer), count: 20, host: "192.168.1.72"
            ) == nil
        )
    }

    // And a datagram with no renderable source address is dropped: a sighting
    // without an address cannot become a record "Add" could act on.
    @Test func aSightingWithoutAHostIsDropped() {
        let buffer = filledBuffer(
            "Ulanzi TC002 9b9a:ccc4b2779b9a:B0D32I008U3671403:false"
        )
        defer { buffer.deallocate() }

        #expect(
            UlanziBroadcastListener.sighting(
                from: UnsafeRawBufferPointer(buffer), count: 55, host: nil
            ) == nil
        )
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
