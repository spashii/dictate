import Foundation
import Testing
import whisper
@testable import VoiceCore

/// The key terms an app would keep in its defaults, in memory.
final class MemoryKeyTerms: KeyTermsSettings, @unchecked Sendable {
    private let lock = NSLock()
    private var text: String

    init(_ text: String = "") { self.text = text }

    var value: String { lock.withLock { text } }

    func keyTerms() async -> String { value }

    func setKeyTerms(_ text: String) async { lock.withLock { self.text = text } }
}

/// One token per character, so a test can say exactly where the limit falls.
struct CharacterTokenizer: PromptTokenizer {
    var max: Int

    func tokens(_ text: String) throws -> Int { text.count }

    func limit() throws -> Int { max }
}

private func count(_ url: URL, _ sql: String) throws -> Int {
    try SQLiteConnection(url: url).query(sql) { $0.int(0) }.first ?? -1
}

@Suite struct EditsMigrationTests {
    /// A file as Voice 0.5.0 leaves it: every migration before edits-1, a dictation and a
    /// call segment already in the index.
    @Test func edits1AddsCorrectionsAndKeepsTheIndex() throws {
        let url = temporaryCallDatabase()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteConnection(url: url)
        try db.exec("""
            CREATE TABLE dictations (id TEXT PRIMARY KEY, created_at REAL NOT NULL, audio_path TEXT NOT NULL,
              duration REAL NOT NULL, mode TEXT NOT NULL, whisper_model TEXT NOT NULL, raw_text TEXT NOT NULL,
              final_text TEXT NOT NULL, cleanup_model TEXT, cleanup_system TEXT, record_ms INTEGER, load_ms INTEGER,
              transcribe_ms INTEGER, cleanup_ms INTEGER, paste_ms INTEGER, error TEXT, origin TEXT);
            CREATE TABLE segments (dictation_id TEXT NOT NULL, idx INTEGER NOT NULL, t0 REAL NOT NULL, t1 REAL NOT NULL,
              text TEXT NOT NULL, avg_logprob REAL, no_speech_prob REAL, compression_ratio REAL, speech_seconds REAL,
              words_per_second REAL, PRIMARY KEY (dictation_id, idx));
            CREATE TABLE voice_migrations (name TEXT PRIMARY KEY, applied_at REAL NOT NULL);
            """)
        let before = CallStore.migrations.prefix { $0.name != "edits-1" }
        #expect(before.map(\.name) == ["calls-1", "search-1", "speakers-1", "retries-1", "retries-2"])
        for migration in before {
            try db.exec(migration.sql)
            try db.run("INSERT INTO voice_migrations VALUES (?, ?)", [migration.name, Date()])
        }
        try db.exec("""
            INSERT INTO dictations VALUES ('old', 1, '/tmp/old.wav', 2, 'plain', 'test', 'meet at the harbour',
              'meet at the harbour', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
            INSERT INTO calls (id, started_at, split, status) VALUES ('c', 1, 1, 'done');
            INSERT INTO call_segments (call_id, channel, start_ms, end_ms, text, created_at)
              VALUES ('c', 'me', 0, 1000, 'the northwynd pilot', 1);
            """)

        let calls = try CallStore(url: url)
        #expect(try calls.appliedMigrations().contains("edits-1"))
        #expect(try count(url, "SELECT count(*) FROM pragma_table_info('dictations') WHERE name = 'corrected_text'") == 1)
        #expect(try count(url, "SELECT count(*) FROM pragma_table_info('call_segments') WHERE name = 'corrected_text'") == 1)
        #expect(try count(url, "SELECT count(*) FROM edits") == 0)
        // What was indexed before stays found, and the new triggers index corrections.
        #expect(try calls.search("harbour").map(\.id) == ["old"])
        #expect(try calls.search("northwynd").map(\.id) == ["c"])
        let segment = try #require(try calls.segments("c").first)
        try calls.correctSegment("c", segment.id, text: "the Northwind pilot", client: nil)
        #expect(try calls.search("northwynd").isEmpty)
        #expect(try calls.search("northwind").map(\.id) == ["c"])
        // A dictation written after the migration is indexed by the new insert trigger.
        try Store(url: url).insert(sampleDictation("lighthouse keeper"))
        #expect(try calls.search("lighthouse").count == 1)
    }
}

@Suite struct CorrectionTests {
    @Test func aDictationKeepsItsTextBesideTheCorrection() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        let original = sampleDictation("send it to the northwynd team")
        try store.insert(original)

        let (corrected, edit) = try calls.correctDictation(original.id, text: "Send it to the Northwind team.",
                                                           client: "test 1")
        #expect(corrected.finalText == "Send it to the Northwind team.")
        #expect(corrected.originalText == "send it to the northwynd team")
        #expect(corrected.rawText == "send it to the northwynd team")
        #expect(corrected.corrected)
        #expect(try count(url, "SELECT count(*) FROM dictations WHERE final_text = 'send it to the northwynd team'") == 1)
        #expect(store.recent(1).first?.finalText == "Send it to the Northwind team.")
        #expect(try calls.dictations().first?.originalText == "send it to the northwynd team")
        #expect(edit.kind == .correctDictation)
        #expect(edit.target == "dictation:\(original.id)")
        #expect(edit.before == Edit.Value(text: "send it to the northwynd team", corrected: false))
        #expect(edit.after == Edit.Value(text: "Send it to the Northwind team.", corrected: true))

        // The original text clears the correction rather than storing a copy of it.
        let (back, _) = try calls.correctDictation(original.id, text: "send it to the northwynd team", client: nil)
        #expect(!back.corrected)
        #expect(try count(url, "SELECT count(*) FROM dictations WHERE corrected_text IS NOT NULL") == 0)
        #expect(throws: VoiceError.self) { try calls.correctDictation("missing", text: "x", client: nil) }
    }

    @Test func aSegmentReadsAsItsCorrectionEverywhere() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: true))
        let written = try calls.appendSegments(call.id, [sampleSegment(.me, 0, "we met ana at akme"),
                                                         sampleSegment(.call, 1500, "great")])
        let (segment, _) = try calls.correctSegment(call.id, written[0].id, text: "We met Alexis at Acme.",
                                                    client: nil)
        #expect(segment.text == "We met Alexis at Acme.")
        #expect(segment.originalText == "we met ana at akme")
        #expect(try calls.segments(call.id).map(\.corrected) == [true, false])
        #expect(try calls.transcript(call.id).contains("Me: We met Alexis at Acme."))
        #expect(try calls.correctedSegments(call.id) == 1)
        // The cursor a live follower holds still works: corrections change no ids.
        #expect(try calls.latestCursor() == written[1].id)
        // A segment of another call isn't found by this call's id.
        let other = try calls.createCall(NewCall(split: true))
        #expect(throws: VoiceError.self) { try calls.correctSegment(other.id, written[0].id, text: "x", client: nil) }
    }

    @Test func searchFindsTheCorrectionAndNotTheOriginal() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        let dictation = sampleDictation("the quarterly numbers from echo")
        try store.insert(dictation)
        let call = try calls.createCall(NewCall(split: true))
        let segment = try calls.appendSegments(call.id, [sampleSegment(.call, 0, "ask the counsel about it")])[0]

        try calls.correctDictation(dictation.id, text: "the quarterly numbers from ECHO platform", client: nil)
        let (_, edit) = try calls.correctSegment(call.id, segment.id, text: "ask the council about it", client: nil)
        #expect(try calls.search("counsel").isEmpty)
        let hit = try #require(try calls.search("council").first)
        #expect(hit.segmentID == segment.id)
        #expect(hit.corrected == true)
        #expect(try calls.search("platform").first?.id == dictation.id)
        #expect(try calls.search("quarterly").first?.corrected == true)

        try calls.undo(edit.id, client: nil)
        #expect(try calls.search("council").isEmpty)
        #expect(try calls.search("counsel").first?.corrected == nil)
        // Rewriting a dictation's row (a retried transcription) reindexes what it now says.
        var again = dictation
        again.finalText = "something else entirely"
        try store.insert(again)
        #expect(try calls.search("platform").isEmpty)
        #expect(try calls.search("entirely").count == 1)
    }
}

@Suite struct KeyTermsTests {
    @Test func parsesAndDedupesWithoutCase() {
        #expect(KeyTerms.parse("Northwind, Acme\n northwind ,,\nAlexis, ACME") == ["Northwind", "Acme", "Alexis"])
        #expect(KeyTerms.prompt(KeyTerms.parse("Northwind, Acme")) == "Northwind, Acme.")
    }

    @Test func addsOnlyNewTermsInTheListsOwnStyle() {
        let commas = KeyTerms.adding(["northwind", "Echo", "echo", "Ana, Orca"], to: "Northwind, Acme")
        #expect(commas.text == "Northwind, Acme, Echo, Ana, Orca")
        #expect(commas.added == ["Echo", "Ana", "Orca"])
        #expect(commas.present == ["northwind", "echo"])
        #expect(KeyTerms.adding(["Echo"], to: "Northwind\nAcme\n").text == "Northwind\nAcme\nEcho")
        #expect(KeyTerms.adding(["Echo"], to: "").text == "Echo")
        #expect(KeyTerms.adding(["acme"], to: "Northwind, Acme").text == "Northwind, Acme")
    }

    @Test func removingWhatWasAddedGivesBackTheSameText() {
        for text in ["Northwind, Acme", "Northwind,Acme", "Northwind\nAcme", "Northwind", ""] {
            let added = KeyTerms.adding(["VoiceTestTerm"], to: text)
            #expect(KeyTerms.removing(["voicetestterm"], from: added.text).text == text)
        }
        let removed = KeyTerms.removing(["acme", "Nope"], from: "Northwind, Acme, Alexis")
        #expect(removed.text == "Northwind, Alexis")
        #expect(removed.removed == ["Acme"])
        #expect(removed.missing == ["Nope"])
        #expect(KeyTerms.removing(["Northwind"], from: "Northwind, Acme").text == "Acme")
    }

    @Test func refusesAnAddThatOutgrowsThePromptWhole() async throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let settings = MemoryKeyTerms("Northwind")
        // "Northwind." is 10 tokens here; the limit leaves room for ", Echo" and ", Ana" but
        // not for ", Acme" as well.
        let editor = KeyTermsEditor(settings: settings, tokenizer: CharacterTokenizer(max: 21), store: calls)
        await #expect(throws: ToolError.self) { try await editor.add(["Echo", "Acme", "Ana"], client: nil) }
        do {
            _ = try await editor.add(["Echo", "Acme", "Ana"], client: nil)
        } catch let error as ToolError {
            #expect(error.message.contains("whisper reads at most 21"))
            #expect(error.message.contains("11 tokens are left"))
            #expect(error.message.contains("these fit: Echo, Ana."))
        }
        #expect(settings.value == "Northwind")
        #expect(try calls.edits().isEmpty)

        let change = try await editor.add(["Echo", "Ana"], client: nil)
        #expect(change.terms == ["Northwind", "Echo", "Ana"])
        #expect(change.tokens == "Northwind, Echo, Ana.".count)
        #expect(change.limit == 21)
        await #expect(throws: ToolError.self) { try await editor.add(["X"], client: nil) }
    }

    /// The light path hands whisper.cpp the vocabulary alone; it has to count exactly as the
    /// fully loaded model does.
    @Test func countsAsTheLoadedModelDoes() throws {
        guard let path = ProcessInfo.processInfo.environment["VOICE_TEST_WHISPER_MODEL"], !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return }
        let light = WhisperTokenizer(modelURL: URL(fileURLWithPath: path))
        var params = whisper_context_default_params()
        params.use_gpu = false
        let loaded: OpaquePointer? = whisper_init_from_file_with_params(path, params)
        let full = try #require(loaded)
        defer { whisper_free(full) }
        let samples = ["Northwind, Acme, Alexis, ECHO, Fieldwork Lab.", "hello", "Zoë's café, naïve 2026 – 7766.",
                       KeyTerms.prompt((1...60).map { "Term\($0)" })]
        for text in samples {
            #expect(try light.tokens(text) == -Int(whisper_tokenize(full, text, nil, 0)), "\(text)")
        }
        #expect(try light.limit() == Int(whisper_n_text_ctx(full)) / 2)
        #expect(try light.limit() == 224)
    }
}

@Suite struct EditLogTests {
    @Test func undoPutsACorrectionBackOnlyWhileItStillApplies() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        let dictation = sampleDictation("first")
        try store.insert(dictation)
        let (_, one) = try calls.correctDictation(dictation.id, text: "second", client: "a 1")
        let (_, two) = try calls.correctDictation(dictation.id, text: "third", client: "b 2")

        #expect(throws: VoiceError.self) { try calls.undo(one.id, client: nil) }
        let undo = try calls.undo(two.id, client: "c 3")
        #expect(undo.kind == .undo)
        #expect(undo.undoes == two.id)
        #expect(undo.target == two.target)
        #expect(undo.client == "c 3")
        #expect(try calls.dictation(dictation.id)?.finalText == "second")
        #expect(throws: VoiceError.self) { try calls.undo(two.id, client: nil) }
        #expect(throws: VoiceError.self) { try calls.undo(undo.id, client: nil) }
        try calls.undo(one.id, client: nil)
        let restored = try #require(try calls.dictation(dictation.id))
        #expect(restored.finalText == "first")
        #expect(!restored.corrected)

        let log = try calls.edits()
        #expect(log.map(\.kind) == [.undo, .undo, .correctDictation, .correctDictation])
        #expect(log.map(\.client) == [nil, "c 3", "b 2", "a 1"])
        #expect(try calls.edit(two.id)?.undoneBy == undo.id)
        #expect(try calls.edits(target: Edit.target(dictation: dictation.id), limit: 1).first?.undoes == one.id)
    }

    @Test func tagChangesAreEditsAndUndoRevertsThem() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: true))
        try calls.tagCall(call.id, add: ["Standup"])
        let (tags, edit) = try calls.tagCall(call.id, add: ["pilot"], remove: ["standup"], client: "t 1")
        #expect(tags == ["pilot"])
        let change = try #require(edit)
        #expect(change.before?.tags == ["Standup"])
        #expect(change.after?.tags == ["pilot"])
        #expect(try calls.tagCall(call.id, add: ["Pilot"], remove: [], client: nil).edit == nil)
        try calls.undo(change.id, client: nil)
        #expect(try calls.call(call.id)?.tags == ["Standup"])
    }

    @Test func keyTermEditsUndoWhatTheyChanged() async throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let settings = MemoryKeyTerms("Northwind\nAcme")
        let editor = KeyTermsEditor(settings: settings, tokenizer: CharacterTokenizer(max: 224), store: calls)
        let add = try #require(try await editor.add(["Echo"], client: "a 1").edit)
        let remove = try #require(try await editor.remove(["acme"], client: "a 1").edit)
        #expect(settings.value == "Northwind\nEcho")
        #expect(add.kind == .addKeyTerms)
        #expect(add.before?.terms == ["Northwind", "Acme"])
        #expect(add.after?.terms == ["Northwind", "Acme", "Echo"])
        #expect(remove.after?.terms == ["Northwind", "Echo"])
        #expect(try await editor.remove(["nothing"], client: nil).edit == nil)

        let undoRemove = try await editor.undo(remove.id, client: "b 2")
        #expect(settings.value == "Northwind\nEcho\nAcme")
        #expect(undoRemove.after?.terms == ["Northwind", "Echo", "Acme"])
        try await editor.undo(add.id, client: "b 2")
        #expect(KeyTerms.parse(settings.value) == ["Northwind", "Acme"])
        await #expect(throws: VoiceError.self) { try await editor.undo(add.id, client: nil) }
        #expect(try calls.edits().map(\.kind) == [.undo, .undo, .removeKeyTerms, .addKeyTerms])
    }
}

/// The tools over HTTP, with the session id initialize hands out naming the client.
@Suite struct EditToolsTests {
    @Test func toolsCorrectListAndUndoAsTheClient() async throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        let settings = MemoryKeyTerms("Northwind")
        let server = MCPServer(store: calls, token: "t", port: 0, keyTerms: settings,
                               tokenizer: CharacterTokenizer(max: 30))
        let port = try await server.start()
        defer { server.stop() }
        let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        var session: String?
        func post(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer t", forHTTPHeaderField: "Authorization")
            if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
            request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method,
                                                                           "params": params])
            let (data, response) = try await URLSession.shared.data(for: request)
            if method == "initialize" {
                session = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id")
            }
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func tool(_ name: String, _ arguments: [String: Any]) async throws -> (Any?, Bool) {
            let reply = try await post("tools/call", ["name": name, "arguments": arguments])
            let result = try #require(reply["result"] as? [String: Any])
            let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8)), result["isError"] as? Bool ?? false)
        }

        _ = try await post("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                          "clientInfo": ["name": "test-agent", "version": "1.2"]])
        #expect(session.flatMap(MCPRouter.client(session:)) == "test-agent 1.2")

        let dictation = sampleDictation("ping the acme team")
        try store.insert(dictation)
        let (fixed, failed) = try await tool("correct_dictation", ["id": dictation.id, "text": "Ping the Acme team."])
        #expect(!failed)
        let object = try #require(fixed as? [String: Any])
        #expect(object["final_text"] as? String == "Ping the Acme team.")
        #expect(object["original_text"] as? String == "ping the acme team")
        #expect(object["corrected"] as? Bool == true)

        let call = try calls.createCall(NewCall(split: true))
        try calls.appendSegments(call.id, [sampleSegment(.me, 0, "hello wold")])
        let (transcript, _) = try await tool("get_transcript", ["id": call.id, "format": "segments"])
        let segmentID = try #require(((transcript as? [String: Any])?["segments"] as? [[String: Any]])?.first?["id"] as? Int)
        let (segment, _) = try await tool("correct_segment", ["call_id": call.id, "segment_id": segmentID,
                                                              "text": "hello world"])
        #expect((segment as? [String: Any])?["corrected"] as? Bool == true)
        #expect((segment as? [String: Any])?["original_text"] as? String == "hello wold")

        let (added, _) = try await tool("add_key_terms", ["terms": ["Acme", "northwind"]])
        #expect((added as? [String: Any])?["added"] as? [String] == ["Acme"])
        #expect((added as? [String: Any])?["already_present"] as? [String] == ["northwind"])
        #expect(settings.value == "Northwind, Acme")
        let (_, refused) = try await tool("add_key_terms", ["terms": ["Fieldwork Lab, the foundation"]])
        #expect(refused)
        let (listed, _) = try await tool("list_key_terms", [:])
        #expect((listed as? [String: Any])?["token_limit"] as? Int == 30)

        let (_, tagFailed) = try await tool("tag_call", ["id": call.id, "add": ["pilot"]])
        #expect(!tagFailed)
        let (edits, _) = try await tool("list_edits", [:])
        let log = try #require(edits as? [[String: Any]])
        #expect(log.compactMap { $0["kind"] as? String } == ["tag_call", "add_key_terms", "correct_segment",
                                                             "correct_dictation"])
        #expect(Set(log.compactMap { $0["client"] as? String }) == ["test-agent 1.2"])
        #expect((log[3]["before"] as? [String: Any])?["text"] as? String == "ping the acme team")

        for edit in log {
            let (_, undoFailed) = try await tool("undo_edit", ["id": edit["id"] as Any])
            #expect(!undoFailed)
        }
        #expect(try calls.dictation(dictation.id)?.corrected == false)
        #expect(try calls.segments(call.id).first?.text == "hello wold")
        #expect(settings.value == "Northwind")
        #expect(try calls.call(call.id)?.tags == [])
        let (_, twice) = try await tool("undo_edit", ["id": log[0]["id"] as Any])
        #expect(twice)
    }

    @Test func keyTermToolsAnswerWithAnErrorWhereThereAreNone() async throws {
        let router = MCPRouter(store: try CallStore(url: temporaryCallDatabase()), recording: nil,
                               recordingUnavailable: "", version: "0")
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "list_key_terms", "arguments": [:]],
        ])
        let (_, data) = await router.handle(body)
        let reply = try JSONSerialization.jsonObject(with: try #require(data)) as? [String: Any]
        #expect((reply?["result"] as? [String: Any])?["isError"] as? Bool == true)
    }
}

@Suite struct HandCorrectionTests {
    /// A detail over the lines of one call, as History reads it.
    private func detail(_ calls: CallStore, _ id: String) throws -> HistoryDetail {
        let entry = try #require(try calls.historyEntries().first { $0.ref == id })
        return try #require(try calls.historyDetail(entry))
    }

    @Test func aPersonsCorrectionIsAnEditByYouThatUndoRevertsAndSearchFinds() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: true))
        let written = try calls.appendSegments(call.id, [sampleSegment(.me, 0, "we met ana at akme today")])
        let request = try #require(try detail(calls, call.id)
            .correction(line: Int(written[0].id), selecting: "akme", at: 14))

        let edit = try #require(try calls.correct(request, to: "Acme", known: []))
        #expect(edit.kind == .correctSegment)
        #expect(edit.client == "You")
        #expect(edit.before == Edit.Value(text: "we met ana at akme today", corrected: false))
        #expect(edit.after == Edit.Value(text: "we met ana at Acme today", corrected: true))
        #expect(try calls.segments(call.id).first?.text == "we met ana at Acme today")
        #expect(try calls.edits().map(\.id) == [edit.id])
        #expect(try calls.search("acme").map(\.id) == [call.id])
        #expect(try calls.search("akme").isEmpty)

        // History marks the words and says who made the change.
        let line = try #require(try detail(calls, call.id).lines.first)
        #expect(line.corrections.map(\.after) == ["Acme"])
        #expect(line.corrections.first?.client == "You")

        try calls.undo(edit.id, client: nil)
        #expect(try calls.segments(call.id).first?.text == "we met ana at akme today")
        #expect(try calls.search("akme").map(\.id) == [call.id])
    }

    @Test func aReplacedNameBecomesAKeyTermSuggestion() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: true))
        let written = try calls.appendSegments(call.id, [sampleSegment(.call, 0, "ask alex about the northwynd pilot")])
        let request = try #require(try detail(calls, call.id)
            .correction(line: Int(written[0].id), selecting: "northwynd", at: 19))
        try calls.correct(request, to: "Northwind", known: [])

        let suggestion = try #require(try calls.termSuggestions().first)
        #expect(suggestion.term == "Northwind")
        #expect(suggestion.heard == ["northwynd"])
        #expect(suggestion.status == .pending)

        // A term already in the list isn't proposed again.
        let second = try calls.appendSegments(call.id, [sampleSegment(.call, 3000, "the akme plan")])
        let again = try #require(try detail(calls, call.id)
            .correction(line: Int(second[0].id), selecting: "akme", at: 4))
        try calls.correct(again, to: "Acme", known: ["Acme"])
        #expect(try calls.termSuggestions().map(\.term) == ["Northwind"])
    }

    @Test func aRepeatedWordIsFoundByWhichOneWasSelected() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: true))
        let written = try calls.appendSegments(call.id, [sampleSegment(.me, 0, "send it to ana and then ana again")])
        // The second "ana": 24 units into the line.
        let request = try #require(try detail(calls, call.id).correction(line: Int(written[0].id), selecting: "ana", at: 24))
        #expect(request.offset == 24)
        try calls.correct(request, to: "Alex", known: [])
        #expect(try calls.segments(call.id).first?.text == "send it to ana and then Alex again")
    }

    @Test func aDictationIsCorrectedAsOneTextAcrossItsLines() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        var dictation = sampleDictation("first ana here. then ana there")
        dictation.segments = [
            Segment(t0: 0, t1: 1, text: "first ana here.", avgLogprob: -0.1, noSpeechProb: 0, compressionRatio: 1,
                    speechSeconds: 1, wordsPerSecond: 2),
            Segment(t0: 1, t1: 2, text: "then ana there", avgLogprob: -0.1, noSpeechProb: 0, compressionRatio: 1,
                    speechSeconds: 1, wordsPerSecond: 2),
        ]
        dictation.duration = 3
        try store.insert(dictation)

        let read = try detail(calls, dictation.id)
        let request = try #require(read.correction(line: read.lines[1].id, selecting: "ana", at: 5))
        #expect(request.target == .dictation(dictation.id))
        #expect(request.offset == 21)
        let edit = try #require(try calls.correct(request, to: "Alex", known: []))
        #expect(edit.kind == .correctDictation)
        #expect(edit.client == "You")
        #expect(try calls.dictation(dictation.id)?.finalText == "first ana here. then Alex there")
        #expect(try calls.search("alex").map(\.id) == [dictation.id])

        // The lines stay, each with its time, and the changed word is marked in its own line.
        let after = try detail(calls, dictation.id)
        #expect(after.lines.map(\.text) == ["first ana here.", "then Alex there"])
        #expect(after.lines.map(\.t0) == [0, 1])
        #expect(after.lines[1].corrections.map(\.after) == ["Alex"])
        #expect(after.lines[1].corrections.first?.client == "You")
        #expect(after.lines[0].corrections.isEmpty)
    }

    @Test func theSelectionsOwnPlaceDecidesWhichRepeatChanges() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: true))
        let written = try calls.appendSegments(call.id, [sampleSegment(.me, 0, "ha ha ha ha")])
        let request = try #require(try detail(calls, call.id).correction(line: Int(written[0].id), selecting: "ha ha", at: 3))
        try calls.correct(request, to: "so", known: [])
        #expect(try calls.segments(call.id).first?.text == "ha so ha")
    }

    @Test func aDictationTheCleanUpRewroteIsNotOfferedForCorrection() throws {
        let url = temporaryCallDatabase()
        let store = try Store(url: url)
        let calls = try CallStore(url: url)
        var dictation = sampleDictation("Send it to the Northwind team.")
        dictation.segments = [Segment(t0: 0, t1: 1, text: "send it to the northwynd team", avgLogprob: -0.1,
                                      noSpeechProb: 0, compressionRatio: 1, speechSeconds: 1, wordsPerSecond: 2)]
        dictation.duration = 3
        try store.insert(dictation)
        let read = try detail(calls, dictation.id)
        #expect(!read.canCorrect)
        #expect(read.correction(line: read.lines[0].id, selecting: "northwynd", at: 15) == nil)
    }

    @Test func leavesNothingToStoreWhenTheWordsAreUnchangedOrGone() throws {
        let calls = try CallStore(url: temporaryCallDatabase())
        let call = try calls.createCall(NewCall(split: true))
        let written = try calls.appendSegments(call.id, [sampleSegment(.me, 0, "hello there Alex")])
        let id = Int(written[0].id)
        let request = try #require(try detail(calls, call.id).correction(line: id, selecting: "there", at: 6))
        #expect(try calls.correct(request, to: " there ", known: []) == nil)
        #expect(try calls.edits().isEmpty)

        // Deleting a word takes its space; a correction can't empty the text.
        try calls.correct(request, to: "", known: [])
        #expect(try calls.segments(call.id).first?.text == "hello Alex")
        #expect(throws: VoiceError.self) { try calls.correct(request, to: "again", known: []) }
        let whole = try #require(try detail(calls, call.id).correction(line: id, selecting: "hello Alex", at: 0))
        #expect(throws: VoiceError.self) { try calls.correct(whole, to: "  ", known: []) }
        // Offsets that don't hold the words give no request.
        #expect(try detail(calls, call.id).correction(line: id, selecting: "Alex", at: 0) == nil)
    }
}
