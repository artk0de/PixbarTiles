import Foundation

/// Defaults that remember the order keys were written in, so a test can say
/// which write came last.
///
/// Both setters are recorded: `set(true, forKey:)` reaches the `Bool` one,
/// and whether that forwards to the `Any?` one is Foundation's business. A key
/// recorded twice changes nothing about which came last.
final class RecordingDefaults: UserDefaults, @unchecked Sendable {
    private(set) var writes: [String] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        writes.append(defaultName)
        super.set(value, forKey: defaultName)
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        writes.append(defaultName)
        super.set(value, forKey: defaultName)
    }
}
