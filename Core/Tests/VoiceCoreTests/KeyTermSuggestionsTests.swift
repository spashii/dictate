import Foundation
import Testing
@testable import VoiceCore

private func propose(_ original: String, _ corrected: String, known: [String] = []) -> [TermProposals.Proposal] {
    TermProposals.from(original: original, corrected: corrected, known: known)
}

private func proposal(_ term: String, _ heard: String...) -> TermProposals.Proposal {
    TermProposals.Proposal(term: term, heard: heard)
}

@Suite struct TermProposalTests {
    @Test func aReplacedWordIsProposedWithHowWhisperHeardIt() {
        #expect(propose("send it back to codecs today", "send it back to Codex today") == [proposal("Codex", "codecs")])
        #expect(propose("why do we need both agents and cloud.md?", "why do we need both agents and Claude.md?")
                == [proposal("Claude", "cloud")])
        #expect(propose("is it using flawed a lot", "is it using Claude a lot") == [proposal("Claude", "flawed")])
    }

    @Test func wordRangesQuoteTheWordsAsWritten() {
        let text = "“Acme’s” plan -- it's T3-Code, 'quoted'"
        #expect(WordDiff.wordRanges(text).map { String(text[$0]) } == WordDiff.words(text))
        #expect(WordDiff.words(text) == ["Acme’s", "plan", "it's", "T3", "Code", "quoted"])
        let diff = WordDiff("we met sam at akme", "we met Sameer and Ana at Acme")
        #expect(diff.spans == [WordDiff.Span(before: 2..<3, after: 2..<5), WordDiff.Span(before: 4..<5, after: 6..<7)])
    }

    @Test func aNameKeepsTheNeighboursTheCorrectionOnlyRecased() {
        #expect(propose("an MCP that tea three code can use", "an MCP that T3 Code can use")
                == [proposal("T3 Code", "tea three code")])
        #expect(propose("open cloud code now", "open Claude Code now") == [proposal("Claude Code", "cloud code")])
        // A capital that starts a sentence isn't part of the name, nor is a word past a full stop.
        #expect(propose("so cloud wrote it", "So Claude wrote it") == [proposal("Claude", "cloud")])
        #expect(propose("ask cloud. then go", "ask Claude. Then go") == [proposal("Claude", "cloud")])
        // Joined spellings stay as the correction wrote them.
        #expect(propose("ask tea three-code", "ask T3-Code") == [proposal("T3-Code", "tea three-code")])
        #expect(propose("the cloud's plan", "the Claude's plan") == [proposal("Claude", "cloud")])
    }

    @Test func punctuationSentenceCaseAndFillerProposeNothing() {
        #expect(propose("hello, world", "Hello world.").isEmpty)
        #expect(propose("send it. then go", "Send it. Then go").isEmpty)
        #expect(propose("ask Prior Art", "ask prior art").isEmpty)
        #expect(propose("then i said ok", "then I said OK").isEmpty)
        #expect(propose("um so we ship it", "we ship it").isEmpty)
        #expect(propose("we uh ship it", "we um ship it").isEmpty)
        #expect(propose("their going", "they're going").isEmpty)
        #expect(propose("is the plan", "was a plan").isEmpty)
    }

    @Test func aNameOnlyRecasedIsProposed() {
        #expect(propose("uses blend and t3 code", "Uses Blend and T3 Code")
                == [proposal("Blend", "blend"), proposal("T3 Code", "t3 code")])
        // Words already written as a name join the one the correction re-cased.
        #expect(propose("provide an MCP that T3 code can use", "provide an MCP that T3 Code can use")
                == [proposal("T3 Code", "T3 code")])
        #expect(propose("a first class citizen in workbench.", "a first class citizen in Workbench.")
                == [proposal("Workbench", "workbench")])
        // At the start of a sentence a capital alone says nothing; a digit or an inner capital does.
        #expect(propose("blend it in", "Blend it in").isEmpty)
        #expect(propose("t3-code can", "T3-Code can") == [proposal("T3-Code", "t3-code")])
        #expect(propose("iphone first", "iPhone first") == [proposal("iPhone", "iphone")])
        #expect(propose("ask blend", "ask Blend", known: ["blend"]).isEmpty)
        // A replacement takes its re-cased neighbours once, not again as a case change.
        #expect(propose("open cloud code", "open Claude Code") == [proposal("Claude Code", "cloud code")])
        #expect(propose("blend, cloud and akme", "Blend, Claude and Acme")
                == [proposal("Claude", "cloud"), proposal("Acme", "akme")])
    }

    @Test func additionsRemovalsNumbersAndRewritesProposeNothing() {
        #expect(propose("we ship", "we ship Northwind").isEmpty)
        #expect(propose("we ship Northwind", "we ship").isEmpty)
        #expect(propose("about fifteen people", "about 15 people").isEmpty)
        #expect(propose("we should probably think about it later on", "Let us revisit this question next week instead")
                .isEmpty)
        // Two names a comma separates aren't one term.
        #expect(propose("ask cloud codecs", "ask Claude, Codex").isEmpty)
    }

    @Test func fillerAtTheEdgesIsTrimmedFromBothSides() {
        #expect(propose("ask uh cloud about it", "ask Claude about it") == [proposal("Claude", "cloud")])
    }

    @Test func knownTermsAndRepeatsAreProposedOnce() {
        #expect(propose("ask cloud and akme", "ask Claude and Acme", known: ["claude"]) == [proposal("Acme", "akme")])
        #expect(propose("cloud.md or cloud or flawed", "Claude.md or Claude or Claude")
                == [proposal("Claude", "cloud", "flawed")])
    }
}

@Suite struct TermSuggestionStoreTests {
    private func corrected(_ calls: CallStore, _ store: Store, _ original: String, _ text: String,
                           known: [String] = []) throws -> [TermSuggestion] {
        let dictation = sampleDictation(original)
        try store.insert(dictation)
        let (_, edit) = try calls.correctDictation(dictation.id, text: text, client: "agent")
        return try calls.suggestKeyTerms(from: edit, known: known)
    }

    @Test func correctionsAreStoredOnceATermAndMerged() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        let first = try corrected(calls, store, "ask cloud about it", "ask Claude about it")
        #expect(first.map(\.term) == ["Claude"])
        #expect(first[0].status == .pending)
        #expect(first[0].heard == ["cloud"])
        let again = try corrected(calls, store, "is it flawed", "is it Claude")
        #expect(again.map(\.id) == first.map(\.id))
        #expect(again[0].heard == ["cloud", "flawed"])
        #expect(again[0].corrections == 2)
        #expect(again[0].editID == first[0].editID)
        #expect(try calls.termSuggestions().count == 1)
        // The same term in another case is the same suggestion.
        #expect(try corrected(calls, store, "the claud plan", "the CLAUDE plan").map(\.id) == first.map(\.id))
        // Listed already: nothing.
        #expect(try corrected(calls, store, "ping akme", "ping Acme", known: ["Acme"]).isEmpty)
        #expect(try calls.termSuggestions().map(\.term) == ["Claude"])
    }

    @Test func aCorrectionBackToWhispersTextProposesNothing() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        let dictation = sampleDictation("ask cloud")
        try store.insert(dictation)
        try calls.correctDictation(dictation.id, text: "ask Claude", client: nil)
        let (_, back) = try calls.correctDictation(dictation.id, text: "ask cloud", client: nil)
        #expect(try calls.suggestKeyTerms(from: back, known: []).isEmpty)
        let call = try calls.createCall(NewCall(split: true))
        let segment = try calls.appendSegments(call.id, [sampleSegment(.call, 0, "the zentrah pilot")])[0]
        let (_, edit) = try calls.correctSegment(call.id, segment.id, text: "the Zentra pilot", client: nil)
        #expect(try calls.suggestKeyTerms(from: edit, known: []).map(\.heard) == [["zentrah"]])
    }

    @Test func dismissIsAnEditAndUndoBringsItBack() async throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        let settings = MemoryKeyTerms("Northwind")
        let suggestions = KeyTermSuggestions(store: calls, settings: settings, tokenizer: CharacterTokenizer(max: 200))
        let id = try #require(try corrected(calls, store, "ask cloud", "ask Claude").first?.id)

        let edit = try await suggestions.dismiss(id)
        #expect(edit.kind == .dismissKeyTerm)
        #expect(edit.client == KeyTermSuggestions.settingsClient)
        #expect(edit.target == "key_term_suggestion:\(id)")
        #expect(edit.before == Edit.Value(terms: ["Claude"], status: "pending"))
        #expect(edit.after == Edit.Value(terms: ["Claude"], status: "dismissed"))
        #expect(try calls.termSuggestion(id)?.status == .dismissed)
        #expect(try calls.termSuggestion(id)?.decisionEditID == edit.id)
        #expect(try await suggestions.pending().isEmpty)
        #expect(settings.value == "Northwind")
        // A dismissed term isn't proposed again.
        #expect(try corrected(calls, store, "is it flawed", "is it Claude").isEmpty)
        await #expect(throws: VoiceError.self) { try await suggestions.accept(id) }

        let router = MCPRouter(store: calls, recording: nil, recordingUnavailable: "", version: "0",
                               keyTerms: KeyTermsEditor(settings: settings, tokenizer: CharacterTokenizer(max: 200),
                                                        store: calls))
        let undo = try await call(router, "undo_edit", ["id": edit.id])
        #expect(undo.failed == false)
        #expect(try calls.termSuggestion(id)?.status == .pending)
        #expect(try calls.termSuggestion(id)?.decisionEditID == nil)
        #expect(try await suggestions.pending().map(\.term) == ["Claude"])
    }

    @Test func acceptAddsThroughTheKeyTermsPathAndUndoTakesItOut() async throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        let settings = MemoryKeyTerms("Northwind")
        let suggestions = KeyTermSuggestions(store: calls, settings: settings, tokenizer: CharacterTokenizer(max: 200))
        let id = try #require(try corrected(calls, store, "an MCP tea three code uses", "an MCP T3 Code uses").first?.id)
        #expect(try await suggestions.pending().map(\.term) == ["T3 Code"])

        let edit = try #require(try await suggestions.accept(id))
        #expect(settings.value == "Northwind, T3 Code")
        #expect(edit.kind == .addKeyTerms)
        #expect(edit.target == Edit.keyTermsTarget)
        #expect(edit.client == KeyTermSuggestions.settingsClient)
        #expect(edit.before?.terms == ["Northwind"])
        #expect(edit.after?.terms == ["Northwind", "T3 Code"])
        #expect(try calls.termSuggestion(id)?.status == .accepted)
        #expect(try calls.termSuggestion(id)?.decisionEditID == edit.id)
        #expect(try await suggestions.pending().isEmpty)
        await #expect(throws: VoiceError.self) { try await suggestions.accept(id) }

        let router = MCPRouter(store: calls, recording: nil, recordingUnavailable: "", version: "0",
                               keyTerms: KeyTermsEditor(settings: settings, tokenizer: CharacterTokenizer(max: 200),
                                                        store: calls))
        #expect(try await call(router, "undo_edit", ["id": edit.id]).failed == false)
        #expect(settings.value == "Northwind")
        #expect(try calls.termSuggestion(id)?.status == .pending)
        #expect(try await suggestions.pending().map(\.term) == ["T3 Code"])
        // Typed into the list by hand, it stops being suggested.
        await settings.setKeyTerms("Northwind, t3 code")
        #expect(try await suggestions.pending().isEmpty)
    }

    @Test func acceptIsRefusedPastWhispersPromptLimit() async throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        let settings = MemoryKeyTerms("Northwind")
        // The prompt for "Northwind" alone fits; with another term it doesn't.
        let tokenizer = CharacterTokenizer(max: KeyTerms.prompt(["Northwind"]).count + 3)
        let suggestions = KeyTermSuggestions(store: calls, settings: settings, tokenizer: tokenizer)
        let id = try #require(try corrected(calls, store, "ask fieldwork some", "ask Fieldwork Labz").first?.id)

        var message = ""
        do {
            try await suggestions.accept(id)
        } catch {
            message = "\(error)"
        }
        #expect(message.hasPrefix("Nothing added: whisper's prompt would be"))
        #expect(message.contains("none of these terms fits"))
        #expect(settings.value == "Northwind")
        #expect(try calls.termSuggestion(id)?.status == .pending)
        #expect(try calls.edits().isEmpty == false)
        #expect(try calls.edits().allSatisfy { $0.kind == .correctDictation })
    }
}

@Suite struct TermSuggestionToolTests {
    @Test func correctionsProposeAndTheToolOnlyLists() async throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        let settings = MemoryKeyTerms("Codex")
        let router = MCPRouter(store: calls, recording: nil, recordingUnavailable: "", version: "0",
                               keyTerms: KeyTermsEditor(settings: settings, tokenizer: CharacterTokenizer(max: 200),
                                                        store: calls))
        let dictation = sampleDictation("send it to codecs and ask cloud about zentrah")
        try store.insert(dictation)
        let fixed = try await call(router, "correct_dictation",
                                   ["id": dictation.id, "text": "Send it to Codex and ask Claude about Zentra."])
        #expect(!fixed.failed)

        let listed = try await call(router, "list_key_term_suggestions", [:])
        let rows = try #require(listed.value as? [[String: Any]])
        #expect(rows.compactMap { $0["term"] as? String } == ["Zentra", "Claude"])
        #expect(rows.compactMap { $0["heard"] as? [String] } == [["zentrah"], ["cloud"]])
        #expect(Set(rows.compactMap { $0["status"] as? String }) == ["pending"])
        let editID = try #require(try calls.edits().first?.id)
        #expect(Set(rows.compactMap { $0["edit_id"] as? Int64 }) == [editID])
        #expect(settings.value == "Codex")

        // Typed in by hand since: no longer pending in the list.
        await settings.setKeyTerms("Codex, Zentra")
        let after = try #require(try await call(router, "list_key_term_suggestions", [:]).value as? [[String: Any]])
        #expect(after.compactMap { $0["term"] as? String } == ["Claude"])
        #expect((try await call(router, "list_key_term_suggestions", ["status": "nope"])).failed)

        let tool = try #require(MCPRouter.tools.first { $0["name"] as? String == "list_key_term_suggestions" })
        #expect((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        // Taking a suggestion is the user's tap in Settings, never a tool.
        let names = MCPRouter.tools.compactMap { $0["name"] as? String }
        #expect(!names.contains { $0.contains("suggestion") && $0 != "list_key_term_suggestions" })
    }
}

/// One tools/call through the router: the parsed JSON it answered with, and whether it was an error.
private func call(_ router: MCPRouter, _ name: String, _ arguments: [String: Any]) async throws -> (value: Any?, failed: Bool) {
    let request = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments],
    ])
    let (_, data) = await router.handle(request, client: "test")
    let body = try #require(data)
    let reply = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let result = try #require(reply["result"] as? [String: Any])
    let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    return (try? JSONSerialization.jsonObject(with: Data(text.utf8)), result["isError"] as? Bool ?? false)
}
