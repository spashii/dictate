import Foundation
import Testing
@testable import VoiceCore

private let noWord: CommonWords.Dictionary = { _ in false }
private let everyday: CommonWords.Dictionary = { ["harbour", "plan", "the", "see"].contains($0) }

@Suite struct HandCorrectionKeyTermTests {
    private struct Fixture {
        var calls: CallStore
        var terms: MemoryKeyTerms
        var service: KeyTermSuggestions
        var call: String
        var line: Int
    }

    /// A call whose one line says `text`, and the service History corrects it through.
    private func fixture(_ text: String, terms: String = "",
                         dictionary: @escaping CommonWords.Dictionary = noWord) throws -> Fixture {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: true))
        let written = try calls.appendSegments(call.id, [sampleSegment(.me, 0, text)])
        let memory = MemoryKeyTerms(terms)
        let service = KeyTermSuggestions(store: calls, settings: memory, tokenizer: CharacterTokenizer(max: 200),
                                         dictionary: dictionary)
        return Fixture(calls: calls, terms: memory, service: service, call: call.id, line: Int(written[0].id))
    }

    private func request(_ fixture: Fixture, selecting selected: String, at offset: Int) throws -> HandCorrection {
        let entry = try #require(try fixture.calls.historyEntries().first { $0.ref == fixture.call })
        let detail = try #require(try fixture.calls.historyDetail(entry))
        return try #require(detail.correction(line: fixture.line, selecting: selected, at: offset))
    }

    @Test func aCorrectedNameInACallIsAddedToTheKeyTerms() async throws {
        let f = try fixture("send it to north wind today")
        let result = try await f.service.correct(try request(f, selecting: "north wind", at: 11), to: "Northwind")
        #expect(KeyTerms.parse(f.terms.value) == ["Northwind"])
        #expect(result.added.map(\.term) == ["Northwind"])
        #expect(result.refused == nil)
        let add = try #require(try f.calls.edit(result.added[0].editID))
        #expect(add.kind == .addKeyTerms)
        #expect(add.client == Edit.personClient)
        #expect(try f.calls.termSuggestions().isEmpty)
    }

    @Test func aCorrectedNameInADictationIsAddedToTheKeyTerms() async throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        var dictation = sampleDictation("send it to north wind today")
        dictation.segments = [Segment(t0: 0, t1: 1, text: "send it to north wind today", avgLogprob: -0.1, noSpeechProb: 0,
                                      compressionRatio: 1, speechSeconds: 1, wordsPerSecond: 2)]
        try store.insert(dictation)
        let entry = try #require(try calls.historyEntries().first { $0.ref == dictation.id })
        let detail = try #require(try calls.historyDetail(entry))
        let request = try #require(detail.correction(line: detail.lines[0].id, selecting: "north wind", at: 11))
        let memory = MemoryKeyTerms()
        let service = KeyTermSuggestions(store: calls, settings: memory, tokenizer: CharacterTokenizer(max: 200),
                                         dictionary: noWord)
        let result = try await service.correct(request, to: "Northwind")
        #expect(try calls.dictation(dictation.id)?.finalText == "send it to Northwind today")
        #expect(KeyTerms.parse(memory.value) == ["Northwind"])
        #expect(result.added.map(\.term) == ["Northwind"])
    }

    @Test func aCommonWordIsNotAdded() async throws {
        let f = try fixture("see the harbor plan", dictionary: everyday)
        let result = try await f.service.correct(try request(f, selecting: "harbor", at: 8), to: "Harbour")
        #expect(result.edit != nil)
        #expect(result.added.isEmpty)
        #expect(KeyTerms.parse(f.terms.value).isEmpty)
    }

    @Test func aTermAlreadyInTheListIsNotAddedTwice() async throws {
        let f = try fixture("send it to north wind today", terms: "northwind")
        let result = try await f.service.correct(try request(f, selecting: "north wind", at: 11), to: "Northwind")
        #expect(result.added.isEmpty)
        #expect(KeyTerms.parse(f.terms.value) == ["northwind"])
    }

    @Test func aTermDismissedBeforeIsNotAdded() async throws {
        let f = try fixture("send it to north wind today")
        let first = try await f.service.correct(try request(f, selecting: "north wind", at: 11), to: "Northwind")
        try await f.service.undo(first.added)

        let again = try await f.service.correct(try request(f, selecting: "Northwind", at: 11), to: "Northwind")
        #expect(again.edit == nil)
        let second = try f.calls.appendSegments(f.call, [sampleSegment(.me, 3000, "and north wind again")])
        let entry = try #require(try f.calls.historyEntries().first { $0.ref == f.call })
        let detail = try #require(try f.calls.historyDetail(entry))
        let next = try #require(detail.correction(line: Int(second[0].id), selecting: "north wind", at: 4))
        let result = try await f.service.correct(next, to: "Northwind")
        #expect(result.added.isEmpty)
        #expect(KeyTerms.parse(f.terms.value).isEmpty)
    }

    @Test func undoTakesTheTermOutAndKeepsItOutOfPending() async throws {
        let f = try fixture("send it to north wind today", terms: "Lakeside")
        let result = try await f.service.correct(try request(f, selecting: "north wind", at: 11), to: "Northwind")
        #expect(KeyTerms.parse(f.terms.value) == ["Lakeside", "Northwind"])

        try await f.service.undo(result.added)
        #expect(KeyTerms.parse(f.terms.value) == ["Lakeside"])
        #expect(try await f.service.pending().isEmpty)
        #expect(try f.calls.termSuggestions(status: .dismissed).map(\.term) == ["Northwind"])
    }

    @Test func aFullListRefusesTheAddAndLeavesAPendingSuggestion() async throws {
        let f = try fixture("send it to north wind today", terms: String(repeating: "x", count: 195))
        let result = try await f.service.correct(try request(f, selecting: "north wind", at: 11), to: "Northwind")
        #expect(result.added.isEmpty)
        #expect(result.refused?.hasPrefix("Nothing added") == true)
        #expect(try await f.service.pending().map(\.term) == ["Northwind"])
    }

    @Test func anAgentsCorrectionStillOnlySuggests() async throws {
        let f = try fixture("send it to north wind today")
        let (_, edit) = try f.calls.correctSegment(f.call, Int64(f.line), text: "send it to Northwind today", client: "agent")
        try f.calls.suggestKeyTerms(from: edit, known: [], dictionary: noWord)
        #expect(KeyTerms.parse(f.terms.value).isEmpty)
        #expect(try await f.service.pending().map(\.term) == ["Northwind"])
    }
}
