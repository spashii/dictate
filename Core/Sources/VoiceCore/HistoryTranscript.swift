import Foundation

/// Words the retry, a fix or a correction put in a line, found in the line's text so the
/// view can mark them.
public struct TextCorrection: Sendable, Equatable, Identifiable {
    public var source: HistoryChange.Source
    /// Character offsets into the line's `text`.
    public var range: Range<Int>
    /// What the words were, empty when they were added.
    public var before: String
    public var after: String
    /// Whisper's confidence before and after, for a retry.
    public var confidenceBefore: Double?
    public var confidenceAfter: Double?
    public var record: String

    public var id: String { "\(record)@\(range.lowerBound)" }
}

/// One word of a line, as the view lays it out, with the correction that wrote it if any.
public struct LineWord: Sendable, Equatable {
    public var text: String
    public var correction: TextCorrection?
}

extension HistoryLine {
    /// Where the applied changes left words in `text`. A change whose new words can't be found
    /// in the line, because something later rewrote them, marks nothing.
    public var corrections: [TextCorrection] {
        var found: [TextCorrection] = []
        var taken: [Range<Int>] = []
        let characters = Array(text)
        for change in changes where change.applied && change.source != .keyTerm {
            for words in change.diff.changes where !words.after.isEmpty {
                guard let range = Self.find(words.after, in: characters, avoiding: taken) else { continue }
                taken.append(range)
                found.append(TextCorrection(source: change.source, range: range, before: words.before.joined(separator: " "),
                                            after: words.after.joined(separator: " "),
                                            confidenceBefore: change.confidenceBefore,
                                            confidenceAfter: change.confidenceAfter, record: change.record))
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The text split at spaces, each word with its correction.
    public var words: [LineWord] {
        let marks = corrections
        var words: [LineWord] = []
        var start: Int?
        let characters = Array(text)
        func close(at end: Int) {
            guard let from = start else { return }
            let range = from..<end
            words.append(LineWord(text: String(characters[range]),
                                  correction: marks.first { $0.range.lowerBound < range.upperBound && range.lowerBound < $0.range.upperBound }))
            start = nil
        }
        for (index, character) in characters.enumerated() {
            if character.isWhitespace { close(at: index) } else if start == nil { start = index }
        }
        close(at: characters.count)
        return words
    }

    /// The first stretch that holds the words in order, with any punctuation between them,
    /// not overlapping one already marked.
    private static func find(_ words: [String], in text: [Character], avoiding taken: [Range<Int>]) -> Range<Int>? {
        let first = Array(words[0])
        var from = 0
        while let start = index(of: first, in: text, from: from) {
            from = start + 1
            // Whole words only: "pricing" is not found inside "repricing".
            if start > 0, text[start - 1].isLetter || text[start - 1].isNumber { continue }
            var end = start + first.count
            var ok = true
            for word in words.dropFirst() {
                guard let next = index(of: Array(word), in: text, from: end), next - end <= 3 else {
                    ok = false
                    break
                }
                end = next + word.count
            }
            if ok {
                if end < text.count, text[end].isLetter || text[end].isNumber { continue }
                let range = start..<end
                if !taken.contains(where: { $0.lowerBound < range.upperBound && range.lowerBound < $0.upperBound }) {
                    return range
                }
            }
        }
        return nil
    }

    private static func index(of needle: [Character], in text: [Character], from: Int) -> Int? {
        guard !needle.isEmpty, text.count >= needle.count, from <= text.count - needle.count else { return nil }
        for start in from...(text.count - needle.count) where Array(text[start..<start + needle.count]) == needle {
            return start
        }
        return nil
    }
}

/// Lines that read as one stretch: what one side of a call said in a row, or a pair of
/// sentences of a dictation. The lines inside stay separate, each with its own time, so a
/// click can play from any of them.
public struct TranscriptBlock: Sendable, Equatable, Identifiable {
    public var speaker: String?
    public var lines: [HistoryLine]

    public var id: Int { lines[0].id }
    /// Where the block starts, for its time label.
    public var start: Double { lines[0].t0 }
}

public enum TranscriptBlocks {
    /// A dictation's paragraph holds at most this many segments.
    public static let paragraph = 2
    /// A call side's block holds at most this many lines, so a long turn reads in paragraphs
    /// and each has its own time to play from.
    public static let callBlock = 4

    /// A call with its sides apart merges each side's consecutive lines; a dictation, and a
    /// call recorded as one mix, has no sides to merge and is cut into short paragraphs.
    /// Lines with no words are left out.
    public static func make(_ detail: HistoryDetail) -> [TranscriptBlock] {
        let lines = detail.lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var blocks: [TranscriptBlock] = []
        if detail.entry.kind == .call, lines.contains(where: { $0.speaker != nil }) {
            for line in lines {
                if let last = blocks.last, last.speaker == line.speaker, last.lines.count < callBlock {
                    blocks[blocks.count - 1].lines.append(line)
                } else {
                    blocks.append(TranscriptBlock(speaker: line.speaker, lines: [line]))
                }
            }
        } else {
            var index = 0
            while index < lines.count {
                blocks.append(TranscriptBlock(speaker: lines[index].speaker,
                                              lines: Array(lines[index..<min(index + paragraph, lines.count)])))
                index += paragraph
            }
        }
        return blocks
    }
}

extension HistoryDetail {
    /// The line being heard `seconds` into the recording: the last one that has begun and
    /// not yet ended, with a moment either side so the highlight doesn't flicker between
    /// neighbours. Nil in a pause.
    public func line(at seconds: Double, grace: Double = 0.15) -> HistoryLine? {
        lines.last { $0.t0 - grace <= seconds && seconds < $0.t1 + grace && !$0.text.isEmpty }
    }
}

extension TranscriptBlock {
    public var text: String { lines.map(\.text).joined(separator: " ") }

    /// What VoiceOver reads for the block as one element: who spoke (on a call), when, then
    /// the words.
    public func spokenLabel(time: String) -> String {
        [speaker, time].compactMap { $0 }.joined(separator: ", ") + ". " + text
    }

    /// One sentence per change that made the words, for people who can't hover them: what
    /// changed, what it became, and where it came from. A change that wasn't applied says so.
    public var correctionDescriptions: [String] {
        lines.flatMap(\.changes).filter { $0.source != .keyTerm }.map { change in
            let words = (change.diff.changes.isEmpty ? [WordDiff.Change(before: [change.before], after: [change.after])] : change.diff.changes)
                .map { item -> String in
                    let before = item.before.joined(separator: " "), after = item.after.joined(separator: " ")
                    return before.isEmpty ? "added \(after)" : after.isEmpty ? "removed \(before)" : "\(before) became \(after)"
                }
                .joined(separator: ", ")
            let source = change.source == .correction ? "agent correction" : change.source.rawValue
            return "\(source): \(words)\(change.applied ? "" : ", not applied")"
        }
    }
}
