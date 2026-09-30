import AppKit
import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// The History: what has played, read on opening; a replay that is not a run;
/// and the one line that says how the last replay went.
@MainActor
@Suite struct AnecdoteHistoryTests {
    private let clockId = UUID()

    /// Answers "unreachable" for the clocks it is given.
    private final class Reachability: ReachabilityReading {
        let down: Set<UUID>
        init(down: Set<UUID>) { self.down = down }
        func clockIsUnreachable(_ clockId: UUID) -> Bool { down.contains(clockId) }
        func recheckClocks() {}
    }

    private func history(
        entries: [PlayedAnecdote] = [],
        carried: Bool = true,
        down: Set<UUID> = []
    ) -> AnecdoteHistory {
        let clockId = self.clockId
        return AnecdoteHistory(
            anecdotes: StubAnecdotes(id: "anecdotes", history: entries),
            pasteboard: NSPasteboard(name: NSPasteboard.Name("history-\(UUID().uuidString)")),
            taskBag: TaskBag(),
            reachability: Reachability(down: down),
            clockCarrying: { _ in carried ? clockId : nil },
            session: { _ in SpyHost() }
        )
    }

    @Test func onlyTheAnecdotesHaveAHistory() {
        let subject = history()
        #expect(subject.hasHistory(connectorId: "anecdotes"))
        #expect(subject.hasHistory(connectorId: "weather") == false)
    }

    @Test func openingShowsTheHistoryAndReadsWhatHasPlayed() async throws {
        let played = PlayedAnecdote(anecdote: try playableAnecdote(id: "a1"), playedAt: Date())
        let subject = history(entries: [played])
        #expect(subject.history == nil)
        subject.openHistory()
        #expect(subject.historyIsOpen)
        for _ in 0..<1_000 where subject.history == nil { await Task.yield() }
        #expect(subject.history?.map(\.anecdote.id) == ["a1"])
        subject.windowDidClose()
        #expect(subject.historyIsOpen == false)
    }

    @Test func aReplayWithNoClockCarryingTheTileSaysSo() throws {
        let subject = history(carried: false)
        subject.replay(try playableAnecdote(id: "a1"))
        #expect(subject.replayResult == AnecdoteHistory.noClockCarriesTheAnecdotes)
    }

    @Test func aReplayToAnUnreachableClockIsNotSentAndSaysWhy() throws {
        let subject = history(down: [clockId])
        subject.replay(try playableAnecdote(id: "a1"))
        #expect(subject.replayResult == AppModel.deviceUnreachable)
        subject.loadHistory()
        #expect(subject.replayResult == nil)
    }
}
