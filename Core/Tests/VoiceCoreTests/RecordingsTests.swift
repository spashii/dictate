import Foundation
import Testing
@testable import VoiceCore

private func rows(_ url: URL, _ sql: String) throws -> Int {
    try SQLiteConnection(url: url).query(sql) { $0.int(0) }.first ?? -1
}

@Suite struct RenameTests {
    @Test func aTitleReplacesNothingStoredAndIsAnEditUndoRevertsAndSearchFinds() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        let dictation = sampleDictation("send the plan to the team")
        try store.insert(dictation)
        let call = try calls.createCall(NewCall(appName: "Slack", split: true))
        try calls.appendSegments(call.id, [sampleSegment(.me, 0, "hello there")])

        let edit = try #require(try calls.rename(.dictation, dictation.id, to: "  Weekly plan  "))
        #expect(edit.kind == .renameRecording)
        #expect(edit.client == "You")
        #expect(edit.target == "dictation:\(dictation.id)")
        #expect(edit.before == Edit.Value(text: nil))
        #expect(edit.after == Edit.Value(text: "Weekly plan"))
        _ = try calls.rename(.call, call.id, to: "Standup with Alex")

        let entries = try calls.historyEntries()
        #expect(entries.first { $0.ref == dictation.id }?.customTitle == "Weekly plan")
        #expect(entries.first { $0.ref == call.id }?.customTitle == "Standup with Alex")
        #expect(entries.first { $0.ref == call.id }?.kindLabel == "Slack call")
        // The title is searchable, and renaming isn't a change to the words.
        #expect(try calls.historyEntries(matching: "weekly").map(\.ref) == [dictation.id])
        #expect(entries.first { $0.ref == dictation.id }?.changes == 0)
        #expect(try calls.historyDetail(try #require(entries.first { $0.ref == dictation.id }))?.textChanges.isEmpty == true)

        // The same name again changes nothing; blank text takes it away.
        #expect(try calls.rename(.dictation, dictation.id, to: "Weekly plan") == nil)
        let cleared = try #require(try calls.rename(.dictation, dictation.id, to: "   "))
        #expect(cleared.after == Edit.Value(text: nil))

        try calls.undo(cleared.id, client: "agent 1")
        #expect(try calls.historyEntries().first { $0.ref == dictation.id }?.customTitle == "Weekly plan")
        try calls.undo(edit.id, client: nil)
        #expect(try calls.historyEntries().first { $0.ref == dictation.id }?.customTitle == nil)
        // The undo isn't drawn as a correction of the text.
        let read = try #require(try calls.historyEntries().first { $0.ref == dictation.id })
        #expect(try calls.historyDetail(read)?.textChanges.isEmpty == true)
        #expect(throws: VoiceError.self) { try calls.rename(.call, "missing", to: "x") }
    }

    @Test func undoRefusesAfterALaterRename() throws {
        let url = temporaryCallDatabase()
        let calls = try CallStore(url: url)
        let call = try calls.createCall(NewCall(split: true))
        let first = try #require(try calls.rename(.call, call.id, to: "One"))
        try calls.rename(.call, call.id, to: "Two")
        #expect(throws: VoiceError.self) { try calls.undo(first.id, client: nil) }
    }

    @Test func aCallWithoutAnAppIsJustACall() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: true))
        try calls.appendSegments(call.id, [sampleSegment(.me, 0, "hello")])
        #expect(try calls.historyEntries().first?.kindLabel == "Call")
    }
}

@Suite struct DeleteRecordingTests {
    private func file(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dictate-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    @Test func aCallGoesWithEverythingKeptForIt() throws {
        let url = temporaryCallDatabase()
        let calls = try CallStore(url: url)
        let audio = try file("call.m4a")
        let keep = try calls.createCall(NewCall(split: true))
        let other = try calls.appendSegments(keep.id, [sampleSegment(.me, 0, "lighthouse keeper")])
        let call = try calls.createCall(NewCall(split: true, audioPath: audio.path))
        let segments = try calls.appendSegments(call.id, [
            NewCallSegment(channel: .me, startMs: 0, endMs: 1500, text: "we met ana at akme", avgLogprob: -0.8,
                           retry: .init(firstText: "we met anna at akme", firstLogprob: -0.9, flagged: true)),
        ])
        try calls.tagCall(call.id, add: ["standup"], remove: [])
        try calls.correctSegment(call.id, segments[0].id, text: "we met Ana at Acme", client: "agent 1")
        try calls.rename(.call, call.id, to: "Standup")
        #expect(try calls.search("acme").count == 1)
        try calls.finishCall(call.id)

        try calls.deleteRecording(.call, call.id)
        #expect(try rows(url, "SELECT count(*) FROM calls WHERE id = '\(call.id)'") == 0)
        for table in ["call_segments", "call_tags", "segment_retries"] {
            #expect(try rows(url, "SELECT count(*) FROM \(table) WHERE call_id = '\(call.id)'") == 0, "\(table)")
        }
        #expect(try rows(url, "SELECT count(*) FROM edits WHERE target LIKE 'call:\(call.id)%'") == 0)
        #expect(try calls.search("acme").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        // Another call, its words and its search entries are untouched.
        #expect(try calls.search("lighthouse").map(\.id) == [keep.id])
        #expect(try calls.segments(keep.id).map(\.id) == other.map(\.id))
    }

    @Test func aDictationGoesWithItsSegmentsRetriesFixesAndEdits() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        let audio = try file("one.wav")
        var dictation = sampleDictation("send it to the northwynd team")
        dictation.audioPath = audio.path
        dictation.segments = [Segment(t0: 0, t1: 1, text: "send it to the northwynd team", avgLogprob: -0.9, noSpeechProb: 0,
                                      compressionRatio: 1, speechSeconds: 1, wordsPerSecond: 2)]
        dictation.segments[0].retry = .init(firstText: "send it to the northwynd team", firstLogprob: -0.9, flagged: true)
        dictation.fixEdits = [FixEdit(segment: 0, span: "northwynd", replacement: "Northwind", keyTerm: "Northwind", offset: 15)]
        try store.insert(dictation)
        let survivor = sampleDictation("keep this one")
        try store.insert(survivor)
        try calls.correctDictation(dictation.id, text: "send it to the Northwind team", client: "agent 1")
        try calls.rename(.dictation, dictation.id, to: "Plan")
        #expect(try calls.search("northwind").count == 1)

        try calls.deleteRecording(.dictation, dictation.id)
        for table in ["dictations WHERE id", "segments WHERE dictation_id", "segment_retries WHERE dictation_id",
                      "fix_edits WHERE dictation_id"] {
            #expect(try rows(url, "SELECT count(*) FROM \(table) = '\(dictation.id)'") == 0, "\(table)")
        }
        #expect(try rows(url, "SELECT count(*) FROM edits WHERE target = 'dictation:\(dictation.id)'") == 0)
        #expect(try calls.search("northwind").isEmpty)
        #expect(try calls.search("northwynd").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(try calls.search("keep").map(\.id) == [survivor.id])
        // Deleting what is already gone is not an error.
        try calls.deleteRecording(.dictation, dictation.id)
    }

    @Test func aFileAnotherRowUsesStaysAndALiveCallIsRefused() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        let audio = try file("shared.wav")
        var first = sampleDictation("first")
        first.audioPath = audio.path
        var second = sampleDictation("second")
        second.audioPath = audio.path
        try store.insert(first)
        try store.insert(second)
        try calls.deleteRecording(.dictation, first.id)
        #expect(FileManager.default.fileExists(atPath: audio.path))
        try calls.deleteRecording(.dictation, second.id)
        #expect(!FileManager.default.fileExists(atPath: audio.path))

        let live = try calls.createCall(NewCall(split: true))
        #expect(throws: VoiceError.self) { try calls.deleteRecording(.call, live.id) }
        #expect(try rows(url, "SELECT count(*) FROM calls WHERE id = '\(live.id)'") == 1)
    }
}
