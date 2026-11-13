import Foundation
import VoiceCore

/// What History lists. An import is a call made from a file, so Calls leaves it to Files.
enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case dictations = "Dictations"
    case calls = "Calls"
    case files = "Files"

    var id: String { rawValue }

    func includes(_ entry: HistoryEntry) -> Bool {
        switch self {
        case .all: true
        case .dictations: entry.kind == .dictation
        case .calls: entry.kind == .call && entry.fileName == nil
        case .files: entry.fileName != nil
        }
    }
}

/// What a History row says about an import: queued behind another, being transcribed, failed
/// with a reason, or nothing special once it is done.
enum ImportRowState: Equatable {
    case waiting
    case transcribing(Double)
    case failed(String)
    case ready

    /// Nil for a dictation or a recorded call.
    static func of(_ entry: HistoryEntry, progress: Double?, waiting: Bool) -> ImportRowState? {
        guard entry.fileName != nil else { return nil }
        if waiting { return .waiting }
        if let progress { return .transcribing(progress) }
        if let reason = entry.error { return .failed(reason) }
        return .ready
    }

    /// An import's length is 0 until its file has been read.
    static func showsDuration(_ entry: HistoryEntry) -> Bool {
        entry.fileName == nil || entry.duration > 0
    }
}

/// Which of a drop's files History imports.
enum ImportDrop {
    static func supported(_ urls: [URL]) -> [URL] {
        urls.filter { $0.isFileURL && AudioImport.supportedExtensions.contains($0.pathExtension.lowercased()) }
    }

    static let refusal = "Only audio and video files can be imported."
}

/// A dictation that ends while Dictate is the frontmost app would be pasted into Dictate's
/// own window, which is History's search field.
enum PasteDecision {
    static func pastes(frontmostPID: pid_t?, ownPID: pid_t) -> Bool {
        frontmostPID != ownPID
    }
}
