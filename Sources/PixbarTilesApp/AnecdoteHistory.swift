import AppKit
import Foundation
import PixbarKit

/// The History: what has played, the surface that shows it in place of the
/// panel, and a replay of a past anecdote — which is not a run.
@MainActor
final class AnecdoteHistory: ObservableObject {
    /// The read that fills the History; a newer one supersedes the older.
    static let historyLoad = "historyLoad"

    /// Whether the History is showing instead of the panel.
    @Published private(set) var historyIsOpen = false
    /// What has played recently, newest first, as of the last read — and nil
    /// until a read has answered.
    ///
    /// Optional rather than an empty array standing in for both, and the merge
    /// is the reported defect rather than a nicety: "nobody has asked yet" and
    /// "the queue holds nothing" are different states, and told apart by nothing
    /// the surface says "Nothing has played yet" about a connector with plenty
    /// to list — measured, byte-identical to the real thing. Reading earlier
    /// narrows the window that is drawn in and cannot close it: it is a race,
    /// and the answer it loses is a confident wrong one rather than a slow right
    /// one.
    ///
    /// `Optional` rather than a `historyHasBeenRead` flag beside the array: one
    /// value cannot disagree with itself, and two values answering one question
    /// disagree the first time either moves. An enum of its own was the other
    /// candidate and it says nothing `Optional` does not — this class already
    /// spells "no answer yet" as nil three times over, in `replayResult`,
    /// `iconStatus` and `locationNote`.
    ///
    /// Read on opening rather than kept in step with the queue: nothing else on
    /// the panel shows it, and a run that happens while the surface is closed
    /// has no reader to tell. The list is whatever the queue still holds — the
    /// retention window bounds it, and nothing here bounds it a second time.
    ///
    /// Never put back to nil once it holds an answer. A read that has happened
    /// stays happened, so leaving the surface and returning to it draws the last
    /// list at once instead of going quiet while the same answer arrives again.
    @Published private(set) var history: [PlayedAnecdote]?
    /// How the last replay went, in the History's own words, and nil until one
    /// has been asked for.
    ///
    /// Its own line rather than the connector's. A replay is not a run: the run
    /// line describes what the SCHEDULE last did, and a failure heard from the
    /// History written over it would claim the schedule had failed. What the
    /// discarded result never stops being discarded FOR is the run line and the
    /// backoff — but discarding it altogether is what left "Play again" against
    /// an unreachable clock doing nothing at all, with no explanation.
    @Published private(set) var replayResult: String?
    /// The connector whose history the menu can browse, or nil when none was
    /// wired. Optional because the panel is generic over connectors and only
    /// one of them keeps anything to look back over.
    private let anecdotes: (any AnecdoteReplaying)?
    /// Where Copy writes. Injected so the suite cannot put anything on the
    /// clipboard of whoever is running it.
    private let pasteboard: NSPasteboard
    /// The model's task bag: teardown waits on what is in it.
    private let taskBag: TaskBag
    /// Whether the clock carrying the anecdotes was asked and did not answer.
    private let reachability: any ReachabilityReading
    /// The clock carrying the tile of the named connector, if any does.
    private let clockCarrying: @MainActor (String) -> UUID?
    /// A clock's session.
    private let session: @MainActor (UUID) -> (any ConnectorRunning)?

    init(
        anecdotes: (any AnecdoteReplaying)?,
        pasteboard: NSPasteboard,
        taskBag: TaskBag,
        reachability: any ReachabilityReading,
        clockCarrying: @escaping @MainActor (String) -> UUID?,
        session: @escaping @MainActor (UUID) -> (any ConnectorRunning)?
    ) {
        self.anecdotes = anecdotes
        self.pasteboard = pasteboard
        self.taskBag = taskBag
        self.reachability = reachability
        self.clockCarrying = clockCarrying
        self.session = session
    }

    /// Whether this connector has a history to browse.
    ///
    /// Asked of the connector rather than answered by a flag on the row,
    /// because the panel draws whatever the registry holds and only the
    /// anecdotes keep anything: a History button on a row with no history behind
    /// it is a promise the surface cannot keep.
    func hasHistory(connectorId: String) -> Bool {
        anecdotes?.id == connectorId
    }

    /// Shows what has played, in place of the panel.
    ///
    /// In place of, not over: a menu bar extra's window dismisses when it loses
    /// focus and takes any sheet with it, so a sheet here is a surface that
    /// vanishes while it is being read. The settings made the same trade.
    ///
    /// The list is read on every open. Nothing else shows it, so keeping it in
    /// step with the queue between opens would be work nobody can see — and a
    /// surface opened right after a run has to show that run.
    func openHistory() {
        historyIsOpen = true
        loadHistory()
    }

    /// Asks what has played, without swapping the panel to show it.
    ///
    /// The half of `openHistory` that is about the LIST rather than about the
    /// panel. The anecdote tile's settings window shows the same history in a
    /// sheet of its own, and its button used to call `openHistory` — which
    /// flipped a flag nothing in that window reads, so the press did nothing
    /// visible there and left the menu bar's panel swapped to a surface
    /// nobody had asked it for.
    func loadHistory() {
        // Whatever the last replay said goes with the surface it was said on.
        // Opening the History is asking what has played, not asking again about
        // the last thing that was pressed — and an answer kept across the open
        // would read as having just happened.
        replayResult = nil
        readHistory()
    }

    /// Asks what has played, into `history`.
    ///
    /// Its own method because the History's own open is too late to be the only
    /// caller. The read is a round trip to an actor and the surface is drawn the
    /// instant the button is pressed, so on the FIRST open there is no answer to
    /// draw yet, while every open after that draws the entries at once off the
    /// answer the first open eventually got — which is exactly the asymmetry
    /// that was reported: the History showing what played only on the second
    /// press. Asking when the PANEL opens is what buys the first open its
    /// answer; `history` staying nil until one arrives is what keeps the gap
    /// honest when it does not.
    ///
    /// Cancelling the load in flight is what keeps the last open's answer from
    /// landing after this one's — two reads racing to write the same list, and
    /// the older one winning is a surface showing what had played a minute ago.
    func readHistory() {
        guard let anecdotes else { return }
        taskBag.replace(Self.historyLoad) { [weak self] in
            let played = await anecdotes.history()
            guard let self, !Task.isCancelled else { return }
            self.history = played
        }
    }

    func closeHistory() { historyIsOpen = false }

    /// Puts the menu back on the panel, because the window went away.
    ///
    /// The History, and only the History. The settings used to be reset here
    /// too, back when they were a surface swapped into the panel's window —
    /// now they are the app's own window, and it closing says nothing about
    /// the panel. A menu bar item is clicked to answer "is the clock alive,
    /// and what is next"; a list of old jokes answers a question nobody
    /// asked.
    ///
    /// Not a teardown. Nothing is stopped and nothing is cancelled — the
    /// schedule, the poll and any replay in flight carry on behind a window
    /// that is not on screen, exactly as they carry on behind a surface that
    /// is.
    func windowDidClose() {
        historyIsOpen = false
    }

    /// Plays a past anecdote again.
    ///
    /// NOT a run, and every part of that is deliberate: it goes to `deliver`, so
    /// nothing is produced and nothing is retired; no outcome is recorded, so
    /// the backoff Task 15 owns is untouched; and no restock follows it, so the
    /// refill Task 18 schedules is not brought forward. Replaying something from
    /// last week cannot change what tomorrow does.
    ///
    /// An entry whose clips have been reaped is refused here, and `isPlayable`
    /// is the one thing asked — the same answer the button's own disabled state
    /// reads. Delivering it would put a held banner on the clock with audio that
    /// never arrives to end it.
    ///
    /// The task is owned rather than left to the button's action closure, for
    /// the reason `runNow`'s is: teardown can only wait for what it holds, and
    /// this puts the same held banner on the clock.
    /// Said instead of an outcome, when no clock carries the anecdotes.
    static let noClockCarriesTheAnecdotes = "No clock carries the anecdotes"

    /// The session of the clock carrying the anecdote tile.
    private var anecdoteSession: (any ConnectorRunning)? {
        anecdoteClock.flatMap(session)
    }

    /// The clock carrying the anecdote tile.
    private var anecdoteClock: UUID? {
        guard let anecdotes else { return nil }
        return clockCarrying(anecdotes.id)
    }

    func replay(_ anecdote: PreparedAnecdote) {
        guard let anecdotes, anecdote.isPlayable else { return }
        guard let session = anecdoteSession else {
            replayResult = Self.noClockCarriesTheAnecdotes
            return
        }
        // Nothing is sent to a clock the poll has found unreachable; the
        // History is told why, in the panel's words for the same hold.
        if let clockId = anecdoteClock, reachability.clockIsUnreachable(clockId) {
            replayResult = AppModel.deviceUnreachable
            return
        }
        let output = anecdotes.output(for: anecdote)
        taskBag.run { [weak self] in
            let result = await session.deliver(output)
            // Kept, where the run line and the failure count are still not
            // touched. Those two are what the discarded result was ever
            // discarded for; the History is a third place, and it is the one
            // the button was pressed on.
            self?.replayResult = TileRunner.words(for: result)
        }
    }

    /// Puts the joke on the pasteboard.
    ///
    /// The anecdote's own text — not the banner, which is the four words the
    /// clock shows, and not the laughter, which is a marker for the synthesizer.
    /// What somebody pressing Copy wants is the thing they would paste into a
    /// chat.
    func copyText(_ anecdote: PreparedAnecdote) {
        pasteboard.clearContents()
        pasteboard.setString(anecdote.text, forType: .string)
    }
}
