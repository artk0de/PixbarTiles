import Foundation
import Testing
@testable import AwtrixKit

// MARK: - The stub, which is what lets everything above this line run

@Test func stubSynthesizerReturnsOneURLPerTurn() async throws {
    let stub = StubSpeechSynthesizer()

    let urls = try await stub.synthesize([
        VoicedTurn(voice: .arthas, text: "раз"),
        VoicedTurn(voice: .peon, text: "два"),
    ], namespace: "batch")

    #expect(urls.count == 2)
}

@Test func stubSynthesizerRecordsWhatItWasAsked() async throws {
    let stub = StubSpeechSynthesizer()

    _ = try await stub.synthesize(
        [VoicedTurn(voice: .peon, text: "работа-работа")], namespace: "batch"
    )

    #expect(stub.received.map(\.voice.id) == ["peon"])
    #expect(stub.received.map(\.text) == ["работа-работа"])
}

// MARK: - The sidecar's line protocol

@Test func sidecarRequestLineAddressesTheVoiceByName() throws {
    let line = SidecarSpeechSynthesizer.requestLine(
        for: VoicedTurn(voice: .arthas, text: "Внимание, анекдот"),
        outputPath: "/tmp/turn0.wav"
    )
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]

    #expect(object["voice"] as? String == "arthas")
    #expect(object["text"] as? String == "Внимание, анекдот")
    #expect(object["out"] as? String == "/tmp/turn0.wav")
    #expect(!line.contains("\n"))  // one request per line
}

// The synthesizer, not the caller, is where normalisation is applied — so a
// request built anywhere carries the prepared text.
@Test func sidecarRequestLineSendsTheNormalisedText() throws {
    let line = SidecarSpeechSynthesizer.requestLine(
        for: VoicedTurn(voice: .arthas, text: "Сеть «Вкусно — и точка»."),
        outputPath: "/tmp/turn0.wav"
    )
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]

    #expect(object["text"] as? String == "Сеть Вкусно и точка")
}

// The protocol is line-delimited; an embedded newline would desync the stream.
@Test func sidecarRequestLineStaysOneLineWhenTheTextContainsANewline() throws {
    let line = SidecarSpeechSynthesizer.requestLine(
        for: VoicedTurn(voice: .peon, text: "первая\nвторая"),
        outputPath: "/tmp/turn0.wav"
    )
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]

    #expect(!line.contains("\n"))
    #expect(object["text"] as? String == "первая вторая")
}

@Test func sidecarResponseYieldsTheProducedFile() throws {
    let url = try SidecarSpeechSynthesizer.parseResponse(
        #"{"ok":true,"voice":"peon","out":"/tmp/turn-1.wav","duration":3.52}"#
    )

    #expect(url.path == "/tmp/turn-1.wav")
}

@Test func sidecarFailureResponseSurfacesTheReportedReason() {
    #expect(throws: SpeechError.self) {
        _ = try SidecarSpeechSynthesizer.parseResponse(
            #"{"ok":false,"error":"unknown voice: foo (have: arthas, peon)"}"#
        )
    }
}

@Test func unparseableSidecarOutputIsAFailureNotACrash() {
    #expect(throws: SpeechError.self) {
        _ = try SidecarSpeechSynthesizer.parseResponse("Traceback (most recent call last):")
    }
}

// A success reply with no file is still a failure: there is nothing to play.
@Test func successWithoutAFileIsAFailure() {
    #expect(throws: SpeechError.self) {
        _ = try SidecarSpeechSynthesizer.parseResponse(#"{"ok":true,"duration":3.52}"#)
    }
}

@Test func missingSidecarScriptIsReportedAsUnavailable() async {
    let synthesizer = SidecarSpeechSynthesizer(
        pythonPath: "/usr/bin/false",
        scriptPath: "/nonexistent/speak.py",
        workingDirectory: NSTemporaryDirectory(),
        outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
    )

    await #expect(throws: SpeechError.self) {
        _ = try await synthesizer.synthesize(
            [VoicedTurn(voice: .arthas, text: "hi")], namespace: "batch"
        )
    }
}

// Nothing to say costs nothing: an empty batch must not start a 1.8 GB model,
// which is why this succeeds against a sidecar that does not exist.
@Test func anEmptyBatchNeverReachesTheSidecar() async throws {
    let synthesizer = SidecarSpeechSynthesizer(
        pythonPath: "/usr/bin/false",
        scriptPath: "/nonexistent/speak.py",
        workingDirectory: NSTemporaryDirectory(),
        outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
    )

    let urls = try await synthesizer.synthesize([], namespace: "batch")

    #expect(urls.isEmpty)
}

// MARK: - One session per batch, against a real child process

/// Writes a stand-in for `speak.py` and returns its path.
///
/// It records every process start, then answers one request per line the way
/// the real sidecar does. A shell script rather than a mock because the claim
/// under test is about process lifetime, and a mock cannot have one.
private func fakeSidecar(recordingStartsTo marker: String, in directory: URL) throws -> String {
    let script = directory.appendingPathComponent("fake_sidecar.sh").path
    try """
    echo start >> \(marker)
    while IFS= read -r line; do
      out=$(printf '%s' "$line" | sed -n 's/.*"out":"\\([^"]*\\)".*/\\1/p')
      printf '{"ok":true,"out":"%s"}\\n' "$out"
    done
    """.write(toFile: script, atomically: true, encoding: .utf8)
    return script
}

// The economics the whole queue rests on. Loading the model costs 70 seconds
// and the synthesis on top of it costs fractions of a second, so a batch of ten
// is only worth preparing if the ten share one session. The preparer calls
// `synthesize` once per anecdote, which is exactly the shape that would pay the
// load ten times if the session did not outlive the call.
@Test func abatchOfAnecdotesSharesOneSidecarSession() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sidecar-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let marker = root.appendingPathComponent("starts.log").path
    let synthesizer = SidecarSpeechSynthesizer(
        pythonPath: "/bin/sh",
        scriptPath: try fakeSidecar(recordingStartsTo: marker, in: root),
        workingDirectory: root.path,
        outputDirectory: root
    )

    // Two anecdotes, driven the way `AnecdotePreparer.refill` drives them.
    let first = try await synthesizer.synthesize(
        [VoicedTurn(voice: .arthas, text: "раз"), VoicedTurn(voice: .peon, text: "два")],
        namespace: "anecdote-one"
    )
    let second = try await synthesizer.synthesize(
        [VoicedTurn(voice: .arthas, text: "три")], namespace: "anecdote-two"
    )

    let starts = try String(contentsOfFile: marker, encoding: .utf8)
        .split(whereSeparator: \.isNewline).count
    #expect(starts == 1)

    // And the namespace reaches the real output path, not just the stub's.
    // Both batches name their first file turn-0.wav — that collision is what
    // used to leave one survivor out of ten.
    #expect(first.map(\.lastPathComponent) == ["turn-0.wav", "turn-1.wav"])
    #expect(second.map(\.lastPathComponent) == ["turn-0.wav"])
    #expect(Set(first).isDisjoint(with: Set(second)))
}

// MARK: - Normalisation. Every rule below fixes a defect that was heard.

@Test func quotationMarksAreRemovedBecauseXttsSpeaksThem() {
    // `точка»` came out as "точкала" — the closing quote became a syllable.
    #expect(SpeechText.prepare("Сеть «Вкусно и точка» решила") == "Сеть Вкусно и точка решила")
}

@Test func everyQuotationVariantIsRemoved() {
    #expect(SpeechText.prepare("“a” „b‟ \"c\" 'd' ‘e’ `f´") == "a b c d e f")
}

// Removed rather than deleted in place: dropping the character outright would
// fuse the two words a quote separates.
@Test func removingAQuoteDoesNotFuseTheWordsAroundIt() {
    #expect(SpeechText.prepare("он сказал:«да»и ушёл") == "он сказал: да и ушёл")
}

@Test func aDashBetweenSpacesIsDropped() {
    // Kept, it pauses long enough to sound like a fault.
    #expect(SpeechText.prepare("Вкусно — и точка") == "Вкусно и точка")
}

@Test func aHyphenInsideAWordSurvives() {
    // The dash rule is bounded by spaces on purpose: "работа-работа" is one word.
    #expect(SpeechText.prepare("работа-работа") == "работа-работа")
}

@Test func aSpacedAsciiHyphenIsNotTreatedAsADash() {
    // The dash rule matches em and en dashes only. Widening it to the ASCII
    // hyphen would eat the minus sign out of arithmetic.
    #expect(SpeechText.prepare("50 - 30") == "50 - 30")
}

@Test func aTrailingFullStopIsRemoved() {
    // It provokes the decoder into appending an audible fragment after the
    // sentence, separated by 0.2 s of real silence at −94 dB.
    #expect(SpeechText.prepare("Он ушёл.") == "Он ушёл")
}

@Test func afullStopInsideTheSentenceSurvives() {
    #expect(SpeechText.prepare("Вкусно. И точка.") == "Вкусно. И точка")
}

@Test func aTrailingQuestionMarkIsKeptAndGetsASpace() {
    // The mark carries the intonation — measured at 18.5 Hz of relative pitch
    // rise — and without the space the final consonant is swallowed.
    #expect(SpeechText.prepare("Правда?") == "Правда? ")
}

@Test func aTrailingExclamationIsKeptAndGetsASpace() {
    #expect(SpeechText.prepare("Анекдот!") == "Анекдот! ")
}

// An ellipsis after a question mark is ordinary Russian. Stripping the dots
// must not cost the sentence its intonation space.
@Test func aQuestionMarkFollowedByDotsStillGetsItsSpace() {
    #expect(SpeechText.prepare("Правда?..") == "Правда? ")
}

@Test func whitespaceRunsCollapseAndNoSpacePrecedesPunctuation() {
    #expect(SpeechText.prepare("Он  сказал «да» , и ушёл") == "Он сказал да, и ушёл")
}

@Test func anEmptyOrBlankLineNormalisesToNothing() {
    #expect(SpeechText.prepare("") == "")
    #expect(SpeechText.prepare("   \n  ") == "")
}

// Documented, not desirable: the sidecar rejects empty text, so a caller must
// not hand it a line that has nothing left after normalisation.
@Test func aPunctuationOnlyLineNormalisesToNothing() {
    #expect(SpeechText.prepare("...") == "")
    #expect(SpeechText.prepare("«»") == "")
}

// Stress marking is deliberately absent. `+` and the combining acute are not in
// the XTTS BPE vocabulary, encode to `[UNK]` and corrupt their neighbours; a
// capital is lowercased before tokenization. All four conventions were tested
// by ear and all four fail, so the text passes through unmarked.
@Test func noStressMarkIsAdded() {
    #expect(SpeechText.prepare("Он открыл замок") == "Он открыл замок")
}
