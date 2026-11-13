import VoiceCore

/// Whether a History row says "Generating title\u{2026}" in place of its title: a recording
/// whose title is being made. An import being read shows its progress instead.
enum RowNaming {
    static let label = "Generating title\u{2026}"

    static func shows(_ entry: HistoryEntry, naming: Set<String>, importState: ImportRowState?) -> Bool {
        guard naming.contains(entry.ref) else { return false }
        switch importState {
        case nil, .ready: return true
        case .waiting, .transcribing, .failed: return false
        }
    }
}

/// The row menu's Generate Title and Regenerate Title: what it says and whether it can run.
enum TitleRequest {
    struct Item: Equatable {
        var label: String
        var enabled: Bool
        /// Why no model can run, shown disabled under the item.
        var hint: String?
    }

    /// Only the chosen model is asked, so it is the one that has to be able to run.
    static func item(hasTitle: Bool, canTitle: Bool, busy: Bool, chosen: LocalModel, apple: AppleModelState,
                     ollamaModels: [String]?) -> Item {
        let canRun = LocalModelChoice.canRun(chosen, appleAvailable: apple == .available, ollamaModels: ollamaModels)
        return Item(label: hasTitle ? "Regenerate Title" : "Generate Title",
                    enabled: canTitle && !busy && canRun,
                    hint: canRun ? nil : reason(chosen: chosen, apple: apple, ollamaModels: ollamaModels))
    }

    /// Why the chosen model can't answer: the shared line when neither model could, else the
    /// chosen one's own problem.
    static func reason(chosen: LocalModel, apple: AppleModelState, ollamaModels: [String]?) -> String {
        if LocalModelChoice.noModelCanRun(apple: apple, ollamaModels: ollamaModels) {
            return LocalModelChoice.noModelHint(apple: apple, ollamaModels: ollamaModels)
        }
        switch chosen {
        case .apple:
            switch apple {
            case .turnedOff: return "Turn on Apple Intelligence."
            case .notReady: return "Apple Intelligence is still getting ready."
            default: return "Apple Intelligence is not available on this Mac."
            }
        case .ollama(let name):
            return ollamaModels == nil ? "Start Ollama." : "Add \(name) in Ollama."
        }
    }
}
