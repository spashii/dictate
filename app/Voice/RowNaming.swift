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

    static func item(hasTitle: Bool, canTitle: Bool, busy: Bool, noModelCanRun: Bool, noModelHint: String) -> Item {
        Item(label: hasTitle ? "Regenerate Title" : "Generate Title",
             enabled: canTitle && !busy && !noModelCanRun,
             hint: noModelCanRun ? noModelHint : nil)
    }
}
