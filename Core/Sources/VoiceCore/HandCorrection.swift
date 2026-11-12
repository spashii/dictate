import Foundation

extension Edit {
    /// The client name of a correction a person makes in History, as list_edits and the
    /// Before / After popover show it.
    public static let personClient = "You"
}

/// Words a person selected in a History transcript, and where they sit, so the correction
/// can be stored through the same path the MCP tools use. A call is corrected one segment at
/// a time and a dictation as a whole, so the words are found again in the stored text by
/// counting identical stretches rather than by offsets, which a whitespace difference between
/// what History draws and what is stored would shift.
public struct HandCorrection: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case dictation(String)
        case segment(call: String, id: Int64)
    }

    public var target: Target
    public var selected: String
    /// How many stretches reading the same as `selected` come before it in the target's text.
    public var occurrence: Int

    /// Where `needle` reads in `text`, not overlapping, in order.
    static func matches(of needle: String, in text: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, let range = text.range(of: needle, options: .literal, range: from..<text.endIndex) {
            found.append(range)
            from = range.upperBound
        }
        return found
    }
}

extension HistoryLine {
    /// The line as History draws it: its words with one space between.
    public var shown: String { words.map(\.text).joined(separator: " ") }
}

extension HistoryDetail {
    /// The correction for `selected`, which starts `offset` UTF-16 units into the shown text
    /// of line `id`. Nil when the line isn't in this recording or the offset doesn't hold the words.
    public func correction(line id: Int, selecting selected: String, at offset: Int) -> HandCorrection? {
        guard let index = lines.firstIndex(where: { $0.id == id }), !selected.isEmpty else { return nil }
        let shown = lines[index].shown
        guard offset >= 0, offset + selected.utf16.count <= shown.utf16.count else { return nil }
        let start = String.Index(utf16Offset: offset, in: shown)
        guard shown[start...].hasPrefix(selected) else { return nil }
        switch entry.kind {
        case .call:
            let before = HandCorrection.matches(of: selected, in: shown).filter { $0.lowerBound < start }.count
            return HandCorrection(target: .segment(call: entry.ref, id: Int64(id)), selected: selected, occurrence: before)
        case .dictation:
            // One text for the whole dictation: the lines before this one come first.
            let text = lines.map(\.shown).joined(separator: " ")
            let lead = lines[..<index].reduce(0) { $0 + $1.shown.utf16.count + 1 }
            let at = String.Index(utf16Offset: lead + offset, in: text)
            let before = HandCorrection.matches(of: selected, in: text).filter { $0.lowerBound < at }.count
            return HandCorrection(target: .dictation(entry.ref), selected: selected, occurrence: before)
        }
    }
}

extension CallStore {
    /// Replaces the selected words with `replacement`, stores the result as a correction by
    /// the person, and proposes key terms from it as an agent's correction would. Nil when
    /// nothing changed.
    @discardableResult
    public func correct(_ request: HandCorrection, to replacement: String, known: [String]) throws -> Edit? {
        let text: String
        switch request.target {
        case .dictation(let id):
            guard let dictation = try dictation(id) else { throw VoiceError.store("No dictation \(id).") }
            text = dictation.finalText
        case .segment(let call, let id):
            guard let segment = try segment(call, id) else { throw VoiceError.store("No segment \(id) in call \(call).") }
            text = segment.text
        }
        let words = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words != request.selected else { return nil }
        let found = HandCorrection.matches(of: request.selected, in: text)
        guard found.indices.contains(request.occurrence) else {
            throw VoiceError.store("Those words are no longer in the saved text.")
        }
        var range = found[request.occurrence]
        // Deleting a word takes the space after it, so no double space is left.
        if words.isEmpty, range.upperBound < text.endIndex, text[range.upperBound] == " " {
            range = range.lowerBound..<text.index(after: range.upperBound)
        }
        var corrected = text
        corrected.replaceSubrange(range, with: words)
        guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceError.store("A correction can't leave the text empty.")
        }
        let edit: Edit
        switch request.target {
        case .dictation(let id):
            edit = try correctDictation(id, text: corrected, client: Edit.personClient).1
        case .segment(let call, let id):
            edit = try correctSegment(call, id, text: corrected, client: Edit.personClient).1
        }
        _ = try? suggestKeyTerms(from: edit, known: known)
        return edit
    }
}
