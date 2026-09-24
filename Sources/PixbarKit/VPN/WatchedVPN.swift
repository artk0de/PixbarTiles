// Sources/PixbarKit/VPN/WatchedVPN.swift
import Foundation

/// A VPN this app can watch, described by where its tunnel runs from.
///
/// Two fields rather than one name, because neither alone is enough: both apps
/// ship a binary called `wireguard-go`, and both keep a daemon running from
/// login to shutdown. The bundle says WHOSE process it is and the binary says
/// whether it is a tunnel — and the question needs both answers.
///
/// A catalogue entry rather than something a user describes: nobody can be
/// asked for a bundle path and a list of tunnel binaries, so a new VPN is added
/// here, in code.
public struct WatchedVPN: Sendable, Equatable {
    /// What a VPN tile stores to name its VPN, and its key's instance.
    public let id: String
    /// What the tile row, the tile detail and a lamp refusal call it.
    public let displayName: String
    /// The application bundle the process must have come out of.
    public let bundle: String
    /// The binaries that exist only while a tunnel is up.
    ///
    /// Deliberately not the app itself and not its service: `pritunl-service`
    /// and `AmneziaVPN-service` are started with the login session and run with
    /// nothing connected. They are what ACCEPTS a connection rather than what
    /// is one, and a detector that watched them would report both VPNs up from
    /// the moment the Mac finished booting.
    public let tunnelBinaries: Set<String>

    public static let pritunl = WatchedVPN(
        id: "pritunl",
        displayName: "Pritunl",
        bundle: "/Applications/Pritunl.app/",
        tunnelBinaries: ["pritunl-openvpn", "pritunl-openvpn10", "wireguard-go"]
    )

    /// Amnezia carries a tunnel over whichever protocol its profile selects,
    /// and the user can change that without this app being told — so the set is
    /// the protocol list, not one name.
    public static let amnezia = WatchedVPN(
        id: "amnezia",
        displayName: "Amnezia",
        bundle: "/Applications/AmneziaVPN.app/",
        tunnelBinaries: [
            "wireguard-go", "openvpn", "tun2socks", "ck-client", "ss-local", "ss-tunnel",
        ]
    )

    /// Every VPN a tile can watch, in the order the tile detail offers them.
    public static let catalogue: [WatchedVPN] = [.pritunl, .amnezia]

    public static func preset(id: String) -> WatchedVPN? {
        catalogue.first { $0.id == id }
    }
}
