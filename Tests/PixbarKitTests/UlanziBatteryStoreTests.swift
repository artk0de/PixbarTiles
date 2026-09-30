import Foundation
import Testing
@testable import PixbarKit

/// A TC002's last battery sample outlives the launch that read it, under the
/// clock's own id: a clock that is off when the app starts has no other way
/// to say it was running down.
@Suite struct UlanziBatteryStoreTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ulanzi-battery-\(UUID().uuidString)")!
    }

    private let sample = UlanziBatterySample(
        percent: 14, charging: false, millivolts: 3_610, at: Date(timeIntervalSince1970: 1_000)
    )

    @Test func aSavedSampleIsWhatTheNextLaunchReads() {
        let defaults = defaults()
        let clockId = UUID()
        UserDefaultsUlanziBatteryStore(defaults: defaults, clockId: clockId).save(sample)

        let nextLaunch = UserDefaultsUlanziBatteryStore(defaults: defaults, clockId: clockId)
        #expect(nextLaunch.storedSample() == sample)
    }

    @Test func anotherClockReadsNothing() {
        let defaults = defaults()
        UserDefaultsUlanziBatteryStore(defaults: defaults, clockId: UUID()).save(sample)

        #expect(UserDefaultsUlanziBatteryStore(defaults: defaults, clockId: UUID()).storedSample() == nil)
    }

    @Test func aKeyThatWillNotDecodeReadsAsNothing() {
        let defaults = defaults()
        let clockId = UUID()
        defaults.set(Data("not json".utf8), forKey: UserDefaultsUlanziBatteryStore.key(for: clockId))

        #expect(UserDefaultsUlanziBatteryStore(defaults: defaults, clockId: clockId).storedSample() == nil)
    }
}
