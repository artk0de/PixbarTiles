import Foundation
import Testing
@testable import PixelClockKit

@Test func aWindowCoversTheHoursBetweenItsEnds() {
    let window = HourWindow(startHour: 9, endHour: 17)

    #expect(window.contains(hour: 8) == false)
    #expect(window.contains(hour: 9))
    #expect(window.contains(hour: 16))
    // Exclusive at the end, so 17:00 is the first hour outside again.
    #expect(window.contains(hour: 17) == false)
}

@Test func aWindowThatWrapsMidnightCoversBothSidesOfIt() {
    let night = HourWindow(startHour: 23, endHour: 8)

    #expect(night.contains(hour: 23))
    #expect(night.contains(hour: 0))
    #expect(night.contains(hour: 7))
    #expect(night.contains(hour: 8) == false)
    #expect(night.contains(hour: 22) == false)
}

@Test func aWindowOfZeroLengthCoversNothing() {
    let window = HourWindow(startHour: 3, endHour: 3)

    #expect(window.isEmpty)
    #expect((0..<24).allSatisfy { window.contains(hour: $0) == false })
}

// Every window the pickers can make, every hour: 576 windows, 13,824 answers,
// against a second statement of the rule that shares no code with the first —
// how far past the start the hour is, against how long the window is.
@Test func everyHourOfEveryWindowIsWhatItsTwoEndsSay() {
    for start in 0..<24 {
        for end in 0..<24 {
            let window = HourWindow(startHour: start, endHour: end)
            let length = (end - start + 24) % 24
            for hour in 0..<24 {
                let intoIt = (hour - start + 24) % 24
                #expect(
                    window.contains(hour: hour) == (intoIt < length),
                    "\(window.label) at \(hour):00"
                )
            }
        }
    }
}

@Test func hoursAreTakenRoundTheClock() {
    #expect(HourWindow(startHour: 24, endHour: 32) == HourWindow(startHour: 0, endHour: 8))
    #expect(HourWindow(startHour: -1, endHour: 8) == HourWindow(startHour: 23, endHour: 8))
    #expect(HourWindow(startHour: 23, endHour: 8).contains(hour: 24))
}

@Test func aWindowSaysItselfAsTwoHoursOnAClock() {
    #expect(HourWindow(startHour: 23, endHour: 8).label == "23:00–08:00")
    #expect(HourWindow(startHour: 0, endHour: 7).label == "00:00–07:00")
    #expect(HourWindow.clockFace(24) == "00:00")
}
