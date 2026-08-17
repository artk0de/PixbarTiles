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
    private let outputDirectory: URL

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()

    public init(
        pythonPath: String,
        scriptPath: String,
        workingDirectory: String,
        outputDirectory: URL
    ) {
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
        self.workingDirectory = workingDirectory
        self.outputDirectory = outputDirectory
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath, "--serve"]
        // A working directory holding a `coverage/` directory shadows the PyPI
        // package, and the failure surfaces as an unrelated numba error.
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

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
