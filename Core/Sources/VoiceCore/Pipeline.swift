import Foundation

/// A recording in, a stored dictation out: whisper, then the fix step when asked for.
/// The app and voice-cli both go through here, so what the evaluation measures is what
/// gets pasted.
public final class Pipeline: Sendable {
    public enum Stage: Sendable {
        case transcribing
        case cleaningUp
    }

    public let transcriber: Transcriber
    public let store: Store?
    private let ollama = Ollama()

    public init(transcriber: Transcriber, store: Store?) {
        self.transcriber = transcriber
        self.store = store
    }

    /// `stoppedAt` is when the recording was stopped, from which retries that delay the
    /// paste are counted. With `cleanup`, the fix step runs on `fixScope`: by default every
    /// segment, answered with edits.
    public func run(_ audio: URL, recordMs: Int? = nil, whisper: WhisperOptions = WhisperOptions(),
                    cleanup: CleanupSettings? = nil, fixScope: FixScope = .every,
                    live: LiveTranscription? = nil, stoppedAt: ContinuousClock.Instant = .now,
                    onStage: @escaping @Sendable (Stage) -> Void = { _ in }) async throws -> Dictation {
        onStage(.transcribing)
        var loadSeconds = 0.0
        let transcript: Transcript
        let duration: Double
        // The chunks decoded while recording are the result: a whole-file decode on top
        // would have to wait out the prompt's model and then hold whisper's queue against
        // the next dictation. When a chunk failed, the file is decoded as before.
        if let live, let joined = try? await live.finish(stoppedAt: stoppedAt) {
            transcript = joined
            duration = live.duration
        } else {
            let samples = try Audio.load(audio)
            loadSeconds = try await transcriber.load()
            var whole = try await transcriber.transcribe(samples, options: whisper)
            // Decoded after the stop, so every retry second is waited for.
            whole.retryAfterStop = whole.retrySeconds
            transcript = whole
            duration = Double(samples.count) / Audio.sampleRate
        }
        let mode: Dictation.Mode = cleanup == nil ? .plain : fixScope == .whole ? .cleanup : .fix
        var dictation = Dictation(
            id: UUID().uuidString, createdAt: Date(), audioPath: audio.path,
            duration: duration,
            mode: mode, whisperModel: transcriber.modelName,
            rawText: transcript.text, finalText: transcript.text,
            cleanupModel: cleanup?.model, cleanupSystem: cleanup.map { fixScope == .whole ? $0.system : TargetedFix.system },
            timings: .init(record: recordMs, load: Self.ms(loadSeconds), transcribe: Self.ms(transcript.seconds),
                           retry: Self.ms(transcript.retryAfterStop)),
            segments: transcript.segments)
        if let cleanup {
            let transcriber = transcriber
            let outcome = await Self.fix(transcript, settings: cleanup, scope: fixScope,
                                         flagBelow: whisper.retry.logprobBelow, beforeOllama: {
                // On a 16 GB Mac, whisper's GPU memory plus a 27B model's is more than Metal
                // allows, and Ollama's runner then fails every request until its model is
                // unloaded. Whisper gives its memory back first; reloading it costs 0.4 s.
                await transcriber.unload()
                onStage(.cleaningUp)
            })
            dictation.finalText = outcome.text
            if fixScope != .whole { dictation.fixEdits = outcome.edits }
            if outcome.askedOllama { dictation.timings.cleanup = Self.ms(outcome.seconds) }
            dictation.error = outcome.error
        }
        try store?.insert(dictation)
        return dictation
    }

    /// The fix step on its own, as the app runs it, so voice-cli can measure exactly this.
    /// A scope that sends no segment returns at once without touching Ollama or whisper. A
    /// failure keeps whisper's text and says why, so the words aren't lost.
    public static func fix(_ transcript: Transcript, settings: CleanupSettings, scope: FixScope,
                           flagBelow: Double = SegmentRetry().logprobBelow,
                           beforeOllama: @Sendable () async -> Void = {}) async -> FixOutcome {
        let segments = transcript.segments
        let flagged = TargetedFix.sent(segments, scope: scope, flagBelow: flagBelow)
        var outcome = FixOutcome(text: transcript.text, flagged: flagged, edits: [], askedOllama: false, seconds: 0)
        guard !transcript.text.isEmpty, !flagged.isEmpty else { return outcome }
        await beforeOllama()
        let start = ContinuousClock.now
        outcome.askedOllama = true
        do {
            switch scope {
            case .whole:
                let result = try await Ollama().cleanup(transcript.text, settings: settings)
                if !result.text.isEmpty { outcome.text = result.text }
            case .every, .flagged:
                let proposed = try await Ollama().edits(segments, flagged: flagged, settings: settings).edits
                outcome.edits = TargetedFix.validate(proposed, segments: segments, flagged: flagged)
                if outcome.edits.contains(where: \.applied) {
                    outcome.text = TargetedFix.join(TargetedFix.apply(outcome.edits, to: segments))
                }
            }
        } catch {
            outcome.error = "\(error)"
        }
        outcome.seconds = (ContinuousClock.now - start).seconds
        return outcome
    }

    static func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }
}
