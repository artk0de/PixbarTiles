import Foundation
import Testing
@testable import PixbarKit

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private let pritunlLamp = VPNTileConfig(
    vpn: "pritunl", slot: .topRight, upColour: "#90EE90", whenDown: .blink("#FF0000")
)
private let amneziaLamp = VPNTileConfig(
    vpn: "amnezia", slot: .bottomRight, upColour: "#A855F7", whenDown: .off
)

@Test func aVPNTileConfigIsWrittenInTheDocumentedShape() throws {
    #expect(try json(pritunlLamp) == """
    {"slot":"top","upColour":"#90EE90","vpn":"pritunl",\
    "whenDown":{"colour":"#FF0000","kind":"blink"}}
    """)
    #expect(try json(amneziaLamp) == """
    {"slot":"bottom","upColour":"#A855F7","vpn":"amnezia","whenDown":{"kind":"off"}}
    """)
}

@Test func aVPNTileConfigSurvivesARoundTrip() throws {
    for config in [pritunlLamp, amneziaLamp] {
        let data = Data(try json(config).utf8)
        #expect(try JSONDecoder().decode(VPNTileConfig.self, from: data) == config)
    }
}

@Test func aLampThisClockDoesNotHaveIsRefused() {
    let text = ##"{"slot":"left","upColour":"#FFFFFF","vpn":"pritunl","whenDown":{"kind":"off"}}"##
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(VPNTileConfig.self, from: Data(text.utf8))
    }
}
