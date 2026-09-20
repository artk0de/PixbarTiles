import Foundation
import Testing
@testable import PixelClockKit

// The two lamps the migration makes out of today's always-on corners, asked
// the questions the old indicator-policy tests asked of what they replace.
// Same names, same answers — the rule moved from one function of the Focus into
// each tile's own policy.

private let desk = UUID()

private func policy(workingIn focuses: Set<MacFocus>) -> TilePolicy {
    TilePolicy(
        refreshSeconds: 60,
        focus: FocusRule(
            silencedIn: Set(MacFocus.allCases).subtracting(focuses).subtracting([.unknown]),
            whenUnknown: .hold
        )
    )
}

private func pritunl(up: Bool) -> LampClaim {
    LampClaim(
        key: TileKey(clockId: desk, connectorId: "vpn", instance: "pritunl"),
        slot: .topRight,
        policy: policy(workingIn: [.work]),
        signal: up ? .steady("#90EE90") : .blinking("#FF0000", everyMilliseconds: 500)
    )
}

private func amnezia(up: Bool) -> LampClaim {
    LampClaim(
        key: TileKey(clockId: desk, connectorId: "vpn", instance: "amnezia"),
        slot: .bottomRight,
        policy: policy(workingIn: [.work, .personal]),
        signal: up ? .steady("#A855F7") : .off
    )
}

private func lamps(_ claims: [LampClaim], in focus: MacFocus) -> [IndicatorSlot: IndicatorSignal] {
    LampBoard.lamps(claims, in: focus, atHour: 12)
}

@Test func workWithoutItsTunnelBlinksTheTopCorner() {
    let shown = lamps([pritunl(up: false), amnezia(up: false)], in: .work)

    #expect(shown[.topRight] == .blinking("#FF0000", everyMilliseconds: 500))
}

@Test func workWithItsTunnelGoesQuietlyGreen() {
    #expect(lamps([pritunl(up: true), amnezia(up: false)], in: .work)[.topRight] == .steady("#90EE90"))
}

@Test func thePersonalTunnelIsWatchedUnderBothFocuses() {
    for focus: MacFocus in [.work, .personal] {
        #expect(lamps([pritunl(up: false), amnezia(up: true)], in: focus)[.bottomRight] == .steady("#A855F7"))
    }
}

@Test func personalFocusSaysNothingAboutTheWorkTunnel() {
    for up in [false, true] {
        #expect(lamps([pritunl(up: up), amnezia(up: true)], in: .personal)[.topRight] == .off)
    }
}

@Test func everyOtherFocusLeavesBothCornersDark() {
    for focus: MacFocus in [.noFocus, .doNotDisturb, .sleep] {
        #expect(
            lamps([pritunl(up: false), amnezia(up: true)], in: focus)
                == [.topRight: .off, .bottomRight: .off],
            "\(focus)"
        )
    }
}

@Test func aFocusThatCannotBeNamedClaimsNothing() {
    #expect(
        lamps([pritunl(up: false), amnezia(up: true)], in: .unknown)
            == [.topRight: .off, .bottomRight: .off]
    )
}

// MARK: - Sharing a lamp

private func other(on slot: IndicatorSlot, workingIn focuses: Set<MacFocus>) -> LampClaim {
    LampClaim(
        key: TileKey(clockId: desk, connectorId: "vpn", instance: "other"),
        slot: slot,
        policy: policy(workingIn: focuses),
        signal: .steady("#00F0FF")
    )
}

@Test func aSharedLampBelongsToWhicheverTileRunsNow() {
    let claims = [pritunl(up: true), other(on: .topRight, workingIn: [.personal])]

    #expect(lamps(claims, in: .work)[.topRight] == .steady("#90EE90"))
    #expect(lamps(claims, in: .personal)[.topRight] == .steady("#00F0FF"))
    #expect(lamps(claims, in: .noFocus)[.topRight] == .off)
}

@Test func whenTwoClaimsRunAtOnceTheFirstHoldsTheLamp() {
    let claims = [pritunl(up: true), other(on: .topRight, workingIn: [.work])]

    #expect(lamps(claims, in: .work)[.topRight] == .steady("#90EE90"))
    #expect(lamps(claims.reversed(), in: .work)[.topRight] == .steady("#00F0FF"))
}

// A lamp nobody claims is somebody else's — another integration may be using
// the middle one — so it is not written at all.
@Test func onlyTheLampsInPlayAreAnswered() {
    #expect(Set(lamps([pritunl(up: true)], in: .work).keys) == [.topRight])
}

@Test func aLampWhoseLastClaimWentAwayIsPutOut() {
    let shown = LampBoard.lamps([], covering: [.middleRight], in: .work, atHour: 12)

    #expect(shown == [.middleRight: .off])
}

@Test func theHoursDecideTooNotOnlyTheFocus() {
    var office = pritunl(up: true)
    office = LampClaim(
        key: office.key, slot: office.slot,
        policy: TilePolicy(refreshSeconds: 60, window: .active(HourWindow(startHour: 10, endHour: 19))),
        signal: office.signal
    )

    #expect(LampBoard.lamps([office], in: .work, atHour: 9)[.topRight] == .off)
    #expect(LampBoard.lamps([office], in: .work, atHour: 10)[.topRight] == .steady("#90EE90"))
}
