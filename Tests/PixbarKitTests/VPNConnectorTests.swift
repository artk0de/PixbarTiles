import Foundation
import Testing
@testable import PixbarKit

private let pritunlLamp = VPNTileConfig(
    vpn: "pritunl", slot: .topRight, upColour: "#90EE90", whenDown: .blink("#FF0000")
)
private let amneziaLamp = VPNTileConfig(
    vpn: "amnezia", slot: .bottomRight, upColour: "#A855F7", whenDown: .off
)

@Test func upIsTheTilesColourSteady() {
    #expect(VPNConnector.signal(for: VPNReading(isUp: true, lamp: pritunlLamp)) == .steady("#90EE90"))
}

@Test func downIsDarkOrABlinkAsTheTileSays() {
    #expect(VPNConnector.signal(for: VPNReading(isUp: false, lamp: amneziaLamp)) == .off)
    #expect(
        VPNConnector.signal(for: VPNReading(isUp: false, lamp: pritunlLamp))
            == .blinking("#FF0000", everyMilliseconds: 500)
    )
}

@Test func theReadingAsksAboutTheTilesOwnVPN() async throws {
    let asked = Asked()
    let connector = VPNConnector { vpn in asked.record(vpn.id); return vpn == .amnezia }

    let reading = try await connector.read(config: amneziaLamp)

    #expect(reading == VPNReading(isUp: true, lamp: amneziaLamp))
    #expect(asked.ids == ["amnezia"])
}

// A preset gone from the catalogue is a failed read, not a dark lamp that
// says "down" about a VPN nobody can watch any more.
@Test func aVPNTheCatalogueNoLongerCarriesIsAFailedReadNotADarkLamp() async {
    var gone = pritunlLamp
    gone.vpn = "wireguard"

    await #expect(throws: VPNConnectorError.unknownVPN("wireguard")) {
        _ = try await VPNConnector(isUp: { _ in false }).read(config: gone)
    }
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var ids: [String] { lock.withLock { recorded } }
    func record(_ id: String) { lock.withLock { recorded.append(id) } }
}
