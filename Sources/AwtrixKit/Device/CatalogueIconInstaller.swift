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

    /// Every GIF ever written starts with one of these two, and nothing else
    /// does. Three bytes of "GIF" would also match the word in an error page's
    /// title, which is exactly the body this check exists to reject.
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
        // The CDN answers a default `URLSession` user agent with a challenge
        // page, which would then be rejected below for the wrong reason.
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await transport.send(request)

        // The status is read by nobody, deliberately. A missing id answers with
        // a rendered error page under a 200, so the status line does not track
        // whether the body is an icon — and a body that opens with a GIF
        // signature is one whatever the status says about it.
        guard Self.signatures.contains(where: data.starts(with:)) else {
            throw Failure.notAnImage(id)
        }
        return data
    }
}
