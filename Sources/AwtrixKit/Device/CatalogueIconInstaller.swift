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
        /// The device refused to delete these, and they are still recorded.
        case notRemoved([String])
    }

    /// The format has exactly these two signatures and no others. Six bytes
    /// rather than three because "GIF" alone is not a signature: it is the
    /// prefix of every truncated download that got that far, and of any text
    /// that happens to open with the word.
    private static let signatures = [Data("GIF87a".utf8), Data("GIF89a".utf8)]

    private static let catalogue = "https://developer.lametric.com/content/apps/icon_thumbs"

    private let device: AwtrixDevice
    private let transport: any Transport
    private let uploads: any UploadedIconStore

    /// `uploads` is required rather than defaulted, because this type is the
    /// only party that can tell an upload from a reuse: `ensureInstalled`
    /// returns the same name either way. A default would let a construction
    /// site opt out of recording without saying so, and the icons it then wrote
    /// would be on the device's flash with nothing anywhere able to name them.
    public init(device: AwtrixDevice, transport: any Transport, uploads: any UploadedIconStore) {
        self.device = device
        self.transport = transport
        self.uploads = uploads
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
            // After the upload, never before: an icon that failed to reach the
            // flash is not one this app can be asked to take back off it.
            uploads.record(name)
            return name
        }
    }

    /// Takes back off the flash exactly what this app put on it, and returns the
    /// names removed.
    ///
    /// An explicit action rather than something teardown does, because the
    /// icons are meant to survive quit and relaunch — removing them on the way
    /// out would re-download the same bytes on the way back in, and would do it
    /// while the user was not asking for anything.
    ///
    /// One name forgotten per successful delete, and the refusals reported at
    /// the end with those names still recorded. A device that is unreachable
    /// halfway through leaves real files on real flash, and forgetting them
    /// here would strand them: nothing in this app could ever name them again.
    ///
    /// Every name is tried, rather than stopping at the first refusal. One
    /// stale entry the device answers 404 for would otherwise block every icon
    /// behind it — permanently, since a refused name stays in the record and is
    /// met again on the next attempt, in the same position.
    public func removeUploaded() async throws -> [String] {
        var removed: [String] = []
        var refused: [String] = []
        for name in uploads.uploadedIcons() {
            do {
                try await device.removeIcon(named: name)
                uploads.forget(name)
                removed.append(name)
            } catch {
                refused.append(name)
            }
        }
        guard refused.isEmpty else { throw Failure.notRemoved(refused) }
        return removed
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
