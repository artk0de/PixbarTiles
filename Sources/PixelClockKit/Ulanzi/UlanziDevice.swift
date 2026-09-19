import Foundation

/// What the clock says about itself. Field names below are the firmware's, not
/// Swift's; everything is optional because no firmware is obliged to answer
/// any of it and a missing field is not a missing device.
public struct UlanziIdentity: Codable, Sendable, Equatable {
    public let serial: String?      // devSn
    public let mac: String?
    public let ip: String?
    public let mcuVersion: String?  // mcuVer
    public let appVersion: String?  // appVer

    private enum CodingKeys: String, CodingKey {
        case serial = "devSn"
        case mac, ip
        case mcuVersion = "mcuVer"
        case appVersion = "appVer"
    }

    public init(
        serial: String?, mac: String?, ip: String?, mcuVersion: String?, appVersion: String?
    ) {
        self.serial = serial
        self.mac = mac
        self.ip = ip
        self.mcuVersion = mcuVersion
        self.appVersion = appVersion
    }
}

/// The TC002 HTTP adapter. Endpoints phase 3 needs and nothing else — there is
/// no `switchDiyApp` here (D3): the knob belongs to the user, and this type
/// never turns it.
public actor UlanziDevice {
    private var host: String
    private let transport: any Transport

    /// Normalised like every other device actor, so a pasted address from a
    /// settings field asks the clock rather than a host named `http`.
    public init(host: String, transport: any Transport) {
        self.host = DeviceAddress.host(from: host) ?? host
        self.transport = transport
    }

    /// Points this device at a new address, the way `AwtrixDevice.adopt` does:
    /// a shared instance re-pointed, never a second one built.
    public func adopt(host: String) {
        self.host = DeviceAddress.host(from: host) ?? host
    }

    // MARK: reading

    /// GET /getBase — the only identity surface this firmware answers. It
    /// replies bare, with no `code` envelope around the identity.
    public func identity() async throws -> UlanziIdentity {
        let data = try await perform("GET", "/getBase")
        guard let identity = try? JSONDecoder().decode(UlanziIdentity.self, from: data) else {
            throw UlanziError.malformed("/getBase did not answer an identity")
        }
        return identity
    }

    /// GET /api/customList — the app names the clock currently carries.
    public func customApps() async throws -> [String] {
        let data = try await envelope("GET", "/api/customList")
        // Names absent is an empty page set, not a failure: a fresh clock has
        // nothing to list, and the sweep reads that as "nothing of ours there".
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0["data"] as? [String] } ?? []
    }

    // MARK: writing

    /// POST /api/custom?name=<name> — an upsert of the app under this name.
    /// Body `code` other than 200 is a failure even under HTTP 200 (D8).
    public func showApp(_ frame: UlanziFrame, named name: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: frame.jsonObject)
        _ = try await envelope("POST", "/api/custom?name=\(name)", body: body)
    }

    /// POST /api/custom?name=<name> with an EMPTY body — the AWTRIX-family
    /// delete. The empty body is the contract: a `{}` body updates the app to
    /// nothing visible and LEAVES it in the knob cycle, which is the measured
    /// difference (research §2.2, A9).
    public func removeApp(named name: String) async throws {
        _ = try await envelope(
            "POST", "/api/custom?name=\(name)", body: Data(), contentType: "application/json"
        )
    }

    // MARK: transport plumbing

    /// The answer to a call the firmware wraps in its `code` envelope: the raw
    /// body, once the envelope says the call succeeded (D8).
    private func envelope(
        _ method: String, _ path: String, body: Data? = nil, contentType: String? = nil
    ) async throws -> Data {
        let data = try await perform(method, path, body: body, contentType: contentType)
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let code = object["code"] as? Int
        else {
            throw UlanziError.malformed("\(path) did not answer a code envelope")
        }
        guard code == 200 else {
            throw UlanziError.deviceRejected(code: code, message: object["message"] as? String ?? "")
        }
        return data
    }

    private func perform(
        _ method: String,
        _ path: String,
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        guard let url = URL(string: "http://\(host)\(path)") else {
            throw UlanziError.malformed("unusable device host: \(host)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw UlanziError.unexpectedStatus(response.statusCode)
        }
        return data
    }
}
