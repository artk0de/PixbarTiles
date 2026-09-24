import Foundation

/// A clock's address as somebody actually types it, turned into the host an
/// HTTP request can be aimed at.
///
/// Pasting `http://10.0.0.5` out of a browser is the single most likely thing a
/// person does with an address field, and what this app did with it is what
/// made it a defect rather than a nicety. Every request is built as
/// `http://<host><path>`, so the paste produced `http://http://10.0.0.5/api/
/// stats` — a URL whose host is a machine literally named `http`. It resolves
/// to nothing, and what reaches the user is a DNS error in the offline reason
/// with nothing anywhere suggesting the address is malformed.
///
/// Normalised rather than refused, where the paste is unambiguous. Somebody
/// pasting the address of the clock's own web interface has done the obvious
/// thing, and an app that knows exactly what they meant and makes them retype
/// it is being difficult on purpose. What cannot be made into a host — a scheme
/// with nothing after it, an entry with a space in the middle — is refused, so
/// the complaint arrives on the field rather than as a failed poll a quarter of
/// an hour later on a different surface.
public enum DeviceAddress {
    /// The host to aim at, or nil when there is nothing usable in what was
    /// typed.
    public static func host(from typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)

        // Case-insensitively: a browser's own address bar is lowercase, but a
        // clipboard carries whatever was in the document it came from.
        for scheme in ["http://", "https://"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }

        // Everything from the first slash on is a path rather than a host. The
        // browser shows `http://10.0.0.5/`, and that trailing slash left in
        // place puts a double slash in every URL this app builds.
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }

        let host = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.isEmpty == false else { return nil }
        // A host cannot contain a space. `URL(string:)` answers nil for one, so
        // without this the entry is accepted, stored, and only complained about
        // at the next poll — the same argument `LocationField` range-checks its
        // coordinates on rather than leaving them to the service.
        guard host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return host
    }
}
