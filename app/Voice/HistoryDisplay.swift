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
    let id: Int
    let generation: Int
    let speaker: String?
    let start: Double
    let clock: String
    let elapsed: String
    let lines: [DisplayLine]
    let plain: AttributedString
    let changes: [HistoryChange]
    let correctionDescriptions: [String]

    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.generation == b.generation }

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

    /// Both times are made here so switching between them is a different string, not a format.
    static func make(_ detail: HistoryDetail, generation: Int) -> [DisplayBlock] {
        let entry = detail.entry
        return TranscriptBlocks.make(detail).map { block in
            let lines = block.lines.map(displayLine)
            var plain = AttributedString()
            for (index, line) in lines.enumerated() {
                if index > 0 { plain.append(AttributedString(" ")) }
                plain.append(line.plain)
            }
            return DisplayBlock(
                id: block.id, generation: generation, speaker: block.speaker, start: block.start,
                clock: HistoryTime.line(start: entry.at, offset: block.start, zone: entry.timeZone, mode: .clock),
                elapsed: HistoryTime.line(start: entry.at, offset: block.start, zone: entry.timeZone, mode: .elapsed),
                lines: lines, plain: plain, changes: block.lines.flatMap(\.changes),
                correctionDescriptions: block.correctionDescriptions)
        }
    }

    private static func displayLine(_ line: HistoryLine) -> DisplayLine {
        var plain = AttributedString()
        for (index, word) in line.words.enumerated() {
            if index > 0 { plain.append(AttributedString(" ")) }
            var run = AttributedString(word.text)
            if word.correction != nil { run.swiftUI.underlineStyle = Text.LineStyle(pattern: .dot) }
            plain.append(run)
        }
        var heard = plain
        heard.swiftUI.backgroundColor = Color.accentColor.opacity(0.16)
        return DisplayLine(id: line.id, plain: plain, heard: heard)
    }
}
