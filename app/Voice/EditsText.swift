import SwiftUI
import VoiceCore

/// The changed words after a paste: the old struck through, the new beside it.
struct EditsLine: View {
    let changes: [WordDiff.Change]

    var body: some View {
        let shown = changes.prefix(3)
        let more = changes.count - shown.count
        shown.enumerated().reduce(Text("")) { line, item in
            let (i, change) = item
            return line + Text(i == 0 ? "" : "   ") + DiffText.text(change)
        }
        + Text(more > 0 ? "   +\(more)" : "").foregroundStyle(.secondary)
    }
}

enum DiffText {
    /// One change as text: what was there struck through, then what replaced it.
    static func text(_ change: WordDiff.Change) -> Text {
        let before = change.before.joined(separator: " ")
        let after = change.after.joined(separator: " ")
        let old = before.isEmpty ? Text("") : Text(before).strikethrough().foregroundStyle(.secondary)
        let new = after.isEmpty ? Text("") : Text(after).foregroundStyle(.green)
        return old + Text(!before.isEmpty && !after.isEmpty ? " " : "") + new
    }
}
