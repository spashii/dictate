import Foundation

/// How long a recording's audio file stays after it was made.
public enum AudioRetention: String, CaseIterable, Sendable {
    case untilTranscribed, oneDay, sevenDays, forever
}

/// How long a recording's transcript stays in History, search and the agent server.
public enum TranscriptRetention: String, CaseIterable, Sendable {
    case sevenDays, thirtyDays, forever
}

/// What the automatic deletion may remove. Developer mode protects data, so it keeps
/// everything, and Forever for audio is a developer-only choice.
public struct RetentionPolicy: Equatable, Sendable {
    public var audio: AudioRetention
    public var transcripts: TranscriptRetention

    public init(audio: AudioRetention, transcripts: TranscriptRetention) {
        self.audio = audio
        self.transcripts = transcripts
    }

    public static let keepEverything = RetentionPolicy(audio: .forever, transcripts: .forever)
    public static let defaultAudio = AudioRetention.sevenDays
    public static let defaultTranscripts = TranscriptRetention.thirtyDays

    public static func effective(audio: AudioRetention?, transcripts: TranscriptRetention?,
                                 developerMode: Bool) -> RetentionPolicy {
        if developerMode { return .keepEverything }
        return RetentionPolicy(audio: shownAudio(audio, developerMode: false),
                               transcripts: transcripts ?? defaultTranscripts)
    }

    /// What the audio picker displays: an unset choice shows Forever in developer mode, and a
    /// stored Forever reads as the default once developer mode is off.
    public static func shownAudio(_ stored: AudioRetention?, developerMode: Bool) -> AudioRetention {
        if developerMode { return stored ?? .forever }
        return stored == .forever ? defaultAudio : stored ?? defaultAudio
    }

    public static func shownTranscripts(_ stored: TranscriptRetention?, developerMode: Bool) -> TranscriptRetention {
        stored ?? (developerMode ? .forever : defaultTranscripts)
    }
}

/// The pickers' stored choices, nil while a picker was never touched, so the default can
/// depend on developer mode. The old "history" key is not read: every install starts from
/// the new defaults.
public struct RetentionChoices: Equatable, Sendable {
    public var audio: AudioRetention?
    public var transcripts: TranscriptRetention?

    public init(audio: AudioRetention? = nil, transcripts: TranscriptRetention? = nil) {
        self.audio = audio
        self.transcripts = transcripts
    }

    public static let audioKey = "audioRetention"
    public static let transcriptsKey = "transcriptRetention"

    public static func load(from defaults: UserDefaults) -> RetentionChoices {
        RetentionChoices(
            audio: defaults.string(forKey: audioKey).flatMap(AudioRetention.init(rawValue:)),
            transcripts: defaults.string(forKey: transcriptsKey).flatMap(TranscriptRetention.init(rawValue:)))
    }

    public func save(to defaults: UserDefaults) {
        if let audio { defaults.set(audio.rawValue, forKey: Self.audioKey) } else { defaults.removeObject(forKey: Self.audioKey) }
        if let transcripts {
            defaults.set(transcripts.rawValue, forKey: Self.transcriptsKey)
        } else {
            defaults.removeObject(forKey: Self.transcriptsKey)
        }
    }

    /// Keep forever only exists while developer mode is on, so turning it off drops that
    /// choice back to the default.
    public func afterDeveloperModeOff() -> RetentionChoices {
        RetentionChoices(audio: audio == .forever ? nil : audio, transcripts: transcripts)
    }
}

/// What a deletion pass removed, or would remove: for the log, and for the confirmation
/// that names the counts before anything goes.
public struct RetentionCounts: Equatable, Sendable {
    /// Whole recordings, transcript and audio.
    public var recordings: Int
    /// Recordings that keep their transcript but lose their audio file.
    public var audioOnly: Int

    public init(recordings: Int = 0, audioOnly: Int = 0) {
        self.recordings = recordings
        self.audioOnly = audioOnly
    }

    public var isEmpty: Bool { recordings == 0 && audioOnly == 0 }
}

/// The deletion pass over dictations and calls. `preview` counts what `run` would delete on
/// the same data, so a confirmation can name the numbers first.
public enum RetentionSweep {
    private struct Cutoffs {
        var transcripts: Date?
        /// Audio of recordings that finished well is deleted before this date.
        var finishedAudio: Date
        /// Audio of any recording, failed or not, is deleted before this date.
        var anyAudio: Date

        init(_ policy: RetentionPolicy, now: Date) {
            let day: TimeInterval = 24 * 3600
            switch policy.transcripts {
            case .sevenDays: transcripts = now.addingTimeInterval(-7 * day)
            case .thirtyDays: transcripts = now.addingTimeInterval(-30 * day)
            case .forever: transcripts = nil
            }
            // A failed recording's audio is what a retry needs, so Until transcribed never
            // deletes it; it goes with the row.
            switch policy.audio {
            case .untilTranscribed: (finishedAudio, anyAudio) = (.distantFuture, .distantPast)
            case .oneDay: (finishedAudio, anyAudio) = (.distantPast, now.addingTimeInterval(-day))
            case .sevenDays: (finishedAudio, anyAudio) = (.distantPast, now.addingTimeInterval(-7 * day))
            case .forever: (finishedAudio, anyAudio) = (.distantPast, .distantPast)
            }
        }
    }

    public static func preview(_ policy: RetentionPolicy, dictations: Store?, calls: CallStore?,
                               now: Date = Date()) -> RetentionCounts {
        let cut = Cutoffs(policy, now: now)
        var counts = RetentionCounts()
        if let dictations {
            if let before = cut.transcripts { counts.recordings += dictations.countRows(before: before) }
            counts.audioOnly += dictations.audioFiles(finishedBefore: cut.finishedAudio, anyBefore: cut.anyAudio,
                                                      keptFrom: cut.transcripts).count
        }
        if let calls {
            if let before = cut.transcripts { counts.recordings += (try? calls.countCalls(before: before)) ?? 0 }
            let withAudio = (try? calls.callsWithAudio(finishedBefore: cut.finishedAudio, anyBefore: cut.anyAudio,
                                                       keptFrom: cut.transcripts)) ?? []
            counts.audioOnly += withAudio.filter { FileManager.default.fileExists(atPath: $0.path) }.count
        }
        return counts
    }

    /// Transcripts first, then audio. Calls still recording or transcribing are never touched.
    /// `deleteCallAudio` lets the app route call audio through the recorder, which never
    /// deletes under a running compression.
    @discardableResult
    public static func run(_ policy: RetentionPolicy, dictations: Store?, calls: CallStore?,
                           deleteCallAudio: ((String) -> Bool)? = nil, now: Date = Date()) -> RetentionCounts {
        let cut = Cutoffs(policy, now: now)
        var counts = RetentionCounts()
        if let before = cut.transcripts {
            if let dictations { counts.recordings += dictations.prune(before: before) }
            if let calls { counts.recordings += (try? calls.prune(before: before)) ?? 0 }
        }
        if let dictations {
            counts.audioOnly += dictations.deleteAudio(finishedBefore: cut.finishedAudio, anyBefore: cut.anyAudio)
        }
        if let calls {
            let delete = deleteCallAudio ?? { (try? calls.clearAudio($0)) ?? false }
            let ids = (try? calls.callsWithAudio(finishedBefore: cut.finishedAudio, anyBefore: cut.anyAudio,
                                                 keptFrom: nil)) ?? []
            for call in ids where delete(call.id) { counts.audioOnly += 1 }
        }
        return counts
    }
}
