import AppKit
import Foundation
import Testing
@testable import VoiceCore

/// Every Copy in the app goes through TranscriptCopy. Each test copies onto a pasteboard of
/// its own that starts with other text on it, never onto the general one.
@Suite struct TranscriptCopyTests {
    private static let held = "held before"

    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.setString(Self.held, forType: .string)
        return board
    }

    @Test func copiesACallWithBothSidesLabelledByTime() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: true))
        // Each side is transcribed apart, so they arrive out of time order.
        try calls.appendSegments(call.id, [sampleSegment(.me, 0, "Shall we start?"), sampleSegment(.me, 6000, "Good.")])
        try calls.appendSegments(call.id, [sampleSegment(.call, 2500, " Yes, the pilot first. ")])
        let board = pasteboard()
        defer { board.releaseGlobally() }

        #expect(TranscriptCopy.copy(.call(call.id), in: calls, to: board))
        #expect(board.string(forType: .string) == """
            [00:00] Me: Shall we start?
            [00:02] Call: Yes, the pilot first.
            [00:06] Me: Good.
            """)
        #expect(try calls.historyEntries().first { $0.ref == call.id }?.hasText == true)
    }

    @Test func copiesCorrectionsInPlaceOfWhisper() throws {
        let url = temporaryCallDatabase()
        let calls = try CallStore(url: url)
        let call = try calls.createCall(NewCall(split: true))
        let segments = try calls.appendSegments(call.id, [sampleSegment(.me, 0, "Ask Akme for the numbers."),
                                                          sampleSegment(.call, 2000, "Will do.")])
        try calls.correctSegment(call.id, segments[0].id, text: "Ask Acme for the numbers.", client: "test")
        let dictation = sampleDictation("Move the review to Thursday.")
        try Store(url: url).insert(dictation)
        try calls.correctDictation(dictation.id, text: "Move the review to Friday.", client: "test")
        let board = pasteboard()
        defer { board.releaseGlobally() }

        #expect(TranscriptCopy.copy(.call(call.id), in: calls, to: board))
        #expect(board.string(forType: .string) == "[00:00] Me: Ask Acme for the numbers.\n[00:02] Call: Will do.")
        // As the History window reads it, and as the menu's Recent list does.
        let read = try #require(try calls.dictation(dictation.id))
        #expect(TranscriptCopy.copy(.dictation(read), in: calls, to: board))
        #expect(board.string(forType: .string) == "Move the review to Friday.")
        let recent = try #require(try Store(url: url).recent(1).first)
        #expect(TranscriptCopy.copy(.dictation(recent), in: nil, to: board))
        #expect(board.string(forType: .string) == "Move the review to Friday.")
    }

    @Test func copiesAndShowsNothingWithoutText() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: true))
        let board = pasteboard()
        defer { board.releaseGlobally() }

        #expect(TranscriptCopy.text(.call(call.id), in: calls) == nil)
        #expect(!TranscriptCopy.copy(.call(call.id), in: calls, to: board))
        // Segments whisper wrote with no words make no transcript either.
        try calls.appendSegments(call.id, [sampleSegment(.me, 0, " "), sampleSegment(.call, 1000, "\n")])
        #expect(!TranscriptCopy.copy(.call(call.id), in: calls, to: board))
        #expect(!TranscriptCopy.copy(.call(call.id), in: nil, to: board))
        #expect(!TranscriptCopy.copy(.call("no-such-call"), in: calls, to: board))
        #expect(!TranscriptCopy.copy(.dictation(sampleDictation(" \n")), in: nil, to: board))
        #expect(board.string(forType: .string) == Self.held)
        // The History window offers no Copy for it.
        #expect(try calls.historyEntries().first { $0.ref == call.id }?.hasText == false)
    }
}
