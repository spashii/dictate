import Foundation
import Testing
@testable import VoiceCore

@Suite struct HeardNothingTests {
    @Test func aRecordingThatHeardNothingIsNotListedOrRecent() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)

        var empty = sampleDictation("")
        empty.duration = 3
        try store.insert(empty)
        var failed = sampleDictation("")
        failed.duration = 3
        failed.error = "whisper failed"
        try store.insert(failed)
        var spoken = sampleDictation("book the room")
        spoken.duration = 3
        try store.insert(spoken)

        let quiet = try calls.createCall(NewCall(split: true))
        try calls.appendSegments(quiet.id, [sampleSegment(.me, 0, " ")])
        try calls.finishCall(quiet.id)
        let talked = try calls.createCall(NewCall(split: true))
        try calls.appendSegments(talked.id, [sampleSegment(.me, 0, "hello Alex")])
        try calls.finishCall(talked.id)
        let live = try calls.createCall(NewCall(split: true))

        #expect(Set(store.recent(10).map(\.id)) == [failed.id, spoken.id])
        #expect(Set(try calls.recentCalls(limit: 10).map(\.id)) == [talked.id, live.id])
        let listed = Set(try calls.historyEntries().map(\.ref))
        #expect(listed == [spoken.id, talked.id, live.id])
        // Agents still see every call.
        #expect(Set(try calls.calls().map(\.id)) == [quiet.id, talked.id, live.id])
    }
}
