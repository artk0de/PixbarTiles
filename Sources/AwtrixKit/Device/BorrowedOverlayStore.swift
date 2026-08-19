import Foundation

/// The device's one global overlay setting as this app found it, what it put
/// there instead, and which connector asked.
///
/// Three fields rather than one, because the question a later launch has to
/// answer is not "what was there" but "was what is there now MINE". A record
/// carrying only `before` cannot tell the two apart, and telling them apart is
/// the whole reason the record exists.
public struct BorrowedOverlay: Sendable, Equatable {
    /// What the device held before this app wrote over it. The user's own
    /// value, set by hand from the clock's web interface as often as not, and
    /// recoverable from nowhere else once it has been overwritten.
    public let before: String
    /// What this app wrote instead. Kept so a fresh custody can recognise its
    /// predecessor's work rather than mistake it for a value somebody chose.
    public let applied: String
    /// Which connector asked. One global setting, so one borrower.
    public let borrower: String

    public init(before: String, applied: String, borrower: String) {
        self.before = before
        self.applied = applied
        self.borrower = borrower
    }
}

/// What this app borrowed from the device's global settings, and has to give
/// back.
///
/// Durable, and that is the single property it exists for. `OVERLAY` is written
/// to flash and survives the app; the record of what it held must survive the
/// app too, or the first unclean exit converts this app's own weather into
/// "what the user had". A force quit, a logout, a crash, or simply a teardown
/// that runs past the 15-second quit budget while a synthesis is wedged — each
/// one ends a launch with the overlay still borrowed and no restore run, and
/// with the record in memory only the next launch reads `rain` off the device
/// and writes it down as the original. Every clean quit from then on restores
/// `rain`, and the user's setting is gone with nothing anywhere to say so.
///
/// The same argument `UploadedIconStore` was built on, and the same shape:
/// what this app did to the device is not knowable afterwards by looking at the
/// device. Where the icons differ is that re-uploading one is idempotent and a
/// user can delete a file; the overlay is a single value whose prior state
/// cannot be recovered from anywhere once it has been written over.
public protocol BorrowedOverlayStore: Sendable {
    /// The outstanding borrow, or nil when this app has nothing on loan.
    func borrowedOverlay() -> BorrowedOverlay?
    /// Replaces the record. There is one global setting, so there is one
    /// record: a second borrow does not stack.
    func record(_ borrowed: BorrowedOverlay)
    /// Forgotten only once the device has confirmed the value went back.
    func forget()
}

public final class InMemoryBorrowedOverlayStore: BorrowedOverlayStore, @unchecked Sendable {
    private var storage: BorrowedOverlay?
    private let lock = NSLock()

    public init() {}

    public func borrowedOverlay() -> BorrowedOverlay? {
        lock.withLock { storage }
    }

    public func record(_ borrowed: BorrowedOverlay) {
        lock.withLock { storage = borrowed }
    }

    public func forget() {
        lock.withLock { storage = nil }
    }
}

public final class UserDefaultsBorrowedOverlayStore: BorrowedOverlayStore, @unchecked Sendable {
    /// One key for the whole record, because the three fields are only ever
    /// read together and a half-written borrow is worse than none: a `before`
    /// without the `applied` beside it cannot answer the question the record
    /// exists for.
    private static let key = "borrowedOverlay"

    /// No lock, where `UserDefaultsUploadedIconStore` has one and the asymmetry
    /// is the point. That store's mutators read, modify and write a list, so
    /// two of them at once lose a record. Both mutators here write the whole
    /// value or remove it, and `UserDefaults` is safe for that on its own.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func borrowedOverlay() -> BorrowedOverlay? {
        guard
            let stored = defaults.dictionary(forKey: Self.key),
            let before = stored["before"] as? String,
            let applied = stored["applied"] as? String,
            let borrower = stored["borrower"] as? String
        else { return nil }
        return BorrowedOverlay(before: before, applied: applied, borrower: borrower)
    }

    public func record(_ borrowed: BorrowedOverlay) {
        defaults.set(
            ["before": borrowed.before, "applied": borrowed.applied, "borrower": borrowed.borrower],
            forKey: Self.key
        )
    }

    public func forget() {
        defaults.removeObject(forKey: Self.key)
    }
}
