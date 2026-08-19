import CoreAudio
import Foundation

/// One audio input, as the system reports it.
///
/// `isCapturing` is `kAudioDevicePropertyDeviceIsRunningSomewhere`, which
/// answers without any permission at all: nothing here opens a stream or reads
/// a sample, so this costs no microphone access and raises no TCC prompt.
/// Probed and working from a bare binary.
struct AudioInput: Equatable, Sendable {
    /// The stable identity. Names are user-visible and change; this does not.
    let uid: String
    /// What the user would recognise it as, and the only thing worth putting on
    /// a panel.
    let name: String
    let isCapturing: Bool
}

/// What CoreAudio says about the inputs.
protocol AudioInputReporting: Sendable {
    func inputs() -> [AudioInput]
}

/// A microphone the user asked the app to wait for.
///
/// Both fields, and the pair is the point. Matching is on `uid`, because names
/// are unstable — "iPhone Microphone" appears and vanishes as the phone comes
/// and goes, and two identical models collide; measured on this machine, "ROG
/// CETRA TWS SN" already names two different audio devices at once. The name is
/// kept beside it so the settings have something to draw, and as the fallback
/// for an entry whose UID matches nothing present.
struct WatchedMicrophone: Equatable, Sendable, Codable {
    /// Nil until this app has seen the device: the shipped defaults are names,
    /// because a UID cannot be known before the device has been enumerated
    /// once. Ticking a box in the settings writes the real one.
    let uid: String?
    let name: String

    static let key = "watchedMicrophones"

    /// Whether this entry names that input.
    ///
    /// One rule, used by every caller — the gate that decides, the listing that
    /// draws the ticks, and the setter that unticks. Two implementations of it
    /// would be a box the user cannot untick.
    ///
    /// UID first. The name is reached only when the UID resolves to nothing
    /// that is currently present: a shipped default that has never been edited,
    /// or a device that came back wearing a new UID. A UID that DOES match some
    /// other present device is an answer — this entry is not that input — and
    /// falling through to the name there is exactly the collision the UID
    /// exists to avoid.
    func matches(_ input: AudioInput, among present: [AudioInput]) -> Bool {
        if let uid {
            if uid == input.uid { return true }
            if present.contains(where: { $0.uid == uid }) { return false }
        }
        return name == input.name
    }

    /// What the last launch left behind, or the shipped default when nothing
    /// was ever saved.
    ///
    /// An EMPTY set is a decision, not an absence: a user who unticks every box
    /// has asked the app never to wait, and folding that back to the default
    /// would silently re-tick two boxes they had just cleared. `data(forKey:)`
    /// answering nil is the only thing that means "never set".
    static func stored(in defaults: UserDefaults) -> [WatchedMicrophone] {
        guard
            let data = defaults.data(forKey: key),
            let watching = try? JSONDecoder().decode([WatchedMicrophone].self, from: data)
        else { return MicrophoneGate.defaultWatchSet }
        return watching
    }

    static func save(_ watching: [WatchedMicrophone], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(watching) else { return }
        defaults.set(data, forKey: key)
    }
}

/// One row of the settings' device list.
struct MicrophoneChoice: Identifiable, Equatable, Sendable {
    let input: AudioInput
    let isWatched: Bool

    var id: String { input.uid }
}

/// Whether a microphone the user cares about is capturing right now.
///
/// A watched SET rather than "any input", and that is the whole design. Probed
/// on this machine: five inputs are present and `Universal Audio Thunderbolt`,
/// an always-on interface, reports `capturing == true` permanently with no
/// meeting in progress. A gate written against "is anything capturing" is a
/// permanent mute — an app that never speaks and nobody knows why.
///
/// Not "the default input" either: a conferencing app does not always take the
/// default, and the default moves when headphones are plugged in.
///
/// A value rather than an object, and the watch set is a parameter for the
/// reason `FocusGate`'s window is: `AppModel` owns it, the settings bind to it
/// and the defaults keep it, and a second copy here would be a second thing to
/// keep in step.
struct MicrophoneGate: Sendable {
    /// The two a human actually talks into on this machine. The Thunderbolt
    /// interface and Serato's virtual input are left out by construction rather
    /// than by a heuristic that has to be right.
    ///
    /// By name, with no UID: a UID cannot be known before the device has been
    /// enumerated once, and the iPhone's is per-phone anyway. `matches` falls
    /// back to the name for exactly this case.
    static let defaultWatchSet = [
        WatchedMicrophone(uid: nil, name: "MacBook Pro Microphone"),
        WatchedMicrophone(uid: nil, name: "iPhone Microphone"),
    ]

    let inputs: any AudioInputReporting

    /// What the panel says while a microphone holds the schedule.
    ///
    /// Names the device, because silence is not diagnosable and "waiting" on
    /// its own is not either. The one that caused it is the one the user has to
    /// go and look at.
    static func inUse(_ name: String) -> String { "\(name) is in use" }

    /// The watched input that is capturing, or nil.
    ///
    /// There is no launch baseline, deliberately. An earlier draft excluded
    /// devices already capturing at startup, to dodge the always-on interface;
    /// with an explicit watch set that heuristic is not merely unnecessary but
    /// wrong — a watched microphone already capturing when the app launches
    /// means a meeting is already in progress, and the right answer is to hold.
    ///
    /// A watched device that is ABSENT is simply not in the list, so it cannot
    /// be capturing and cannot hold anything. Its absence is not an error and
    /// does not disable the gate for the devices that are present.
    func capturing(watching: [WatchedMicrophone]) -> AudioInput? {
        let present = inputs.inputs()
        // The first in the system's own enumeration order, so the answer is
        // stable between two reads a second apart — and it is the first WATCHED
        // one, not the first capturing one, which on this desk would be the
        // interface every single time.
        return present.first { input in
            input.isCapturing && watching.contains { $0.matches(input, among: present) }
        }
    }

    /// Every input the system reports, with the watched ones marked.
    ///
    /// Every input, not only the watched ones: a gate the user cannot inspect
    /// is a gate they will eventually fight, and the interface that reports
    /// itself busy for ever is only understandable next to the ones that do
    /// not.
    func listing(watching: [WatchedMicrophone]) -> [MicrophoneChoice] {
        let present = inputs.inputs()
        return present.map { input in
            MicrophoneChoice(
                input: input,
                isWatched: watching.contains { $0.matches(input, among: present) }
            )
        }
    }
}

/// The shipped reporter.
///
/// Measured: a full enumeration — every device, its input channel count, name,
/// UID and running state — costs 1.36 ms on this machine with seven devices
/// present. Cheap enough to ask on every tick and every turn of the watch loop;
/// worth knowing before it is put inside anything that redraws at 60 Hz.
///
/// No permission, no prompt, no entitlement. `kAudioDevicePropertyDeviceIs
/// RunningSomewhere` reports whether SOMETHING has the device running, which is
/// the question, and answering it never opens a stream.
struct SystemAudioInputs: AudioInputReporting {
    func inputs() -> [AudioInput] {
        Self.deviceIds().compactMap { id in
            // Output-only devices are dropped here rather than filtered later:
            // a speaker cannot be captured from, and on this machine two of the
            // seven devices share a name with an input — so a list that kept
            // them would make the name fallback ambiguous for no gain.
            guard Self.inputChannels(id) > 0 else { return nil }
            guard
                let name = Self.string(id, kAudioObjectPropertyName),
                let uid = Self.string(id, kAudioDevicePropertyDeviceUID)
            else { return nil }
            return AudioInput(uid: uid, name: name, isCapturing: Self.isRunningSomewhere(id))
        }
    }

    private static func deviceIds() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func string(
        _ device: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    /// How many channels this device can be recorded FROM.
    ///
    /// The input scope, which is what separates a microphone from a speaker.
    /// The property is a variable-length `AudioBufferList`, so its size has to
    /// be asked for before it is read.
    private static func inputChannels(_ device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr
        else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }
}
