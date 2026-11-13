import AppKit
import SwiftUI
import VoiceCore

/// A transcript line as it is drawn: its words with the corrected ones dotted, and the same
/// with the highlight of the line being heard. Both are made once, when a recording opens.
struct DisplayLine: Sendable {
    let id: Int
    let plain: AttributedString
    let heard: AttributedString
}

/// One block of the transcript with everything a row needs, so scrolling does no formatting,
/// splitting or diffing. Immutable once made; `generation` tells a block from a reload of the
/// same recording apart, so a row redraws only when what it shows changed.
struct DisplayBlock: Identifiable, Equatable, Sendable {
    /// A corrected stretch of the block's text, in UTF-16 offsets as TextKit counts them.
    struct Mark: Equatable, Sendable {
        let range: Range<Int>
        let correction: TextCorrection
    }

    /// Where a line starts in the block's text and in the recording.
    struct Span: Sendable {
        let id: Int
        let start: Int
        let t0: Double
    }

    let id: Int
    let generation: Int
    let speaker: String?
    /// False when the block before is the same speaker's.
    let showsSpeaker: Bool
    /// The text as the row draws it, for finding the word under the pointer.
    let string: String
    let marks: [Mark]
    let spans: [Span]
    let start: Double
    let clock: String
    let elapsed: String
    let lines: [DisplayLine]
    let plain: AttributedString
    let changes: [HistoryChange]
    let correctionDescriptions: [String]

    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.generation == b.generation }

    /// Whether the block reads and marks the same as `other`, whatever the generation.
    func sameContent(as other: Self) -> Bool {
        id == other.id && speaker == other.speaker && showsSpeaker == other.showsSpeaker && string == other.string
            && marks == other.marks && start == other.start && clock == other.clock && elapsed == other.elapsed
            && spans.map(\.id) == other.spans.map(\.id) && spans.map(\.start) == other.spans.map(\.start)
            && changes == other.changes && correctionDescriptions == other.correctionDescriptions
    }

    /// `fresh` with the generation of the block `old` already shows wherever the content is the
    /// same, so a reload redraws only what changed and keeps selection and an open popover.
    static func keeping(_ old: [DisplayBlock], in fresh: [DisplayBlock]) -> [DisplayBlock] {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return fresh.map { block in
            guard let kept = before[block.id], kept.sameContent(as: block) else { return block }
            return kept
        }
    }

    func contains(line: Int) -> Bool { lines.contains { $0.id == line } }

    /// The block's text with `line`, when it is one of its lines, highlighted.
    func text(heard line: Int?) -> AttributedString {
        guard let line, contains(line: line) else { return plain }
        var text = AttributedString()
        for (index, shown) in lines.enumerated() {
            if index > 0 { text.append(AttributedString(" ")) }
            text.append(shown.id == line ? shown.heard : shown.plain)
        }
        return text
    }

    /// What VoiceOver reads: who spoke, when, then the words.
    func spokenLabel(_ mode: HistoryTimeMode) -> String {
        [speaker, mode == .clock ? clock : elapsed].compactMap { $0 }.joined(separator: ", ") + ". "
            + lines.map { String($0.plain.characters) }.joined(separator: " ")
    }

    /// The words around `offset` without the punctuation at their ends, so "Acme," selects Acme.
    func word(at offset: Int) -> Range<Int>? {
        let text = string as NSString
        guard offset >= 0, offset < text.length else { return nil }
        func isSpace(_ index: Int) -> Bool {
            Unicode.Scalar(text.character(at: index)).map(CharacterSet.whitespacesAndNewlines.contains) ?? false
        }
        func isWord(_ index: Int) -> Bool {
            Unicode.Scalar(text.character(at: index)).map(CharacterSet.alphanumerics.contains) ?? true
        }
        guard !isSpace(offset) else { return nil }
        var lower = offset, upper = offset + 1
        while lower > 0, !isSpace(lower - 1) { lower -= 1 }
        while upper < text.length, !isSpace(upper) { upper += 1 }
        while lower < upper, !isWord(lower) { lower += 1 }
        while upper > lower, !isWord(upper - 1) { upper -= 1 }
        return lower < upper ? lower..<upper : nil
    }

    /// The whole words a drag from `a` to `b` covers.
    func phrase(from a: Int, to b: Int) -> Range<Int>? {
        let (low, high) = (min(a, b), max(a, b))
        guard let first = word(at: low) ?? word(at: low + 1), let last = word(at: high) ?? word(at: max(high - 1, 0)),
              first.lowerBound < last.upperBound else { return nil }
        return first.lowerBound..<last.upperBound
    }

    /// The line `offset` falls in: where it starts and ends in the block's text.
    func lineRange(at offset: Int) -> (id: Int, range: Range<Int>)? {
        guard let index = spans.lastIndex(where: { $0.start <= offset }) ?? spans.indices.first else { return nil }
        let end = index + 1 < spans.count ? spans[index + 1].start - 1 : string.utf16.count
        return (spans[index].id, spans[index].start..<end)
    }

    /// The time to play from for a click at `offset` into the text: the line it is in.
    func start(at offset: Int) -> Double {
        spans.last { $0.start <= offset }?.t0 ?? start
    }

    /// Both times are made here so switching between them is a different string, not a format.
    static func make(_ detail: HistoryDetail, generation: Int) -> [DisplayBlock] {
        let entry = detail.entry
        return TranscriptBlocks.make(detail).map { block in
            var plain = AttributedString()
            var lines: [DisplayLine] = []
            var spans: [Span] = []
            var marks: [Mark] = []
            var string = ""
            var offset = 0
            for (lineIndex, line) in block.lines.enumerated() {
                if lineIndex > 0 {
                    plain.append(AttributedString(" "))
                    string += " "
                    offset += 1
                }
                spans.append(Span(id: line.id, start: offset, t0: line.t0))
                var shown = AttributedString()
                for (index, word) in line.words.enumerated() {
                    if index > 0 {
                        shown.append(AttributedString(" "))
                        string += " "
                        offset += 1
                    }
                    var run = AttributedString(word.text)
                    if let correction = word.correction {
                        run.swiftUI.underlineStyle = Text.LineStyle(pattern: .dot)
                        let range = offset..<offset + word.text.utf16.count
                        // A correction that spans words is one mark.
                        if let last = marks.last, last.correction.id == correction.id, last.range.upperBound + 1 == range.lowerBound {
                            marks[marks.count - 1] = Mark(range: last.range.lowerBound..<range.upperBound, correction: correction)
                        } else {
                            marks.append(Mark(range: range, correction: correction))
                        }
                    }
                    shown.append(run)
                    string += word.text
                    offset += word.text.utf16.count
                }
                var heard = shown
                heard.swiftUI.backgroundColor = Color.accentColor.opacity(0.16)
                lines.append(DisplayLine(id: line.id, plain: shown, heard: heard))
                plain.append(shown)
            }
            return DisplayBlock(
                id: block.id, generation: generation, speaker: block.speaker, showsSpeaker: !block.continuesTurn,
                string: string, marks: marks, spans: spans, start: block.start,
                clock: HistoryTime.line(start: entry.at, offset: block.start, zone: entry.timeZone, mode: .clock),
                elapsed: HistoryTime.line(start: entry.at, offset: block.start, zone: entry.timeZone, mode: .elapsed),
                lines: lines, plain: plain, changes: block.lines.flatMap(\.changes),
                correctionDescriptions: block.correctionDescriptions)
        }
    }
}

/// Finds the word under a point in a block's text by laying the same string out with TextKit
/// at the width the row gave it. Made on the first hover or click in a block, so scrolling
/// never pays for it, and one text per block keeps its single layout.
@MainActor
final class BlockTextLayout {
    let width: CGFloat
    let string: String
    private let storage: NSTextStorage
    private let manager = NSLayoutManager()
    private let container: NSTextContainer

    init(string: String, width: CGFloat) {
        self.width = width
        self.string = string
        // SwiftUI's default text on the Mac is the system font at its standard size.
        storage = NSTextStorage(string: string, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
    }

    /// The character offset under `point`. With `nearest`, the closest one when the point
    /// is beside the text rather than on it.
    func offset(at point: CGPoint, nearest: Bool) -> Int? {
        guard storage.length > 0 else { return nil }
        let glyph = manager.glyphIndex(for: point, in: container)
        if !nearest {
            let box = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            guard box.contains(point) else { return nil }
        }
        return manager.characterIndexForGlyph(at: glyph)
    }

    func rect(of range: Range<Int>) -> CGRect {
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: range.lowerBound, length: range.count),
                                        actualCharacterRange: nil)
        return manager.boundingRect(forGlyphRange: glyphs, in: container)
    }
}
