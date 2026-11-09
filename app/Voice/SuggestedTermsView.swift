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
        SuggestedTermsList(suggestions: suggestions, refused: refused, busy: busy, decide: decide)
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
