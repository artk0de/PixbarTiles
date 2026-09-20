import Foundation
import Testing
@testable import PixelClockKit

private func json(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func decoded<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(text.utf8))
}

private let moscow = Coordinates(latitude: 55.7558, longitude: 37.6173)
private let pritunl = VPNTileConfig(
    vpn: "pritunl", slot: .topRight, upColour: "#90EE90", whenDown: .blink("#FF0000")
)
private let zaiHandle = ZaiTileConfig(keyAccount: "8C0D2E7A-6A4B-4E5C-9D1F-2B3A4C5D6E7F.zai")

@Test func aTileConfigIsStoredUnderTheConnectorItBelongsTo() throws {
    #expect(try json(TileConfig.weather(moscow)) == #"{"weather":{"latitude":55.7558,"longitude":37.6173}}"#)
    #expect(try json(TileConfig.vpn(pritunl)) == """
    {"vpn":{"slot":"top","upColour":"#90EE90","vpn":"pritunl",\
    "whenDown":{"colour":"#FF0000","kind":"blink"}}}
    """)
    #expect(try json(TileConfig.zai(zaiHandle)) == """
    {"zai":{"keyAccount":"8C0D2E7A-6A4B-4E5C-9D1F-2B3A4C5D6E7F.zai"}}
    """)
}

@Test func aTileConfigSurvivesARoundTrip() throws {
    for config in [TileConfig.weather(moscow), .vpn(pritunl), .zai(zaiHandle)] {
        #expect(try decoded(TileConfig.self, try json(config)) == config)
    }
}

@Test func aConfigNamingTwoConnectorsIsRefused() {
    let both = ##"{"weather":{"latitude":1,"longitude":2},"vpn":{"slot":"top","upColour":"#FFFFFF","vpn":"pritunl","whenDown":{"kind":"off"}}}"##
    #expect(throws: DecodingError.self) { _ = try decoded(TileConfig.self, both) }
    #expect(throws: DecodingError.self) { _ = try decoded(TileConfig.self, "{}") }
}

@Test func eachConfigAnswersOnlyForItsOwnConnector() {
    #expect(TileConfig.weather(moscow).location == moscow)
    #expect(TileConfig.weather(moscow).lamp == nil)
    #expect(TileConfig.vpn(pritunl).lamp == pritunl)
    #expect(TileConfig.vpn(pritunl).location == nil)
    #expect(TileConfig.zai(zaiHandle).key == zaiHandle)
    #expect(TileConfig.zai(zaiHandle).lamp == nil)
    #expect(TileConfig.vpn(pritunl).key == nil)
}

// Phase 1's records carry no config, and they still decode.
@Test func aTileWithoutAConfigStillDecodes() throws {
    let text = """
    {"key":{"clockId":"8C0D2E7A-6A4B-4E5C-9D1F-2B3A4C5D6E7F","connectorId":"claude","instance":""},\
    "policy":{"isPaused":false,"refreshSeconds":300}}
    """
    let tile = try decoded(TileRecord.self, text)

    #expect(tile.config == nil)
    #expect(try json(tile).contains("config") == false)
}
