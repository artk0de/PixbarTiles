import Foundation

/// The art this app carries for skies the catalogue cannot draw.
///
/// A lookup rather than a stored table, because the package IS the table: a GIF
/// added to `Sources/AwtrixKit/Resources` is reachable by its basename, and one
/// removed or renamed answers nil. That is the whole point — the names the
/// themes use are checked against this at test time, so art that stops shipping
/// fails the suite instead of failing silently on the clock.
public enum BundledIcon {
    /// The GIF bytes shipped under this basename, or nil when the package
    /// carries no such art.
    ///
    /// `name` reaches `Bundle` as a resource name rather than a path, so it
    /// cannot climb out of the bundle however it is spelled.
    public static func data(named name: String) -> Data? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "gif") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}
