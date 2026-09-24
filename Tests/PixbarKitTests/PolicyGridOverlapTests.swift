// Tests/PixbarKitTests/PolicyGridOverlapTests.swift
import Foundation
import Testing
@testable import PixbarKit

private func workingIn(
    _ focuses: Set<MacFocus>, _ window: TileWindow = .always
) -> TilePolicy {
    TilePolicy(
        refreshSeconds: 60,
        focus: FocusRule(
            silencedIn: Set(MacFocus.allCases).subtracting(focuses).subtracting([.unknown]),
            whenUnknown: .hold
        ),
        window: window
    )
}

private func office(_ start: Int, _ end: Int) -> TileWindow {
    .active(HourWindow(startHour: start, endHour: end))
}

// The design's own example: one tunnel for the whole of Work, another for
// the office day inside it.
@Test func twoTilesOverlapExactlyWhereBothRun() {
    let pritunl = workingIn([.work]).grid
    let wireGuard = workingIn([.work], office(10, 19)).grid

    let overlap = pritunl.overlap(with: wireGuard)

    #expect(overlap.running.count == 9)
    #expect(overlap.summary == "Work, 10:00–19:00")
}

@Test func theOverlapIsTheSameWhicheverTileAsks() {
    let a = workingIn([.work, .personal]).grid
    let b = workingIn([.personal, .noFocus], office(8, 20)).grid

    #expect(a.overlap(with: b) == b.overlap(with: a))
}

@Test func tilesInDifferentFocusesShareALampWithoutOverlap() {
    let work = workingIn([.work]).grid
    let personal = workingIn([.personal]).grid

    #expect(work.overlap(with: personal).isEmpty)
}

// Working hours end where the next begin, exclusive, so a hand-over at 13:00
// is not a moment both tiles claim.
@Test func tilesAtAdjoiningHoursShareALampWithoutOverlap() {
    let morning = workingIn([.work], office(9, 13)).grid
    let afternoon = workingIn([.work], office(13, 18)).grid

    #expect(morning.overlap(with: afternoon).isEmpty)
}

@Test func aPausedTileOverlapsNothing() {
    var paused = workingIn([.work])
    paused.isPaused = true

    #expect(paused.grid.overlap(with: workingIn([.work]).grid).isEmpty)
}

// MARK: - Saying it

@Test func everyStateAllDayIsSaidAsAnyFocus() {
    #expect(TileDefaults.vpn.grid.summary == "any Focus, all day")
}

@Test func statesOverTheSameHoursAreNamedTogether() {
    let daytime = workingIn([.noFocus, .work, .personal], office(8, 23)).grid

    #expect(daytime.summary == "No Focus, Work and Personal, 08:00–23:00")
}

@Test func aStretchAcrossMidnightIsOneStretch() {
    let night = workingIn([.sleep], office(23, 8)).grid

    #expect(night.summary == "Sleep, 23:00–08:00")
}

// Quiet from ten to eight in Work leaves one stretch, from eight at night to
// ten in the morning — not two that happen to meet at midnight.
@Test func whatQuietHoursLeaveIsOneStretchRoundMidnight() {
    let evenings = workingIn([.work], .quiet(HourWindow(startHour: 10, endHour: 20))).grid

    #expect(evenings.summary == "Work, 20:00–10:00")
}

@Test func separateStretchesAreEachSaid() {
    let morning = workingIn([.work], office(8, 10)).grid
    let evening = workingIn([.work], office(20, 22)).grid

    #expect(PolicyGrid(running: morning.running.union(evening.running)).summary
        == "Work, 08:00–10:00 and 20:00–22:00")
}

@Test func differentHoursInDifferentStatesAreSaidApart() {
    let a = workingIn([.work], office(10, 19)).grid
    let b = workingIn([.personal]).grid

    #expect(PolicyGrid(running: a.running.union(b.running)).summary
        == "Work, 10:00–19:00; Personal, all day")
}

@Test func anEmptyGridSaysNothing() {
    #expect(workingIn([]).grid.summary == "")
}
