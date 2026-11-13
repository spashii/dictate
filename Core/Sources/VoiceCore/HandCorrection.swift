import Foundation

extension Edit {
    /// The client name of a correction a person makes in History, as list_edits and the
    /// Before / After popover show it.
    public static let personClient = "You"
}

/// Words a person selected in a History transcript, and where they sit. A call is corrected
/// one segment at a time and a dictation as a whole. The place is a character offset into the
/// target's text with its whitespace made single, which is how History draws it, so the same
/// words earlier or later in the text are never mistaken for the selection.
public struct HandCorrection: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case dictation(String)
        case segment(call: String, id: Int64)
    }

    public var target: Target
    public var selected: String
    /// In characters, into the target's text as `normalized` makes it.
    public var offset: Int

    /// The text as History draws it: words with one space between, nothing at the ends.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Where each character of `normalized(text)` came from in `text`.
    static func sourceIndices(_ text: String) -> [String.Index] {
        var found: [String.Index] = []
        var spaced = true
        for index in text.indices {
            if text[index].isWhitespace {
                if !spaced { found.append(index) }
                spaced = true
            } else {
                found.append(index)
                spaced = false
            }
        }
        // A space at the end belongs to no word.
        if spaced, !found.isEmpty, let last = found.last, text[last].isWhitespace { found.removeLast() }
        return found
    }
}

extension HistoryLine {
    /// The line as History draws it: its words with one space between.
    public var shown: String { HandCorrection.normalized(text) }
}

extension HistoryDetail {
    /// Whether what History draws is the text a correction would change. A dictation whose
    /// text the clean-up step rewrote shows whisper's segments and stores the rewrite.
    public var canCorrect: Bool {
        guard entry.kind == .dictation, let stored = storedText else { return true }
        return HandCorrection.normalized(stored) == lines.map(\.shown).joined(separator: " ")
    }

    /// The correction for `selected`, which starts `offset` characters into the shown text
    /// of line `id`. Nil when the line isn't in this recording, the recording can't be
    /// corrected, or the offset doesn't hold the words.
    public func correction(line id: Int, selecting selected: String, at offset: Int) -> HandCorrection? {
        guard canCorrect, let index = lines.firstIndex(where: { $0.id == id }), !selected.isEmpty else { return nil }
        let shown = Array(lines[index].shown)
        guard offset >= 0, offset + selected.count <= shown.count,
              String(shown[offset..<offset + selected.count]) == selected else { return nil }
        switch entry.kind {
        case .call:
            return HandCorrection(target: .segment(call: entry.ref, id: Int64(id)), selected: selected, offset: offset)
        case .dictation:
            // One text for the whole dictation: the lines before this one come first.
            let lead = lines[..<index].reduce(0) { $0 + $1.shown.count + 1 }
            return HandCorrection(target: .dictation(entry.ref), selected: selected, offset: lead + offset)
        }
    }
}

extension CallStore {
    /// Replaces the selected words with `replacement`, stores the result as a correction by
    /// the person, and, with `suggest`, proposes key terms from it as an agent's correction
    /// would. Nil when nothing changed. History adds the terms itself through
    /// `KeyTermSuggestions.correct`, so it passes false.
    @discardableResult
    public func correct(_ request: HandCorrection, to replacement: String, known: [String],
                        suggest: Bool = true) throws -> Edit? {
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
        let normalized = Array(HandCorrection.normalized(text))
        let sources = HandCorrection.sourceIndices(text)
        let end = request.offset + request.selected.count
        guard request.offset >= 0, end <= normalized.count, normalized.count == sources.count,
              String(normalized[request.offset..<end]) == request.selected else {
            throw VoiceError.store("Those words are no longer in the saved text.")
        }
        var range = sources[request.offset]..<text.index(after: sources[end - 1])
        // Deleting a word takes the space after it, so no double space is left.
        if words.isEmpty, range.upperBound < text.endIndex, text[range.upperBound].isWhitespace {
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
        if suggest { _ = try? suggestKeyTerms(from: edit, known: known) }
        return edit
    }
}
