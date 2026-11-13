import Foundation

/// A recording in, a stored dictation out: whisper, then the fix step when asked for.
/// The app and dictate-cli both go through here, so what the evaluation measures is what
/// gets pasted.
public final class Pipeline: Sendable {
    public enum Stage: Sendable {
        case transcribing
        case cleaningUp
    }

    public let transcriber: Transcriber
    public let store: Store?

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
            id: UUID().uuidString, createdAt: Date(), timeZone: TimeZone.current.identifier, audioPath: audio.path,
            duration: duration,
            mode: mode, whisperModel: transcriber.modelName,
            rawText: transcript.text, finalText: transcript.text,
            cleanupModel: cleanup?.modelName, cleanupSystem: cleanup.map { fixScope == .whole ? $0.system : TargetedFix.system },
            timings: .init(record: recordMs, load: Self.ms(loadSeconds), transcribe: Self.ms(transcript.seconds),
                           retry: Self.ms(transcript.retryAfterStop)),
            segments: transcript.segments)
        if let cleanup {
            let transcriber = transcriber
            let asked = ContinuousClock.now
            let outcome = await Self.fix(transcript, settings: cleanup, scope: fixScope,
                                         flagBelow: whisper.retry.logprobBelow, beforeOllama: {
                // On a 16 GB Mac, whisper's GPU memory plus a 27B model's is more than Metal
                // allows, and Ollama's runner then fails every request until its model is
                // unloaded. Whisper gives its memory back first; reloading it costs 0.4 s.
                await transcriber.unload()
            }, beforeModel: { onStage(.cleaningUp) })
            dictation.finalText = outcome.text
            if fixScope != .whole { dictation.fixEdits = outcome.edits }
            if outcome.askedOllama { dictation.timings.cleanup = Self.ms(outcome.seconds) }
            dictation.error = outcome.error
            if outcome.askedOllama, let store {
                // Including whisper's unload, which the fix waits for. The model's own time is
                // the cleanup timing.
                let entry = ModelTimings.Entry(
                    work: .fix, kind: cleanup.engine == .apple ? .apple : .ollama,
                    outcome: outcome.error == nil ? .ok : .failed,
                    totalMs: (ContinuousClock.now - asked).milliseconds, modelMs: Self.ms(outcome.seconds))
                try? ModelTimings.record(entry, at: store.url)
            }
        }
        try store?.insert(dictation)
        return dictation
    }

    /// The fix step on its own, as the app runs it, so dictate-cli can measure exactly this.
    /// A scope that sends no segment returns at once without touching the model or whisper. A
    /// failure keeps whisper's text and says why, so the words aren't lost. `beforeOllama`
    /// runs only for an editor that competes with whisper for memory; `beforeModel` runs for
    /// every editor, after it. `editor` defaults to the settings' engine.
    public static func fix(_ transcript: Transcript, settings: CleanupSettings, scope: FixScope,
                           flagBelow: Double = SegmentRetry().logprobBelow,
                           editor: (any FixEditor)? = nil,
                           beforeOllama: @Sendable () async -> Void = {},
                           beforeModel: @Sendable () async -> Void = {}) async -> FixOutcome {
        let segments = transcript.segments
        let flagged = TargetedFix.sent(segments, scope: scope, flagBelow: flagBelow)
        var outcome = FixOutcome(text: transcript.text, flagged: flagged, edits: [], askedOllama: false, seconds: 0)
        guard !transcript.text.isEmpty, !flagged.isEmpty else { return outcome }
        let editor = editor ?? FixEditors.editor(for: settings)
        if editor.unloadsWhisper { await beforeOllama() }
        await beforeModel()
        let start = ContinuousClock.now
        outcome.askedOllama = true
        do {
            switch scope {
            case .whole:
                let text = try await editor.rewrite(transcript.text, settings: settings)
                if !text.isEmpty { outcome.text = text }
            case .every, .flagged:
                let proposed = try await editor.edits(segments, flagged: flagged, settings: settings)
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
