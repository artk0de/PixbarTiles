import Foundation
import Testing
@testable import PixelClockKit

// MARK: - The address a browse already knows

// The whole feature rests on this one fact, so it is pinned rather than
// assumed. The firmware advertises `awtrix_<mac-suffix>` AND answers to that
// same name under `.local` — measured against the clock on the desk, where
// `awtrix_a07f9c.local` resolved to 192.168.1.67 and served `/api/stats`. The
// comment this replaces claimed a browse could not know an address at all,
// which is why nothing was ever built on top of one.
@Test func theInstanceNameIsAlsoTheHostTheClockAnswersOn() {
    let device = DiscoveredDevice(instanceName: "awtrix_a07f9c")

    #expect(device.host == "awtrix_a07f9c.local")
}

// MARK: - Which clock, if any, may be moved to

// The remembered clock is THE clock: it is the one whose readings are in the
// battery history and whose overlay this app borrowed. A neighbour's device
// advertising alongside it is not a tie to be broken, it is somebody else's.
@Test func theRememberedClockIsTakenEvenFromACrowd() {
    let chosen = DeviceAdoption.candidate(
        remembering: "awtrix_a07f9c",
        among: [
            DiscoveredDevice(instanceName: "awtrix_ff0102"),
            DiscoveredDevice(instanceName: "awtrix_a07f9c"),
        ]
    )

    #expect(chosen == DiscoveredDevice(instanceName: "awtrix_a07f9c"))
}

// A first launch has nothing remembered, and one clock on the network is not a
// guess — there is nothing else it could be.
@Test func theOnlyClockOnTheNetworkIsTakenWhenNoneIsRemembered() {
    let chosen = DeviceAdoption.candidate(
        remembering: nil, among: [DiscoveredDevice(instanceName: "awtrix_a07f9c")]
    )

    #expect(chosen == DiscoveredDevice(instanceName: "awtrix_a07f9c"))
}

// Two strangers and no memory is the one case where picking would be picking
// for the user — and picking silently would point this app at somebody else's
// clock, write to their overlay, and put an app in their loop.
@Test func noClockIsTakenFromACrowdOfStrangers() {
    let chosen = DeviceAdoption.candidate(
        remembering: nil,
        among: [
            DiscoveredDevice(instanceName: "awtrix_a07f9c"),
            DiscoveredDevice(instanceName: "awtrix_ff0102"),
        ]
    )

    #expect(chosen == nil)
}

// The dangerous case, and the reason the memory is consulted before the count.
// Our clock is unplugged and a neighbour's is advertising: exactly one device
// is on the network, and taking it would move this app onto a stranger without
// anybody being told. Knowing which clock is ours makes "only one here" the
// wrong question.
@Test func aStrangerIsNotTakenWhileAParticularClockIsRemembered() {
    let chosen = DeviceAdoption.candidate(
        remembering: "awtrix_a07f9c", among: [DiscoveredDevice(instanceName: "awtrix_ff0102")]
    )

    #expect(chosen == nil)
}

@Test func nothingIsTakenFromAnEmptyNetwork() {
    #expect(DeviceAdoption.candidate(remembering: "awtrix_a07f9c", among: []) == nil)
    #expect(DeviceAdoption.candidate(remembering: nil, among: []) == nil)
}

// The uid is read off `/api/stats` and the instance name off a Bonjour browse:
// two paths out of the same firmware, and nothing promises they agree on case.
// `DeviceDiscovery.isAwtrixInstance` already lowercases for the same reason.
@Test func theRememberedClockIsMatchedWhateverTheCase() {
    let chosen = DeviceAdoption.candidate(
        remembering: "AWTRIX_A07F9C", among: [DiscoveredDevice(instanceName: "awtrix_a07f9c")]
    )

    #expect(chosen == DiscoveredDevice(instanceName: "awtrix_a07f9c"))
}

// MARK: - Proving the clock at the address is the clock that was found

// `<name>.local` is a construction, not a fact, and mDNS is a cache that can be
// stale. Asking the address who it is turns the construction into evidence, so
// that an adoption is never a guess that happened to answer.
@Test func aClockThatAnswersToItsOwnNameIsTheOneThatWasFound() {
    let device = DiscoveredDevice(instanceName: "awtrix_a07f9c")

    #expect(DeviceAdoption.isTheSameClock("awtrix_a07f9c", as: device))
}

@Test func aClockThatAnswersToAnotherNameIsNotTheOneThatWasFound() {
    let device = DiscoveredDevice(instanceName: "awtrix_a07f9c")

    #expect(DeviceAdoption.isTheSameClock("awtrix_ff0102", as: device) == false)
}

@Test func theAnswersOwnNameIsMatchedWhateverTheCase() {
    let device = DiscoveredDevice(instanceName: "awtrix_a07f9c")

    #expect(DeviceAdoption.isTheSameClock("AWTRIX_A07F9C", as: device))
}

// MARK: - Moving the app onto the new address

// The whole point of the feature: the device is an actor built once and held by
// the monitor, the custody and every connector, so re-pointing it re-points all
// of them at once. A new `AwtrixDevice` would leave every existing holder
// talking to the address that stopped answering.
@Test func requestsAfterAnAdoptionGoToTheNewAddress() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "192.168.1.72", transport: transport)

    try await device.notify(NotifyPayload(text: "before"))
    await device.adopt(host: "awtrix_a07f9c.local")
    try await device.notify(NotifyPayload(text: "after"))

    #expect(transport.requests.map { $0.url?.absoluteString } == [
        "http://192.168.1.72/api/notify",
        "http://awtrix_a07f9c.local/api/notify",
    ])
}

// The initialiser normalises what it is handed because the field is not its
// only caller; an adoption is a third caller and gets the same treatment, so
// there is no way into this actor that skips the rule.
@Test func anAdoptedAddressIsNormalisedTheWayATypedOneIs() async throws {
    let transport = RecordingTransport()
    let device = AwtrixDevice(host: "192.168.1.72", transport: transport)

    await device.adopt(host: "http://10.0.0.5/")
    try await device.notify(NotifyPayload(text: "after"))

    #expect(transport.requests.map { $0.url?.absoluteString } == [
        "http://10.0.0.5/api/notify"
    ])
}
