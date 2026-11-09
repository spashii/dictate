import SwiftUI
import VoiceCore

/// The suggested key terms as Settings shows them, without the loading, so the rows can be
/// drawn on their own: each term with how whisper heard it, Add and Dismiss, and a refusal
/// under its row.
struct SuggestedTermsList: View {
    let suggestions: [TermSuggestion]
    let refused: [Int64: String]
    let busy: Int64?
    let decide: (Int64, Bool) -> Void

    var body: some View {
        Group {
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested").foregroundStyle(.secondary)
                    ForEach(suggestions) { suggestion in
                        row(suggestion)
                    }
                }
            }
        }
    }

    private func row(_ suggestion: TermSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(suggestion.term)
                Text(suggestion.heard.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("How whisper heard it")
                Spacer()
                Button("Add") { decide(suggestion.id, true) }
                Button("Dismiss") { decide(suggestion.id, false) }
            }
            .disabled(busy != nil)
            if let message = refused[suggestion.id] {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
