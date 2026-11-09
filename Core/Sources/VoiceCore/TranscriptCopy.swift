import AppKit

/// What every Copy in the app puts on the clipboard: the History window's buttons, the menu's
/// Recent rows and the pill after a call. One function, so they never disagree on the text.
public enum TranscriptCopy {
    public enum Item: Sendable {
        /// A call by its id, read when copied, so a correction made since the row was drawn
        /// is in it.
        case call(String)
        /// A dictation as a store read it.
        case dictation(Dictation)
    }

    /// The text to copy, or nil when there is none. A call is both sides merged by time with
    /// Me and Call labels (or its speakers' names), as get_transcript gives it, less segments
    /// with no words; a dictation is its final text. An agent's correction stands in for
    /// whisper's text in both, since the stores read the corrected text first.
    public static func text(_ item: Item, in store: CallStore?) -> String? {
        switch item {
        case .call(let id):
            guard let store, let segments = try? store.segments(id).filter({ !blank($0.text) }),
                  !segments.isEmpty else { return nil }
            return CallTranscript.text(segments, speakers: (try? store.call(id))?.speakers)
        case .dictation(let dictation):
            return blank(dictation.finalText) ? nil : dictation.finalText
        }
    }

    /// Puts the item's text on the pasteboard and says whether it did. With nothing to copy
    /// the pasteboard keeps what it held, and the caller shows no "Copied".
    @discardableResult
    public static func copy(_ item: Item, in store: CallStore?, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let text = text(item, in: store) else { return false }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    private static func blank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
