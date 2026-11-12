import Foundation
import Testing
@testable import VoiceCore

private func line(_ id: Int, _ speaker: String?, _ t0: Double, _ text: String, changes: [HistoryChange] = []) -> HistoryLine {
    HistoryLine(id: id, speaker: speaker, t0: t0, t1: t0 + 2, whisper: text, text: text, flagged: false, changes: changes)
}

private func entry(_ kind: HistoryEntry.Kind) -> HistoryEntry {
    HistoryEntry(kind: kind, ref: "r", at: Date(timeIntervalSince1970: 1_794_514_804), duration: 60, title: "t", changes: 0)
}

@Suite struct TranscriptBlocksTests {
    @Test func aCallMergesEachSidesConsecutiveLines() {
        let detail = HistoryDetail(entry: entry(.call), audioPath: nil, lines: [
            line(1, "Me", 0, "Thanks for joining, Alex."), line(2, "Me", 2, "Let's start."),
            line(3, "Call", 4, "Sure."), line(4, "Call", 5, "The budget is open."), line(5, "Call", 7, "And the quote."),
            line(6, "Me", 9, "Okay."),
        ], textChanges: [])
        let blocks = TranscriptBlocks.make(detail)
        #expect(blocks.map(\.speaker) == ["Me", "Call", "Me"])
        #expect(blocks.map(\.start) == [0, 4, 9])
        // Still separate underneath, each with its own time.
        #expect(blocks[1].lines.map(\.t0) == [4, 5, 7])
    }

    @Test func aDictationReadsInParagraphsOfTwoSegments() {
        let lines = (0..<5).map { line($0, nil, Double($0) * 2, "Sentence \($0).") }
        let blocks = TranscriptBlocks.make(HistoryDetail(entry: entry(.dictation), audioPath: nil, lines: lines,
                                                         textChanges: []))
        #expect(blocks.map { $0.lines.count } == [2, 2, 1])
        #expect(blocks.allSatisfy { $0.speaker == nil })
    }

    @Test func aMixedCallIsCutLikeADictation() {
        let lines = (0..<3).map { line($0, nil, Double($0), "Line \($0).") }
        let blocks = TranscriptBlocks.make(HistoryDetail(entry: entry(.call), audioPath: nil, lines: lines, textChanges: []))
        #expect(blocks.map { $0.lines.count } == [2, 1])
    }

    @Test func linesWithNoWordsAreLeftOut() {
        let detail = HistoryDetail(entry: entry(.call), audioPath: nil, lines: [
            line(1, "Me", 0, "Hello."), line(2, "Me", 1, "  "), line(3, "Me", 2, "Again."),
        ], textChanges: [])
        #expect(TranscriptBlocks.make(detail).map { $0.lines.map(\.id) } == [[1, 3]])
    }

    @Test func theLineBeingHeardFollowsThePlayhead() {
        let detail = HistoryDetail(entry: entry(.call), audioPath: nil, lines: [
            line(1, "Me", 0, "One."), line(2, "Call", 5, "Two."),
        ], textChanges: [])
        #expect(detail.line(at: 1)?.id == 1)
        #expect(detail.line(at: 5.1)?.id == 2)
        #expect(detail.line(at: 3.5) == nil)
        #expect(detail.line(at: 4.9)?.id == 2, "the grace before a line starts")
    }
}

@Suite struct CorrectionMarkTests {
    private func change(_ source: HistoryChange.Source, _ before: String, _ after: String, applied: Bool = true) -> HistoryChange {
        HistoryChange(source, before: before, after: after, applied: applied, record: "\(source.rawValue):1",
                      confidenceBefore: 0.41, confidenceAfter: 0.88)
    }

    @Test func markTheWordsAChangeWrote() throws {
        let text = "And the pricing update, does it ship?"
        let marked = line(1, "Me", 0, text, changes: [change(.retry, "And the pricing a date, does it ship?", text)])
        let mark = try #require(marked.corrections.first)
        #expect(marked.corrections.count == 1)
        #expect(String(Array(text)[mark.range]) == "update")
        #expect(mark.before == "a date")
        #expect(mark.after == "update")
        #expect(mark.source == .retry)
        #expect(mark.confidenceBefore == 0.41 && mark.confidenceAfter == 0.88)
    }

    @Test func wordsCarryTheirMarks() {
        let text = "Open the Orbit board."
        let marked = line(1, "Me", 0, text, changes: [change(.fix, "Open the orbit board.", text)])
        let words = marked.words
        #expect(words.map(\.text) == ["Open", "the", "Orbit", "board."])
        #expect(words.map { $0.correction != nil } == [false, false, true, false])
        #expect(words[2].correction?.source == .fix)
    }

    @Test func aRejectedChangeAndAKeyTermMarkNothing() {
        let text = "Ask Claude."
        let marked = line(1, "Me", 0, text, changes: [
            change(.fix, "Ask Claud.", text, applied: false),
            HistoryChange(.keyTerm, before: "cloud", after: "Claude", note: "added", record: "k:1"),
        ])
        #expect(marked.corrections.isEmpty)
    }

    @Test func wholeWordsOnlyAndTheFirstStretchNotAlreadyMarked() {
        let text = "repricing the pricing and the pricing"
        let marked = line(1, "Me", 0, text, changes: [
            change(.retry, "repricing the prising and the pricing", text),
            change(.fix, "the prising", "the pricing"),
        ])
        let ranges = marked.corrections.map { String(Array(text)[$0.range]) }
        #expect(ranges == ["pricing", "pricing"])
        #expect(marked.corrections[0].range.lowerBound == 14)
    }

    @Test func aChangeThatLaterTextRewroteMarksNothing() {
        let marked = line(1, "Me", 0, "Something else entirely.", changes: [change(.retry, "a b", "pricing update")])
        #expect(marked.corrections.isEmpty)
    }
}

@Suite struct HistoryRowTests {
    @Test func theTitleIsTheClockItWasMadeOn() {
        let start = Date(timeIntervalSince1970: 1_794_514_804) // 2026-11-12 20:20:04 UTC
        let us = Locale(identifier: "en_US_POSIX")
        #expect(HistoryTime.title(start: start, zone: "Europe/Amsterdam", locale: us) == "Thu 12 Nov, 21:20")
        #expect(HistoryTime.title(start: start, zone: "Asia/Kolkata", locale: us) == "Fri 13 Nov, 01:50")
        #expect(HistoryTime.title(start: start, zone: nil, current: TimeZone(identifier: "UTC")!, locale: us)
                == "Thu 12 Nov, 20:20")
    }
}

@Suite struct HistoryTextTests {
    @Test func aCallLineReadsAsCorrectedAndTheListShowsTheFirstWords() throws {
        let url = temporaryCallDatabase()
        let calls = try CallStore(url: url)
        let call = try calls.createCall(NewCall(split: true))
        let made = try calls.appendSegments(call.id, [sampleSegment(.call, 3000, "Then the budget."),
                                                      sampleSegment(.me, 0, "Thanks for joining, Alex.")])
        _ = try calls.correctSegment(call.id, made[0].id, text: "Then the Northwind budget.", client: "agent")
        try calls.finishCall(call.id)

        let entries = try calls.historyEntries()
        #expect(entries.first?.firstLine == "Thanks for joining, Alex.")
        let first = try #require(entries.first)
        let read = try calls.historyDetail(first)
        let detail = try #require(read)
        #expect(detail.lines.map(\.text) == ["Thanks for joining, Alex.", "Then the Northwind budget."])
        #expect(detail.lines[1].whisper == "Then the budget.")
        let marks = detail.lines[1].corrections
        #expect(marks.map(\.after) == ["Northwind"])
        #expect(marks.first?.source == .correction)
    }

    @Test func searchFindsDictationsAndCallsByTheirWords() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        var spoken = sampleDictation("book the room for the design review")
        spoken.duration = 3
        try store.insert(spoken)
        let call = try calls.createCall(NewCall(split: true))
        try calls.appendSegments(call.id, [sampleSegment(.me, 0, "the pricing update ships Thursday")])
        try calls.finishCall(call.id)

        #expect(try calls.historyEntries(matching: "DESIGN").map(\.ref) == [spoken.id])
        #expect(try calls.historyEntries(matching: "pricing").map(\.ref) == [call.id])
        #expect(try calls.historyEntries(matching: "  ").count == 2)
        #expect(try calls.historyEntries(matching: "100%").isEmpty)
    }
}

@Suite struct BlockAccessibilityTests {
    private func change(_ source: HistoryChange.Source, _ before: String, _ after: String, applied: Bool = true) -> HistoryChange {
        HistoryChange(source, before: before, after: after, applied: applied, record: "r:1")
    }

    @Test func aBlockReadsAsSpeakerTimeAndText() {
        let block = TranscriptBlock(speaker: "Me", lines: [line(1, "Me", 0, "Thanks, Alex."), line(2, "Me", 2, "Let's start.")])
        #expect(block.spokenLabel(time: "9:41") == "Me, 9:41. Thanks, Alex. Let's start.")
        let dictation = TranscriptBlock(speaker: nil, lines: [line(1, nil, 0, "Hello.")])
        #expect(dictation.spokenLabel(time: "0:00") == "0:00. Hello.")
    }

    @Test func correctionsAreSpelledOutWithoutHovering() {
        let block = TranscriptBlock(speaker: nil, lines: [
            line(1, nil, 0, "the northwind pilot", changes: [change(.retry, "northwynd", "northwind"),
                                                              change(.fix, "x", "y", applied: false)]),
        ])
        #expect(block.correctionDescriptions == ["retry: northwynd became northwind", "fix: x became y, not applied"])
    }
}
