import VoiceCore

/// Every retention string the app shows, so a copy change is one edit here.
enum RetentionText {
    static let groupTitle = "Data retention"
    static let audioLabel = "Keep audio recordings"
    static let historyLabel = "Keep history"
    static let developerModeFooter = "Developer mode is on, so nothing is deleted."
    static let audioDeleted = "Audio deleted"

    static func title(_ audio: AudioRetention) -> String {
        switch audio {
        case .untilTranscribed: "Until transcribed"
        case .oneDay: "1 day"
        case .sevenDays: "7 days"
        case .forever: "Forever"
        }
    }

    static func title(_ transcripts: TranscriptRetention) -> String {
        switch transcripts {
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .forever: "Forever"
        }
    }

    /// Forever keeps audio for good, which only Developer mode may do.
    static func audioOptions(developerMode: Bool) -> [AudioRetention] {
        developerMode ? AudioRetention.allCases : AudioRetention.allCases.filter { $0 != .forever }
    }

    static let transcriptOptions = TranscriptRetention.allCases

    struct Alert: Equatable {
        var title: String
        var body: String
        var confirm: String
        var cancel = "Cancel"
    }

    static func turnOffDeveloperMode(counts: RetentionCounts, policy: RetentionPolicy) -> Alert {
        Alert(title: "Turn off Developer mode?", body: body(counts: counts, policy: policy),
              confirm: "Turn Off and Delete")
    }

    static func deleteOldRecordings(counts: RetentionCounts, policy: RetentionPolicy) -> Alert {
        Alert(title: "Delete old recordings?", body: body(counts: counts, policy: policy), confirm: "Delete")
    }

    /// What would go, from the counts and the policy that would delete it.
    static func body(counts: RetentionCounts, policy: RetentionPolicy) -> String {
        var parts: [String] = []
        if counts.recordings > 0 {
            parts.append(recordings(counts.recordings) + transcriptAge(policy.transcripts))
        }
        if counts.audioOnly > 0 {
            let more = counts.recordings > 0 ? " more" : ""
            let what = counts.recordings > 0 ? "\(counts.audioOnly)\(more)" : recordings(counts.audioOnly)
            parts.append("the audio of \(what)" + audioAge(policy.audio))
        }
        guard !parts.isEmpty else { return "" }
        return "Dictate will delete \(parts.joined(separator: " and ")). You can\u{2019}t undo this."
    }

    private static func recordings(_ count: Int) -> String {
        count == 1 ? "1 recording" : "\(count) recordings"
    }

    // Forever never deletes, so its suffix is empty and unreachable in a real confirmation.
    private static func transcriptAge(_ transcripts: TranscriptRetention) -> String {
        switch transcripts {
        case .sevenDays: " older than 7 days"
        case .thirtyDays: " older than 30 days"
        case .forever: ""
        }
    }

    private static func audioAge(_ audio: AudioRetention) -> String {
        switch audio {
        case .untilTranscribed: " that are already transcribed"
        case .oneDay: " older than 1 day"
        case .sevenDays: " older than 7 days"
        case .forever: ""
        }
    }
}
