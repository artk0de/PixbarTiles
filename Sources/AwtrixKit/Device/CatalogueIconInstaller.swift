import Foundation

/// Installs icons on demand, skipping ones the device already holds.
///
/// Two hosts, one transport: the listing and the upload go to the clock, the
/// download goes to LaMetric's CDN. `device` owns the first two because it owns
/// the flash layout; the download is a plain GET this type makes itself.
public struct CatalogueIconInstaller: IconInstalling {
    public enum Failure: Error, Sendable, Equatable {
        /// The catalogue answered for this id with something that is not a GIF.
        case notAnImage(Int)
    }

    /// The format has exactly these two signatures and no others. Six bytes
    /// rather than three because "GIF" alone is not a signature: it is the
    /// prefix of every truncated download that got that far, and of any text
    /// that happens to open with the word.
    private static let signatures = [Data("GIF87a".utf8), Data("GIF89a".utf8)]

    private static let catalogue = "https://developer.lametric.com/content/apps/icon_thumbs"

    private let device: AwtrixDevice
    private let transport: any Transport

    public init(device: AwtrixDevice, transport: any Transport) {
        self.device = device
        self.transport = transport
    }

    public func ensureInstalled(_ reference: IconReference) async throws -> String {
        switch reference {
        case let .installed(name):
            // Taken at its word. The device is not asked to confirm it, because
            // the answer would only ever be used to fail a delivery over an
            // icon — and a banner with a missing icon still reads.
            return name
        case let .catalogue(id):
            // `id` is an `Int`, so the name it produces cannot contain a slash
            // or a `..` — nothing from the catalogue picks the path it lands on.
            let name = String(id)
            let present = try await device.list("/ICONS")
            guard !present.contains(where: { $0.name == "\(name).gif" }) else {
                return name
            }
            try await device.installIcon(download(id: id), named: name)
            return name
        }
    }

    private func download(id: Int) async throws -> Data {
        // Interpolating an `Int` into a constant that is already a valid URL
        // cannot produce one that is not.
        var request = URLRequest(url: URL(string: "\(Self.catalogue)/\(id).gif")!)
        // Not a reproduced requirement: checked on 2026-08-18, this CDN serves
        // the icon identically under a browser agent, a default client agent
        // and none at all. Sent because gating on a default agent is a common
        // thing for a CDN to start doing and this costs nothing, and asserted
        // in the tests so that removing it is a decision rather than a drift.
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await transport.send(request)

        // The status is read by nobody, deliberately — though not for the
        // reason the plan gave. Checked on 2026-08-18, a bogus id answers 404
        // with an HTML page, so the status IS honest about that particular
        // case. The bytes are still the authority because they are the stricter
        // test: they reject the same 404 page, and they also reject a 200
        // carrying HTML, which is what a WAF, a captive portal or a CDN error
        // page serves and what a status check would happily install.
        //
        // What this trades away: a non-2xx carrying a real GIF — a placeholder
        // image, say — would be installed, and the skip-by-name check above
        // would then leave it on the flash for good, since nothing revisits an
        // icon that is already there. No such body exists on this CDN today;
        // its error bodies are HTML.
        guard Self.signatures.contains(where: data.starts(with:)) else {
            throw Failure.notAnImage(id)
        }
        return data
    }
}
