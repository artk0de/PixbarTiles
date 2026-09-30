import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// The microphones the schedule waits for: which of them is busy, which the
/// user ticked, and the loop that asks every few seconds whether the meeting
/// is over.
@MainActor
@Suite struct MicrophoneWatchTests {
    private let inputs = StubAudioInputs(duringAMeeting)
    private let defaults = UserDefaults(suiteName: "mic-\(UUID().uuidString)")!

    private func watch(sleep: @escaping AppModel.Sleeping = parked, taskBag: TaskBag = TaskBag()) -> MicrophoneWatch {
        MicrophoneWatch(
            gate: MicrophoneGate(inputs: inputs),
            watching: [WatchedMicrophone(uid: Inputs.builtIn.uid, name: Inputs.builtIn.name)],
            defaults: defaults, sleep: sleep, taskBag: taskBag
        )
    }

    @Test func aWatchedMicrophoneCapturingIsBusyAndOnlyWhileItIs() {
        let subject = watch()
        #expect(subject.busyMicrophone?.uid == Inputs.builtIn.uid)
        inputs.nowReports(afterTheMeeting)
        #expect(subject.busyMicrophone == nil)
    }

    @Test func unwatchingAMicrophoneStopsTheWaitAndIsKept() {
        let subject = watch()
        subject.setWatched(false, for: Inputs.builtIn)
        #expect(subject.busyMicrophone == nil)
        #expect(subject.watchedMicrophones.isEmpty)
        #expect(WatchedMicrophone.stored(in: defaults).isEmpty)
    }

    @Test func eachTurnOfTheLoopRunsTheTurnThenSleeps() async {
        let slept = Counter()
        let subject = watch(sleep: { _ in
            await slept.increment()
            if await slept.value >= 2 { throw CancellationError() }
        })
        var turns = 0
        subject.start { turns += 1 }
        for _ in 0..<1_000 where turns < 2 { await Task.yield() }
        #expect(turns == 2)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
