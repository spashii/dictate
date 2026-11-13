import VoiceCore

/// Whether a History row says "Naming\u{2026}" in place of its title: a call that has no name
/// yet and whose title is being made. An import being read shows its progress instead.
enum RowNaming {
    static let label = "Naming\u{2026}"

    static func shows(_ entry: HistoryEntry, naming: Set<String>, importState: ImportRowState?) -> Bool {
        guard entry.kind == .call, entry.customTitle == nil, naming.contains(entry.ref) else { return false }
        switch importState {
        case nil, .ready: return true
        case .waiting, .transcribing, .failed: return false
        }
    }
}
