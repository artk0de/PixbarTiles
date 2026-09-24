import Foundation
import Testing
@testable import PixbarTilesApp

private func presence(_ paths: String...) -> VPNPresence {
    VPNPresence(processes: FixedProcessList(paths: paths))
}

/// The process table of this machine with both tunnels up, captured 2026-08-26.
///
/// Every path here was resolved through `proc_pidpath`, root-owned processes
/// included — which is the measurement that let this be a C call rather than a
/// shelled-out `ps`: 612 of 613 paths came back, and the one refusal was not a
/// VPN.
private let bothUp = [
    "/Applications/Pritunl.app/Contents/Resources/pritunl-service",
    "/Applications/Pritunl.app/Contents/MacOS/Pritunl",
    "/Applications/Pritunl.app/Contents/Frameworks/Pritunl Helper.app/Contents/MacOS/Pritunl Helper",
    "/Applications/Pritunl.app/Contents/Resources/pritunl-openvpn",
    "/Applications/AmneziaVPN.app/Contents/MacOS/AmneziaVPN-service",
    "/Applications/AmneziaVPN.app/Contents/MacOS/AmneziaVPN",
    "/Applications/AmneziaVPN.app/Contents/MacOS/wireguard-go",
    "/usr/libexec/sandboxd",
]

@Test func bothTunnelsAreSeenInACaptureOfThisMachine() {
    let live = VPNPresence(processes: FixedProcessList(paths: bothUp))

    #expect(live.isUp(.pritunl))
    #expect(live.isUp(.amnezia))
}

// The two apps each ship a binary called `wireguard-go` — Pritunl's under
// `Contents/Resources`, Amnezia's under `Contents/MacOS`. So the BUNDLE is what
// tells them apart, never the name. A detector keyed on the name would report
// both VPNs up whenever either one was, and would be right half the time, which
// is the expensive kind of wrong: the work corner would go green on the
// strength of the personal tunnel.
@Test func theBundleTellsTheTwoWireguardsApart() {
    let amneziaOnly = presence("/Applications/AmneziaVPN.app/Contents/MacOS/wireguard-go")
    #expect(amneziaOnly.isUp(.amnezia))
    #expect(amneziaOnly.isUp(.pritunl) == false)

    let pritunlOnly = presence("/Applications/Pritunl.app/Contents/Resources/wireguard-go")
    #expect(pritunlOnly.isUp(.pritunl))
    #expect(pritunlOnly.isUp(.amnezia) == false)
}

// The daemons are the obvious thing to look for and they answer a different
// question. Measured on this machine: both were started at 12:14 with the
// session and were still running with nothing connected — they are the thing
// that ACCEPTS a connection, not the thing that IS one.
@Test func aServiceDaemonIsNotEvidenceOfATunnel() {
    let idle = presence(
        "/Applications/Pritunl.app/Contents/Resources/pritunl-service",
        "/Applications/AmneziaVPN.app/Contents/MacOS/AmneziaVPN-service",
        "/Applications/Pritunl.app/Contents/MacOS/Pritunl",
        "/Applications/AmneziaVPN.app/Contents/MacOS/AmneziaVPN"
    )

    #expect(idle.isUp(.pritunl) == false)
    #expect(idle.isUp(.amnezia) == false)
}

// Amnezia can carry a tunnel over any of several protocols, and the user can
// switch between them without this app being told. Each one runs a different
// binary out of the same bundle, so the set is the protocol list rather than a
// single name.
@Test func amneziaIsSeenWhicheverProtocolItIsCarrying() {
    for binary in ["wireguard-go", "openvpn", "tun2socks", "ck-client", "ss-local", "ss-tunnel"] {
        let running = presence("/Applications/AmneziaVPN.app/Contents/MacOS/\(binary)")
        #expect(running.isUp(.amnezia), "\(binary) went unnoticed")
    }
}

@Test func pritunlIsSeenOnEitherOpenVPNBuild() {
    for binary in ["pritunl-openvpn", "pritunl-openvpn10", "wireguard-go"] {
        let running = presence("/Applications/Pritunl.app/Contents/Resources/\(binary)")
        #expect(running.isUp(.pritunl), "\(binary) went unnoticed")
    }
}

// A binary of the right name from somewhere else entirely — Homebrew's
// wireguard-go, a copy in Downloads — is not this VPN and must not light its
// lamp.
@Test func aTunnelBinaryFromSomewhereElseIsNotThisVPN() {
    let stranger = presence(
        "/opt/homebrew/bin/wireguard-go",
        "/Users/artk0re/Downloads/AmneziaVPN.app/Contents/MacOS/wireguard-go",
        "/usr/local/sbin/pritunl-openvpn"
    )

    #expect(stranger.isUp(.amnezia) == false)
    #expect(stranger.isUp(.pritunl) == false)
}

@Test func nothingRunningMeansNothingIsUp() {
    let empty = VPNPresence(processes: FixedProcessList(paths: []))

    #expect(empty.isUp(.pritunl) == false)
    #expect(empty.isUp(.amnezia) == false)
}
