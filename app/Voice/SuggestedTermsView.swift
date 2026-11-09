import SwiftUI
import VoiceCore

/// The key terms agents' corrections proposed, under the key terms field: each with how
/// whisper heard it, and Add and Dismiss. Only these buttons add a suggestion; Add is
/// refused, in its row, where add_key_terms would be. Read when Settings opens, every few
/// seconds while it is open, and when the key terms change.
struct SuggestedTermsView: View {
    @Environment(AppModel.self) private var model
    @State private var service: KeyTermSuggestions?
    @State private var suggestions: [TermSuggestion] = []
    @State private var refused: [Int64: String] = [:]
    @State private var busy: Int64?

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
        .task(id: model.preferences.keyTerms) {
            if service == nil {
                let settings = PreferencesKeyTerms(preferences: model.preferences)
                service = await Task.detached(priority: .utility) {
                    (try? CallStore(url: Paths.database)).map { KeyTermSuggestions(store: $0, settings: settings) }
                }.value
            }
            // Corrections land from agents at any time, so the list is read again while it shows.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func row(_ suggestion: TermSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(suggestion.term)
                Text(suggestion.heard.map { "“\($0)”" }.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("How whisper heard it")
                Spacer()
                Button("Add") { decide(suggestion.id, accept: true) }
                Button("Dismiss") { decide(suggestion.id, accept: false) }
            }
            .disabled(busy != nil)
            if let message = refused[suggestion.id] {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func decide(_ id: Int64, accept: Bool) {
        guard let service else { return }
        busy = id
        Task {
            do {
                if accept { try await service.accept(id) } else { try await service.dismiss(id) }
                refused[id] = nil
            } catch {
                refused[id] = "\(error)"
            }
            busy = nil
            await refresh()
        }
    }

    private func refresh() async {
        guard let service, let pending = try? await service.pending() else { return }
        suggestions = pending
        refused = refused.filter { id, _ in pending.contains { $0.id == id } }
    }
}
