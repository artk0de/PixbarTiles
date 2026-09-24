// `@Published`'s projected value and `AnyCancellable`, both read below, are
// Combine's.
import Combine
import Foundation

/// One bounded attempt to find where the clock went, run after it has stopped
/// answering.
///
/// The clock is on the network under a name that never changes and an address
/// the router is free to change at every lease. Discovery has always known the
/// name; what this type adds is the part that makes acting on it safe — a
/// browse that cannot outlive the attempt, a rule about which clock may be
/// taken, and an address that has to say its own name back before anything
/// moves onto it.
///
/// It owns the browse it runs, and that is the point rather than a detail. The
/// panel's browse is gated on the panel being open, because a browse left
/// running puts multicast on the network for the life of the process and
/// nothing else would stop it. This one cannot be left running: it is started
/// and stopped inside a single call, on every path out of it, including the one
/// where the browse never comes up at all.
@MainActor
public final class DeviceRelocation {
    /// Asks an address who it is. Answers with the uid the firmware reports, or
    /// nil for an address that does not answer.
    ///
    /// A closure rather than a device, so that nothing here needs a transport,
    /// a URL or an opinion about HTTP.
    public typealias Probing = @Sendable (String) async -> String?

    /// Injected so the deadline below can be run out by a test without waiting.
    public typealias Sleeping = @Sendable (TimeInterval) async throws -> Void

    /// How long one attempt may take before it is abandoned.
    ///
    /// Longer than the browse's own settle window on purpose: that window is
    /// what turns mDNS silence into "nothing here", so cutting the attempt off
    /// sooner would report an empty network about a browse that was still
    /// listening to it. This deadline is for the case the settle window cannot
    /// answer — the window is armed by `.ready`, so a browser that never comes
    /// up never arms it, and without a deadline of its own the attempt would
    /// wait on it for the life of the process holding an NWBrowser open.
    public static let attemptWindow: TimeInterval = DeviceBrowser.settleWindow + 2

    private let makeBrowser: @MainActor () -> DeviceBrowser
    private let probe: Probing
    private let sleep: Sleeping

    public init(
        browser: @escaping @MainActor () -> DeviceBrowser,
        probe: @escaping Probing,
        sleep: @escaping Sleeping = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.makeBrowser = browser
        self.probe = probe
        self.sleep = sleep
    }

    /// The address to move onto, or nil when nothing here may be moved onto.
    ///
    /// - Parameter uid: the clock this app has been talking to, as it named
    ///   itself in `/api/stats`. Nil before any poll has ever answered.
    ///
    /// Four things have to hold, and a failure of any of them is the same
    /// answer: the browse has to say something, there has to be a clock in it
    /// this app may take, that clock's address has to answer, and it has to
    /// answer to the name it was found under.
    public func relocatedHost(remembering uid: String?) async -> String? {
        let browser = makeBrowser()
        // On every path out, including the deadline and a cancelled caller.
        // This is the whole of the promise that no browse outlives an attempt.
        defer { browser.stop() }

        browser.start()
        guard case let .devices(found) = await answer(from: browser) else { return nil }
        guard let candidate = DeviceAdoption.candidate(remembering: uid, among: found) else {
            return nil
        }
        guard let answered = await probe(candidate.host),
              DeviceAdoption.isTheSameClock(answered, as: candidate)
        else { return nil }
        return candidate.host
    }

    /// What the browse settled on, or nothing when it said nothing in time.
    enum Answer: Sendable {
        case devices([DiscoveredDevice])
        case nothing
    }

    /// The browse's first settled answer, or nothing once the deadline lands.
    private func answer(from browser: DeviceBrowser) async -> Answer {
        await Race().run(watching: browser, givingUpAfter: Self.attemptWindow, sleeping: sleep)
    }

    /// Whether a browse has finished saying what it can, and what that was.
    ///
    /// `.searching` is not an answer, and `.idle` is the value a `@Published`
    /// hands every new subscriber before anything has happened. Everything else
    /// is settled: a list to act on, or a refusal, a failure or a dead network —
    /// none of which is a list, and all of which mean the same thing here.
    static func settled(_ state: DiscoveryState) -> Answer? {
        switch state {
        case .idle, .searching:
            nil
        case let .listed(devices):
            .devices(devices)
        case .denied, .failed, .unavailable:
            .nothing
        }
    }

    /// A browse's answer against a deadline, whichever lands first.
    ///
    /// Its own object because the race needs somewhere to keep "already
    /// answered": both sides can fire, and resuming a continuation twice is a
    /// crash rather than a wasted call. Written with a `sink` and a deadline
    /// task rather than as a task group because the group's main-actor child
    /// defeats the region-based isolation checker outright — Swift 6.3.3
    /// answers that shape with "pattern that the region-based isolation checker
    /// does not understand how to check. Please file a bug".
    @MainActor
    private final class Race {
        private var continuation: CheckedContinuation<Answer, Never>?
        private var watching: AnyCancellable?
        private var deadline: Task<Void, Never>?

        func run(
            watching browser: DeviceBrowser,
            givingUpAfter window: TimeInterval,
            sleeping sleep: @escaping Sleeping
        ) async -> Answer {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                // A `@Published` sends its current value to every new
                // subscriber, so a browse that settled between `start()` and
                // here is not missed — it arrives on subscription.
                watching = browser.$state.sink { [weak self] state in
                    guard let answer = DeviceRelocation.settled(state) else { return }
                    self?.finish(answer)
                }
                deadline = Task { [weak self] in
                    // A cancelled deadline is the answer having arrived first,
                    // and says nothing about the network either way.
                    try? await sleep(window)
                    self?.finish(.nothing)
                }
            }
        }

        private func finish(_ answer: Answer) {
            guard let continuation else { return }
            self.continuation = nil
            watching?.cancel()
            watching = nil
            deadline?.cancel()
            deadline = nil
            continuation.resume(returning: answer)
        }
    }
}
