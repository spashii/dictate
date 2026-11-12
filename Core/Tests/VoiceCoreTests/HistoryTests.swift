import SQLite3
import XCTest
@testable import VoiceCore

/// The History window shows every change that was made to a transcript. These fixtures hold
/// each kind the store keeps (a retry that changed words, applied and rejected fix edits,
/// corrections and their undo, on dictations and on a call), and the test reads every such
/// row straight from the tables and looks for it in the view model.
final class HistoryTests: StoreTestCase {
    private func seg(_ text: String, t0: Double, t1: Double, logprob: Double = -0.1,
                     retry: SegmentRetry.Record? = nil) -> Segment {
        var s = Segment(t0: t0, t1: t1, text: text, avgLogprob: logprob, noSpeechProb: 0, compressionRatio: 1,
                        speechSeconds: t1 - t0, wordsPerSecond: 2)
        s.retry = retry ?? .init(firstText: text, firstLogprob: logprob, flagged: logprob < -0.6)
        return s
    }

    /// Two fixed dictations, a plain one, and a split call, with corrections over MCP.
    private func fixtures() throws -> CallStore {
        // A retry kept a second text, a flagged segment was left alone, and the fix made one
        // edit and had two rejected.
        var fixed = try dictation("fixed", mode: .fix, segments: [
            seg("the northwind pilot", t0: 0, t1: 2, logprob: -0.3,
                retry: .init(firstText: "the northwynd pilot", firstLogprob: -0.9, flagged: true,
                             retriedText: "the northwind pilot", retriedLogprob: -0.3, seconds: 0.2, kept: true,
                             changed: true)),
            seg("ask Claud about it", t0: 2, t1: 4, logprob: -0.8),
            seg("then we ship", t0: 4, t1: 5, logprob: -0.7),
        ])
        fixed.fixEdits = [
            FixEdit(segment: 1, span: "Claud", replacement: "Claude", keyTerm: "Claude", offset: 4),
            FixEdit(segment: 2, span: "we", replacement: "we will all", rejected: .addsWords),
            FixEdit(segment: 0, span: "x", replacement: "y", rejected: .notFlagged),
        ]
        fixed.finalText = "the northwind pilot ask Claude about it then we ship"
        try store.insert(fixed)
        var second = try dictation("second", mode: .fix, segments: [seg("send it to codex", t0: 0, t1: 2, logprob: -0.7)])
        second.fixEdits = [FixEdit(segment: 0, span: "codex", replacement: "Codex", keyTerm: "Codex", offset: 11)]
        second.finalText = "send it to Codex"
        try store.insert(second)
        try store.insert(try dictation("plain", segments: [seg("nothing to see", t0: 0, t1: 1)]))

        let calls = try CallStore(url: databaseURL)
        try calls.correctDictation("fixed", text: "The Northwind pilot: ask Claude about it.", client: "agent 1")
        let wrong = try calls.correctDictation("second", text: "send it to Kodex", client: "agent 1").1
        // The correction suggests Kodex as a key term; Settings dismisses it before the undo.
        let kodex = try XCTUnwrap(try calls.suggestKeyTerms(from: wrong, known: []).first)
        try calls.dismissTermSuggestion(kodex.id, client: KeyTermSuggestions.settingsClient)
        try calls.undo(wrong.id, client: "agent 1")

        try calls.createCall(NewCall(id: "call", appName: "Zoom", split: true, audioPath: dir.appending(path: "call.m4a").path))
        let lines = try calls.appendSegments("call", [
            NewCallSegment(channel: .me, startMs: 0, endMs: 2000, text: "we use blend", avgLogprob: -0.4,
                           retry: .init(firstText: "we use bland", firstLogprob: -0.8, flagged: true,
                                        retriedText: "we use blend", retriedLogprob: -0.4, kept: true, changed: true)),
            NewCallSegment(channel: .call, startMs: 1500, endMs: 3000, text: "sounds good", avgLogprob: -0.1,
                           retry: .init(firstText: "sounds good", firstLogprob: -0.1, flagged: false)),
            NewCallSegment(channel: .call, startMs: 3000, endMs: 4500, text: "ask the northwynd team", avgLogprob: -0.2,
                           retry: .init(firstText: "ask the northwynd team", firstLogprob: -0.2, flagged: false)),
        ])
        try calls.correctSegment("call", lines[0].id, text: "we use Blend", client: "agent 2")
        // Added from Settings: an add_key_terms edit decides the suggestion.
        let northwind = try calls.correctSegment("call", lines[2].id, text: "ask the Northwind team", client: "agent 2").1
        let suggested = try XCTUnwrap(try calls.suggestKeyTerms(from: northwind, known: []).first)
        let add = try calls.recordEdit(.addKeyTerms, target: Edit.keyTermsTarget, client: KeyTermSuggestions.settingsClient,
                                       before: Edit.Value(terms: []), after: Edit.Value(terms: ["Northwind"]))
        try calls.acceptTermSuggestion(suggested.id, edit: add.id)
        return calls
    }

    /// Every stored change, as the `table:id` HistoryChange.record names.
    private func storedChanges() -> Set<String> {
        var db: OpaquePointer?
        sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        var found: Set<String> = []
        for (table, sql) in [
            ("segment_retries", "SELECT id FROM segment_retries WHERE kept = 1 AND changed = 1"),
            ("fix_edits", "SELECT id FROM fix_edits"),
            // Transcript edits only: an undo counts when it reverted a transcript's correction.
            ("edits", """
                SELECT id FROM edits WHERE kind IN ('correct_dictation', 'correct_segment')
                  OR (kind = 'undo' AND (target LIKE 'dictation:%' OR target LIKE 'call:%'))
                """),
        ] {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            while sqlite3_step(statement) == SQLITE_ROW { found.insert("\(table):\(sqlite3_column_int64(statement, 0))") }
            sqlite3_finalize(statement)
        }
        return found
    }

    func testEveryStoredChangeAppearsInTheHistory() throws {
        let calls = try fixtures()
        let entries = try calls.historyEntries()
        let all = try entries.compactMap { try calls.historyDetail($0) }.flatMap(\.allChanges)
        let shown = all.filter { $0.source != .keyTerm }
        let stored = storedChanges()

        XCTAssertEqual(stored.count, 11, "2 retries, 4 fix edits, 4 corrections and an undo")
        XCTAssertEqual(Set(shown.map(\.record)), stored)
        XCTAssertEqual(shown.count, stored.count, "each change once")
        XCTAssertEqual(Set(entries.map(\.id)), ["dictation:fixed", "dictation:second", "dictation:plain", "call:call"])
        XCTAssertEqual(entries.first { $0.ref == "fixed" }?.changes, 5)
        XCTAssertEqual(entries.first { $0.ref == "call" }?.changes, 3)
    }

    func testSearchFindsRecordingsThroughTheTranscriptIndex() throws {
        let calls = try fixtures()
        func found(_ query: String) throws -> Set<String> { Set(try calls.historyEntries(matching: query).map(\.id)) }

        XCTAssertEqual(try found("sounds good"), ["call:call"], "a call by what was said in it")
        XCTAssertTrue(try found("northwi").contains("dictation:fixed"), "the start of a word still being typed")
        XCTAssertEqual(try found("codex"), ["dictation:second"])
        XCTAssertEqual(try found("pilot northwind"), ["dictation:fixed"], "every word has to appear")
        XCTAssertEqual(try found("zzz"), [])
        XCTAssertEqual(try found("  ").count, 4, "blank shows everything")
    }

    func testHalfTypedAndMidWordFragmentsStillFindTheRecording() throws {
        try store.insert(try dictation("pricing", text: "the pricing update ships Friday",
                                        segments: [seg("the pricing update ships Friday", t0: 0, t1: 2)]))
        let calls = try CallStore(url: databaseURL)
        func found(_ query: String) throws -> Set<String> { Set(try calls.historyEntries(matching: query).map(\.id)) }

        // The index stems whole words, so "prici" is in no token; the text match finds it.
        XCTAssertEqual(try found("prici"), ["dictation:pricing"])
        XCTAssertEqual(try found("ricing upd"), ["dictation:pricing"], "from the middle of a word")
        XCTAssertEqual(try found("pricing update"), ["dictation:pricing"])
    }

    func testKeyTermDecisionsShowAsKeyTermEventsNotTranscriptEdits() throws {
        let calls = try fixtures()
        let all = try calls.historyEntries().compactMap { try calls.historyDetail($0) }.flatMap(\.allChanges)
        let decisions = Set(try calls.edits(limit: 100).filter { [.addKeyTerms, .dismissKeyTerm].contains($0.kind) }
            .map { "edits:\($0.id)" })

        let events = all.filter { $0.source == .keyTerm }
        XCTAssertEqual(decisions.count, 2)
        XCTAssertEqual(Set(events.map(\.record)), decisions)
        XCTAssertEqual(Set(events.map { "\($0.before) \($0.after) \($0.note ?? "")" }),
                       ["Codex Kodex dismissed", "northwynd Northwind added"])
        XCTAssertTrue(all.filter { $0.source != .keyTerm }.allSatisfy { !decisions.contains($0.record) })
    }

    /// A correction replaces the whole text, so the detail shows it like the list and Copy do,
    /// as one block that keeps the retry and fix changes of the segments it replaced.
    func testACorrectedDictationShowsTheCorrectedText() throws {
        let calls = try fixtures()
        let entry = try XCTUnwrap(try calls.historyEntries().first { $0.ref == "fixed" })
        let detail = try XCTUnwrap(try calls.historyDetail(entry))

        XCTAssertEqual(entry.title, "The Northwind pilot: ask Claude about it.")
        XCTAssertEqual(detail.lines.map(\.text), ["The Northwind pilot: ask Claude about it."])
        XCTAssertEqual(detail.lines[0].whisper, "the northwynd pilot ask Claud about it then we ship")
        XCTAssertEqual(detail.lines[0].t0, 0)
        XCTAssertEqual(detail.lines[0].t1, 5)
        XCTAssertEqual(detail.lines[0].changes.map(\.source), [.retry, .fix, .fix, .fix])
        XCTAssertEqual(detail.lines[0].changes[0].diff.changes, [.init(before: ["northwynd"], after: ["northwind"])])
        XCTAssertEqual(detail.lines[0].changes[1].applied, false)
        XCTAssertEqual(detail.lines[0].changes[1].note, "not-flagged")
        XCTAssertEqual(detail.lines[0].changes[2].after, "ask Claude about it")
        XCTAssertEqual(detail.lines[0].changes[2].note, "Claude")
        XCTAssertEqual(detail.textChanges.map(\.source), [.correction])
        XCTAssertEqual(detail.textChanges[0].after, "The Northwind pilot: ask Claude about it.")
        XCTAssertEqual(detail.textChanges[0].note, "agent 1")
        XCTAssertEqual(detail.audioPath, dir.appending(path: "fixed.wav").path)
    }

    func testAnUncorrectedDictationReadsLineByLineFromWhispersText() throws {
        let calls = try fixtures()
        try store.insert(try dictation("lines", mode: .fix, segments: [seg("first thing", t0: 0, t1: 1), seg("second thing", t0: 1, t1: 3)]))
        let entry = try XCTUnwrap(try calls.historyEntries().first { $0.ref == "lines" })
        let detail = try XCTUnwrap(try calls.historyDetail(entry))

        XCTAssertEqual(detail.lines.map(\.text), ["first thing", "second thing"])
        XCTAssertEqual(detail.lines.map(\.t0), [0, 1])
    }

    func testACaseOnlyFixStillShowsAsAChange() throws {
        let calls = try fixtures()
        let entry = try XCTUnwrap(try calls.historyEntries().first { $0.ref == "second" })
        let detail = try XCTUnwrap(try calls.historyDetail(entry))

        XCTAssertEqual(detail.lines[0].changes[0].diff.changes, [.init(before: ["codex"], after: ["Codex"])])
        XCTAssertEqual(detail.textChanges.map(\.after), ["send it to Kodex", "send it to Codex", "Kodex"])
        XCTAssertEqual(detail.textChanges.map(\.source), [.correction, .correction, .keyTerm])
    }

    func testACallHasItsSidesTimesAndCorrections() throws {
        let calls = try fixtures()
        let entry = try XCTUnwrap(try calls.historyEntries().first { $0.kind == .call })
        let detail = try XCTUnwrap(try calls.historyDetail(entry))

        XCTAssertEqual(entry.title, "Zoom call")
        XCTAssertEqual(detail.lines.map(\.speaker), ["Me", "Call", "Call"])
        XCTAssertEqual(detail.lines.map(\.whisper), ["we use bland", "sounds good", "ask the northwynd team"])
        XCTAssertEqual(detail.lines[0].t0, 0)
        XCTAssertEqual(detail.lines[1].t0, 1.5)
        XCTAssertEqual(detail.lines[1].t1, 3)
        XCTAssertEqual(detail.lines[0].changes.map(\.source), [.retry, .correction])
        XCTAssertEqual(detail.lines[0].changes[1].note, "agent 2")
        XCTAssertEqual(detail.lines[2].changes.map(\.source), [.correction, .keyTerm])
        XCTAssertEqual(detail.lines.map(\.playable), [true, false, true])
    }

    func testOnlyFlaggedOrChangedLinesPlay() throws {
        let calls = try fixtures()
        let entry = try XCTUnwrap(try calls.historyEntries().first { $0.ref == "plain" })
        let detail = try XCTUnwrap(try calls.historyDetail(entry))

        XCTAssertEqual(detail.lines.map(\.playable), [false])
        XCTAssertEqual(detail.allChanges, [])
    }
}
