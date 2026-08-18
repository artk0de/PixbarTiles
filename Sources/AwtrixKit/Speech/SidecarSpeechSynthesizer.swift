import Foundation

/// Drives the long-lived Python synthesis process.
///
/// The model costs seconds to load and caches conditioning latents per voice, so
/// the process is started once and reused. Spawning per phrase would pay the
/// load every time and discard the cache that makes alternating voices free — a
/// cold demonstration run took 70 seconds where a fully cached one takes 0.28 s.
public actor SidecarSpeechSynthesizer: SpeechSynthesizing {
    private let pythonPath: String
    private let scriptPath: String
    private let workingDirectory: String
    /// Where batches are written. Readable because it is half of an invariant
    /// the composition root has to get right: the queue's reaper is contained by
    /// this same directory, and nothing can check that the two agree unless both
    /// ends can be asked.
    public nonisolated let outputDirectory: URL
    /// The environment handed to the sidecar. Readable for the same reason
    /// `outputDirectory` is: what a child process was given cannot be read back
    /// off the process afterwards, and this one is the whole point of `start`.
    public nonisolated let environment: [String: String]

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()

    public init(
        pythonPath: String,
        scriptPath: String,
        workingDirectory: String,
        outputDirectory: URL,
        environment: [String: String] = SidecarSpeechSynthesizer.childEnvironment()
    ) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
        self.workingDirectory = workingDirectory
        self.outputDirectory = outputDirectory
        self.environment = environment
    }

    /// Where the sidecar's own tools live.
    ///
    /// `speak.py` shells out to `ffmpeg` to normalise every clip, and to
    /// `ffprobe` on the fallback path where `wave` cannot read the result.
    /// Homebrew installs both here: `/opt/homebrew/bin` on Apple silicon,
    /// `/usr/local/bin` on Intel.
    static let toolDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The environment to hand the sidecar: the caller's own, with the tool
    /// directories in front of its `PATH`.
    ///
    /// An app launched from Finder inherits its environment from launchd, and
    /// `launchctl getenv PATH` is empty on a stock machine — so it runs with
    /// `/usr/bin:/bin:/usr/sbin:/sbin`, which has no homebrew on it. The Python
    /// child inherited that, `subprocess.run(["ffmpeg", …])` raised
    /// `FileNotFoundError`, and every "Run now" came back as
    /// `synthesisFailed("[Errno 2] No such file or directory: 'ffmpeg'")`.
    ///
    /// Extended rather than replaced, so a developer running from a shell keeps
    /// everything they had. Prepended rather than appended, so an older ffmpeg
    /// earlier on that shell's `PATH` does not decide what normalises the clips.
    /// Duplicates are left in: a repeated entry costs one failed stat, and
    /// removing them would make the result depend on what the caller happened
    /// to have.
    public static func childEnvironment(
        inheriting inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = inherited
        // `split` drops empty subsequences, so a `PATH` that is absent, empty
        // or carries a stray colon cannot yield an empty entry here — and an
        // empty entry means the current directory, which for this child is a
        // directory of downloaded voice packs.
        let inheritedEntries = (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = (toolDirectories + inheritedEntries).joined(separator: ":")
        return environment
    }

    /// Whether `tool` resolves to an executable on `path`, the way `execvp`
    /// resolves it — which is how the Python child will go looking.
    static func resolves(_ tool: String, on path: String) -> Bool {
        path.split(separator: ":").contains { directory in
            FileManager.default.isExecutableFile(
                atPath: URL(fileURLWithPath: String(directory))
                    .appendingPathComponent(tool).path
            )
        }
    }

    /// One request per line: the sidecar reads stdin line by line.
    ///
    /// Normalisation happens here, so every request carries prepared text no
    /// matter who built it, and an embedded newline cannot desync the stream —
    /// it is collapsed to a space before JSON ever sees it.
    public static func requestLine(for turn: VoicedTurn, outputPath: String) -> String {
        let object: [String: Any] = [
            "voice": turn.voice.id,
            "text": SpeechText.prepare(turn.text),
            "out": outputPath,
        ]
        // A dictionary of strings is always a valid JSON object and
        // JSONSerialization escapes every control character inside one, so this
        // cannot fail and the result is a single line by construction.
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// `{"ok":true,"out":"..."}` on success, `{"ok":false,"error":"..."}` otherwise.
    public static func parseResponse(_ line: String) throws -> URL {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else {
            throw SpeechError.synthesisFailed("unparseable sidecar output: \(line)")
        }
        guard object["ok"] as? Bool == true else {
            throw SpeechError.synthesisFailed(object["error"] as? String ?? "unknown error")
        }
        guard let path = object["out"] as? String else {
            throw SpeechError.synthesisFailed("sidecar reported success without a file")
        }
        return URL(fileURLWithPath: path)
    }

    /// Writes one batch into `outputDirectory/<namespace>/turn-<index>.wav`.
    ///
    /// The subdirectory is what keeps batches apart: the index restarts at zero
    /// for every call, so ten anecdotes written flat would leave one survivor.
    ///
    /// Called once per anecdote and still one session for the whole batch —
    /// `start()` returns immediately while the process is alive, so the model
    /// load is paid on the first call and no other.
    public func synthesize(_ turns: [VoicedTurn], namespace: String) async throws -> [URL] {
        // Nothing to say costs nothing: an empty batch must not pay a model
        // load, and must not leave an empty directory behind either.
        guard !turns.isEmpty else { return [] }

        let directory = outputDirectory.appendingPathComponent(namespace)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        } catch {
            throw SpeechError.synthesisFailed(
                "cannot create \(directory.path): \(error)"
            )
        }
        try start()

        var produced: [URL] = []
        for (index, turn) in turns.enumerated() {
            let destination = directory.appendingPathComponent("turn-\(index).wav")
            let request = Self.requestLine(for: turn, outputPath: destination.path)
            try write(request)
            produced.append(try Self.parseResponse(try readResponseLine()))
        }
        return produced
    }

    /// Starts the sidecar, or restarts it if a previous session died. A crashed
    /// synthesizer must not wedge the app.
    private func start() throws {
        if let process, process.isRunning { return }
        // A dead session still owns its pipe descriptors. Releasing them here is
        // what stops a restart loop from leaking four of them per attempt.
        discardSession()

        guard FileManager.default.isReadableFile(atPath: scriptPath) else {
            throw SpeechError.sidecarUnavailable("script not found at \(scriptPath)")
        }

        // Settled here rather than left to the child. A missing ffmpeg reaches
        // Swift as `[Errno 2] No such file or directory: 'ffmpeg'` on the first
        // clip of the batch — an opaque errno charged to synthesis, after the
        // model load has already been paid for a batch that cannot produce
        // anything. An unresolvable tool is a fact about the installation.
        //
        // ffprobe is deliberately not checked: `duration()` reaches for it only
        // when `wave` cannot open the clip, which the normalised output never
        // is, so demanding it would refuse a sidecar that works. It is on the
        // PATH above regardless, since Homebrew ships it beside ffmpeg.
        guard Self.resolves("ffmpeg", on: environment["PATH"] ?? "") else {
            throw SpeechError.sidecarUnavailable("ffmpeg not found on PATH")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath, "--serve"]
        // A working directory holding a `coverage/` directory shadows the PyPI
        // package, and the failure surfaces as an unrelated numba error.
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        // Set explicitly, because the default is to inherit this process's own
        // — which under launchd is not one the sidecar's tools can be found on.
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        // Discarded rather than piped: coqui-tts is chatty on stderr, and an
        // undrained pipe would stall the child once its buffer filled.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw SpeechError.sidecarUnavailable(String(describing: error))
        }

        self.process = process
        self.input = stdin.fileHandleForWriting
        self.output = stdout.fileHandleForReading
        self.pending = Data()
    }

    /// Lets go of a finished session so the next start begins clean.
    private func discardSession() {
        try? input?.close()
        try? output?.close()
        process = nil
        input = nil
        output = nil
        pending = Data()
    }

    private func write(_ line: String) throws {
        guard let input else {
            throw SpeechError.sidecarUnavailable("sidecar stdin is closed")
        }
        do {
            // The throwing form on purpose: the older `write(_:)` raises an
            // Objective-C exception on a broken pipe, which Swift cannot catch.
            try input.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            discardSession()
            throw SpeechError.sidecarUnavailable("cannot reach the sidecar: \(error)")
        }
    }

    /// Waits for one complete reply line.
    ///
    /// There is no timeout: synthesis genuinely takes seconds and a cold model
    /// load takes over a minute, so a slow answer is not a failure. A sidecar
    /// that dies closes its output, and that end-of-file is the signal — a
    /// partial line followed by death ends the same way rather than hanging.
    private func readResponseLine() throws -> String {
        guard let output else {
            throw SpeechError.sidecarUnavailable("sidecar stdout is closed")
        }
        while true {
            if let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = output.availableData
            guard !chunk.isEmpty else {
                // Dropped rather than kept: `isRunning` can still read true in
                // the window before the child is reaped, and reusing these
                // handles would write the next request into a dead pipe.
                discardSession()
                throw SpeechError.synthesisFailed("sidecar closed its output")
            }
            pending.append(chunk)
        }
    }
}
