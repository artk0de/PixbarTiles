import Foundation
import PixbarKit

/// The microphones the schedule waits for: which ones the user ticked, which
/// of them is capturing now, and the loop that asks every few seconds whether
/// the meeting is over. What a turn of that loop does — let held runs go,
/// relabel the schedules — is the model's, handed in as `eachTurn`.
@MainActor
final class MicrophoneWatch: ObservableObject {
    /// How often a held run asks whether the meeting is over.
    ///
    /// Five seconds. Not a user setting, and not the schedule's interval: what
    /// this decides is how long after the microphone goes quiet the deferred
    /// anecdote arrives, and a full enumeration costs 1.36 ms measured on this
    /// machine. Polled rather than listened for, because devices come and go —
    /// a listener would need re-registering every time the phone appears, and
    /// the property it would listen to is on a device that may not exist yet.
    static let microphoneInterval: TimeInterval = 5
    /// The loop that lets held runs go when the meeting is over.
    static let microphoneWatch = "microphoneWatch"

    /// The microphones the schedule waits for. Published because the settings'
    /// tick boxes bind to them: the defaults behind it are persistence rather
    /// than state.
    @Published private(set) var watchedMicrophones: [WatchedMicrophone]
    /// Whether a microphone the user cares about is capturing.
    private let microphone: MicrophoneGate
    /// The cadence a held run is released on, one sleeper for the whole app.
    ///
    /// A third clock rather than a share of either of the two above, for the
    /// reason those two are apart: an aggregate can only answer "something is
    /// asleep", and a test that drives the release must be able to say it meant
    /// the microphone rather than the schedule — otherwise "held then released"
    /// cannot be told from "ran late", which is this feature's whole claim.
    private let micSleep: AppModel.Sleeping
    /// Where the ticked set is kept between launches.
    private let defaults: UserDefaults
    /// The model's task bag: teardown waits on the loop through it.
    private let taskBag: TaskBag

    init(
        gate: MicrophoneGate,
        watching: [WatchedMicrophone],
        defaults: UserDefaults,
        sleep: @escaping AppModel.Sleeping,
        taskBag: TaskBag
    ) {
        self.microphone = gate
        self.watchedMicrophones = watching
        self.defaults = defaults
        self.micSleep = sleep
        self.taskBag = taskBag
    }

    /// The watched microphone that is capturing right now, or nil.
    var busyMicrophone: AudioInput? {
        microphone.capturing(watching: watchedMicrophones)
    }

    /// Every input the system reports, with the watched ones marked.
    ///
    /// Asked rather than stored, because the list changes underneath the app:
    /// the phone appears and vanishes, headphones are plugged in. Costs one
    /// CoreAudio enumeration — 1.36 ms measured — and is only drawn while the
    /// settings are open.
    var microphoneListing: [MicrophoneChoice] {
        microphone.listing(watching: watchedMicrophones)
    }

    /// Adds or removes a microphone from the set the schedule waits for.
    ///
    /// Removal goes through the same `matches` rule the gate decides with, and
    /// not through equality on the stored entry: the shipped defaults carry no
    /// UID, so an entry-equality removal would leave a box that cannot be
    /// unticked.
    func setWatched(_ watched: Bool, for input: AudioInput) {
        let present = microphone.listing(watching: watchedMicrophones).map(\.input)
        var watching = watchedMicrophones.filter { $0.matches(input, among: present) == false }
        // Written with the UID this app has just SEEN, which is what upgrades a
        // shipped default from a name to an identity the moment the user
        // confirms it.
        if watched { watching.append(WatchedMicrophone(uid: input.uid, name: input.name)) }
        watchedMicrophones = watching
        WatchedMicrophone.save(watching, to: defaults)
    }

    /// Watches for the meeting being over, and lets the held run go.
    ///
    /// A loop of its own rather than a share of the reachability poll: they
    /// answer different questions on different cadences, and — the reason that
    /// decides it — a test driving one must be able to say which it meant. With
    /// the two folded together, "held then released" could not be told from
    /// "ran late", which is this feature's entire claim.
    ///
    /// The release is AWAITED inside the loop, so a long run cannot be overtaken
    /// by the next turn, and so teardown waiting on this task waits on the run
    /// as well.
    func start(eachTurn: @escaping @MainActor () async -> Void) {
        taskBag.replace(Self.microphoneWatch) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await eachTurn()
                do { try await self.micSleep(Self.microphoneInterval) } catch { return }
            }
        }
    }
}
