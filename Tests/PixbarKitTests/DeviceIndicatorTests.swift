import Foundation
import Testing
@testable import PixbarKit

private func body(_ request: URLRequest) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
}

// Which lamp each number is was MEASURED, not read off a page. Every slot was
// set to magenta on the clock at 192.168.1.72 and the framebuffer read back
// through `/api/screen`: indicator1 lit (0,30)(0,31)(1,31), indicator2 lit
// (3,31)(4,31), indicator3 lit (6,31)(7,30)(7,31) — top, middle and bottom of
// the two rightmost columns. The names below say the position rather than the
// number, so a caller asking for the top-right corner cannot get the middle.
@Test func eachSlotIsNumberedAsTheClockWasMeasuredToLightIt() {
    #expect(IndicatorSlot.topRight.rawValue == 1)
    #expect(IndicatorSlot.middleRight.rawValue == 2)
    #expect(IndicatorSlot.bottomRight.rawValue == 3)
}

@Test func aSteadyLampPostsItsColourToItsOwnEndpoint() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    try await device.setIndicator(.bottomRight, to: .steady("#A855F7"))

    let request = try #require(transport.requests.first)
    #expect(request.url?.path == "/api/indicator3")
    #expect(request.httpMethod == "POST")
    #expect(try body(request)["color"] as? String == "#A855F7")
    // No `blink` key at all rather than a zero. The firmware blinks on the
    // presence of the key, and a lamp that never asked to blink should not have
    // to say how fast it is not blinking.
    #expect(try body(request)["blink"] == nil)
}

// The blinking is the firmware's, which is the entire reason an indicator can
// carry an alarm for free: nothing here polls, nothing re-posts, and the corner
// keeps flashing through app rotation and through this app being asleep.
@Test func aBlinkingLampAsksTheFirmwareToDoTheBlinking() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    try await device.setIndicator(.topRight, to: .blinking("#FF0000", everyMilliseconds: 500))

    let request = try #require(transport.requests.first)
    #expect(request.url?.path == "/api/indicator1")
    #expect(try body(request)["color"] as? String == "#FF0000")
    #expect(try body(request)["blink"] as? Int == 500)
}

// `"0"`, which is what the firmware takes for "off" and what cleared all three
// lamps after the pixel probe above.
@Test func clearingALampSendsTheZeroTheFirmwareUnderstands() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)

    try await device.setIndicator(.middleRight, to: .off)

    let request = try #require(transport.requests.first)
    #expect(request.url?.path == "/api/indicator2")
    #expect(try body(request)["color"] as? String == "0")
    #expect(try body(request)["blink"] == nil)
}
