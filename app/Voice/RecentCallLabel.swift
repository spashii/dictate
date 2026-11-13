import Foundation
import VoiceCore

extension Call {
    /// What the menu and the pill call a call nobody titled: its app's call, or just Call. An
    /// import is named by its file.
    var untitledName: String {
        fileName ?? appName.map { "\($0) call" } ?? "Call"
    }

    /// What the menu and the pill call it: its title, or what it is.
    var displayName: String { title ?? untitledName }
}

/// The menu's text for a recent call. An untitled call is one line, "Slack call, 14:05 · 32 min".
/// A titled one puts the title first and that same line under it, so the app, the time and
/// how it ended are still there.
enum RecentCallLabel {
    static let titleLimit = 60

    struct Lines: Equatable {
        var title: String?
        var detail: String
    }

    static func lines(_ call: Call, time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) -> Lines {
        let minutes = call.endedAt.map { " · \(max(1, Int($0.timeIntervalSince(call.startedAt) / 60))) min" } ?? ""
        let live = call.fileName == nil ? "recording" : "importing"
        let state = call.status == .failed ? " · failed" : call.status.isLive ? " · \(live)" : ""
        let detail = "\(call.untitledName), \(time(call.startedAt))\(minutes)\(state)"
        guard let title = call.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return Lines(title: nil, detail: detail)
        }
        return Lines(title: cut(title), detail: detail)
    }

    static func cut(_ title: String) -> String {
        guard title.count > titleLimit else { return title }
        return title.prefix(titleLimit - 1).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
