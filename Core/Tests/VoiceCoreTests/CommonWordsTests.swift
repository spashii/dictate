import Foundation
import Testing
@testable import VoiceCore

/// A small stand-in for the system dictionary, so the rule is tested on its own.
private let anyWord: CommonWords.Dictionary = { _ in true }
private let noWord: CommonWords.Dictionary = { _ in false }
private let everyday: CommonWords.Dictionary = { ["quarterly", "roadmap", "harbour", "atlas", "the", "plan", "it's"].contains($0) }

@Suite struct CommonWordsTests {
    @Test func aTermOfOnlyEverydayWordsIsCommon() {
        #expect(CommonWords.covers("Atlas", in: everyday))
        #expect(CommonWords.covers("quarterly roadmap", in: everyday))
        #expect(CommonWords.covers("Harbour", in: everyday))
        #expect(CommonWords.covers("it's", in: everyday))
        #expect(CommonWords.covers("It’s", in: everyday))
    }

    @Test func oneUnknownWordKeepsTheTerm() {
        #expect(!CommonWords.covers("Quorvin", in: everyday))
        #expect(!CommonWords.covers("Atlas Quorvin", in: everyday))
        #expect(!CommonWords.covers("OAuth", in: everyday))
    }

    @Test func digitsAndSingleLettersAreNames() {
        #expect(!CommonWords.covers("T3 Code", in: everyday))
        #expect(!CommonWords.covers("plan9", in: everyday))
        #expect(!CommonWords.covers("A", in: anyWord))
        #expect(!CommonWords.covers("", in: anyWord))
        #expect(!CommonWords.covers("...", in: anyWord))
    }

    @Test func joinersSplitTheWords() {
        #expect(CommonWords.covers("the-plan", in: everyday))
        #expect(!CommonWords.covers("the-quorvin", in: everyday))
    }

    /// The real dictionary, as the app uses it.
    @Test func theSystemDictionaryKnowsEverydayWordsAndNotNames() {
        for term in ["roadmap", "quarterly roadmap", "harbour", "harbor", "atlas", "pricing update", "release"] {
            #expect(CommonWords.covers(term), "\(term)")
        }
        for term in ["OAuth", "Quorvin", "Kubernetes", "Northwind", "T3 Code"] {
            #expect(!CommonWords.covers(term), "\(term)")
        }
    }
}

@Suite struct CommonWordSuggestionTests {
    private func suggest(_ original: String, _ text: String, dictionary: @escaping CommonWords.Dictionary) throws
        -> (CallStore, [TermSuggestion]) {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        let dictation = sampleDictation(original)
        try store.insert(dictation)
        let (_, edit) = try calls.correctDictation(dictation.id, text: text, client: "agent")
        return (calls, try calls.suggestKeyTerms(from: edit, known: [], dictionary: dictionary))
    }

    @Test func aCommonWordIsNeverSuggested() throws {
        let (calls, made) = try suggest("see the quarter the road map plan", "see the quarterly roadmap plan",
                                        dictionary: everyday)
        #expect(made.isEmpty)
        #expect(try calls.termSuggestions().isEmpty)
    }

    @Test func aNameStillIs() throws {
        let (_, made) = try suggest("ask corvin about the atlas", "ask Quorvin about the atlas", dictionary: everyday)
        #expect(made.map(\.term) == ["Quorvin"])
    }

    @Test func suggestionsStoredBeforeTheCheckAreHiddenToo() async throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        let dictation = sampleDictation("see the harbor plan")
        try store.insert(dictation)
        let (_, edit) = try calls.correctDictation(dictation.id, text: "see the Harbour plan", client: "agent")
        // Stored as an earlier version would have, with nothing filtering it out.
        let kept = try calls.suggestKeyTerms(from: edit, known: [], dictionary: noWord)
        #expect(kept.map(\.term) == ["Harbour"])
        let service = KeyTermSuggestions(store: calls, settings: MemoryKeyTerms(), tokenizer: CharacterTokenizer(max: 200), dictionary: everyday)
        #expect(try await service.pending().isEmpty)
    }
}
