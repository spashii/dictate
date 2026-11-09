import XCTest
@testable import VoiceCore

/// A segment with a log probability, and a retry record saying whether it was flagged.
private func seg(_ text: String, _ logprob: Double = -0.1, flagged: Bool? = nil, t0: Double = 0,
                 t1: Double = 1) -> Segment {
    var s = Segment(t0: t0, t1: t1, text: text, avgLogprob: logprob, noSpeechProb: 0, compressionRatio: 1,
                    speechSeconds: t1 - t0, wordsPerSecond: 2)
    if let flagged { s.retry = .init(firstText: text, firstLogprob: logprob, flagged: flagged) }
    return s
}

private func transcript(_ segments: [Segment]) -> Transcript {
    Transcript(text: TargetedFix.join(segments.map(\.text)), segments: segments, seconds: 1)
}

/// Ollama's answer carrying edits as the structured output asks for them.
private func editsReply(_ edits: [[String: Any]]) -> [String: Any] {
    let response = String(decoding: try! JSONSerialization.data(withJSONObject: ["edits": edits]), as: UTF8.self)
    return ["model": "qwen3.5:9b", "response": response, "done": true, "load_duration": 0]
}

final class TargetedFixTests: XCTestCase {
    func testTheRetryRecordDecidesWhatIsFlagged() {
        let segments = [seg("a", -0.9, flagged: false), seg("b", -0.1, flagged: true), seg("c", -0.9), seg("", -2)]

        XCTAssertEqual(TargetedFix.flagged(segments, below: -0.6), [1, 2])
    }

    func testThePromptHoldsOnlyFlaggedSegmentsWithTheirNeighbours() {
        let segments = [seg("one two"), seg("we need Claud"), seg("three four")]

        let prompt = TargetedFix.prompt(segments, flagged: [1], keyTerms: ["Claude", " ", "Blend"])

        XCTAssertEqual(prompt, """
            Key terms: Claude, Blend

            Segment 1
            Before: one two
            Text: we need Claud
            After: three four
            """)
    }

    func testWithEverySegmentSentTheListIsTheDictationWithNoContextRepeated() {
        let segments = [seg("we need Claud"), seg(""), seg("and blend"), seg("done")]

        let sent = TargetedFix.sent(segments, scope: .every, flagBelow: -0.6)
        let prompt = TargetedFix.prompt(segments, flagged: [0, 2], keyTerms: ["Claude"])

        XCTAssertEqual(sent, [0, 2, 3])
        XCTAssertEqual(prompt, """
            Key terms: Claude

            Segment 0
            Text: we need Claud

            Segment 2
            Text: and blend
            After: done
            """)
        XCTAssertEqual(TargetedFix.prompt(segments, flagged: sent, keyTerms: []), """
            Key terms: none

            Segment 0
            Text: we need Claud

            Segment 2
            Text: and blend

            Segment 3
            Text: done
            """)
    }

    func testAMatchingEditIsAppliedInPlace() {
        let segments = [seg("why both Agents and Claud.md?", flagged: true), seg("fine")]
        let proposed = [FixEdit(segment: 0, span: "Claud.md", replacement: "Claude.md", keyTerm: "Claude")]

        let edits = TargetedFix.validate(proposed, segments: segments, flagged: [0])

        XCTAssertEqual(edits, [FixEdit(segment: 0, span: "Claud.md", replacement: "Claude.md", keyTerm: "Claude",
                                       offset: 20)])
        XCTAssertEqual(TargetedFix.apply(edits, to: segments), ["why both Agents and Claude.md?", "fine"])
    }

    func testEveryKindOfBadEditIsRejectedWithItsReason() {
        let segments = [seg("before it"), seg("the blend app and the app", flagged: true), seg("after it")]
        let proposed = [
            FixEdit(segment: 0, span: "before", replacement: "Before"),
            FixEdit(segment: 1, span: "Blender", replacement: "Blend"),
            FixEdit(segment: 1, span: "it the blend", replacement: "it, the Blend"),
            FixEdit(segment: 1, span: "app", replacement: "App"),
            FixEdit(segment: 1, span: "blend", replacement: "blend"),
            FixEdit(segment: 1, span: "blend", replacement: "Blend that I made last week"),
            FixEdit(segment: 1, span: "blend", replacement: "Blend\nApp"),
            FixEdit(segment: 1, span: "blend app", replacement: "Blend app"),
            FixEdit(segment: 1, span: "blend", replacement: "Blend"),
            FixEdit(segment: 7, span: "x", replacement: "y"),
            FixEdit(segment: 1, span: "", replacement: "y"),
        ]

        let edits = TargetedFix.validate(proposed, segments: segments, flagged: [1])

        XCTAssertEqual(edits.map(\.rejected), [.notFlagged, .noMatch, .outsideSegment, .ambiguous, .noChange,
                                               .addsWords, .addsWords, nil, .overlaps, .notFlagged, .noMatch])
        XCTAssertEqual(TargetedFix.apply(edits, to: segments)[1], "the Blend app and the app")
    }

    func testTwoEditsInOneSegmentBothLand() {
        let segments = [seg("send it to codex and claud now", flagged: true)]
        let proposed = [FixEdit(segment: 0, span: "claud", replacement: "Claude"),
                        FixEdit(segment: 0, span: "codex", replacement: "Codex")]

        let edits = TargetedFix.validate(proposed, segments: segments, flagged: [0])

        XCTAssertEqual(TargetedFix.apply(edits, to: segments), ["send it to Codex and Claude now"])
    }

    func testAnAnswerThatIsNotEditsIsAnError() {
        XCTAssertThrowsError(try TargetedFix.parse("Here is the fixed text."))
        XCTAssertThrowsError(try TargetedFix.parse("{\"text\": \"x\"}"))
        XCTAssertEqual(try TargetedFix.parse("{\"edits\": []}"), [])
    }

    func testAnEmptyKeyTermIsNone() throws {
        let edits = try TargetedFix.parse("""
            {"edits": [{"segment": 2, "span": "a", "replacement": "b", "key_term": ""},
                       {"segment": "3", "span": "c", "replacement": "d", "key_term": "Blend"}]}
            """)

        XCTAssertEqual(edits, [FixEdit(segment: 2, span: "a", replacement: "b"),
                               FixEdit(segment: 3, span: "c", replacement: "d", keyTerm: "Blend")])
    }
}

final class FixStepTests: StubbedOllamaTestCase {
    func testADictationWithNothingFlaggedNeverReachesOllama() async {
        StubOllama.install(.failure(.cannotConnectToHost))
        let called = Flag()

        let outcome = await Pipeline.fix(transcript([seg("all sure", -0.1, flagged: false), seg("yes", -0.2)]),
                                         settings: settings(terms: ["Claude"]), scope: .flagged,
                                         beforeOllama: { called.set() })

        XCTAssertFalse(outcome.askedOllama)
        XCTAssertFalse(called.value, "whisper must not unload when Ollama isn't asked")
        XCTAssertEqual(StubOllama.requests.count, 0)
        XCTAssertEqual(outcome.text, "all sure yes")
        XCTAssertEqual(outcome.seconds, 0)
        XCTAssertNil(outcome.error)
    }

    func testFlaggedSegmentsGoOutAsAStructuredRequestAndTheEditsComeBackApplied() async throws {
        StubOllama.install(.json(editsReply([
            ["segment": 1, "span": "Claud", "replacement": "Claude", "key_term": "Claude"],
            ["segment": 0, "span": "first", "replacement": "1st", "key_term": ""],
        ])))
        let called = Flag()

        let outcome = await Pipeline.fix(transcript([seg("the first one", flagged: false),
                                                     seg("ask Claud about it", -0.8, flagged: true)]),
                                         settings: settings(terms: ["Claude"]), scope: .flagged,
                                         beforeOllama: { called.set() })

        XCTAssertTrue(outcome.askedOllama)
        XCTAssertTrue(called.value)
        XCTAssertEqual(outcome.flagged, [1])
        XCTAssertEqual(outcome.text, "the first one ask Claude about it")
        XCTAssertEqual(outcome.edits.map(\.rejected), [nil, .notFlagged])
        let body = try XCTUnwrap(StubOllama.requests.first).json
        XCTAssertEqual(body["system"] as? String, TargetedFix.system)
        XCTAssertNotNil(body["format"] as? [String: Any])
        XCTAssertEqual(body["think"] as? Bool, false)
        let prompt = try XCTUnwrap(body["prompt"] as? String)
        XCTAssertTrue(prompt.contains("Text: ask Claud about it"))
        XCTAssertFalse(prompt.contains("Text: the first one"))
    }

    func testTheEveryScopeSendsSegmentsWhisperWasSureOf() async throws {
        StubOllama.install(.json(editsReply([
            ["segment": 0, "span": "Claud", "replacement": "Claude", "key_term": "Claude"],
        ])))

        let outcome = await Pipeline.fix(transcript([seg("ask Claud", -0.05, flagged: false), seg("about it", -0.1)]),
                                         settings: settings(terms: ["Claude"]), scope: .every)

        XCTAssertTrue(outcome.askedOllama)
        XCTAssertEqual(outcome.flagged, [0, 1])
        XCTAssertEqual(outcome.text, "ask Claude about it")
        XCTAssertEqual(outcome.edits.map(\.applied), [true])
        let prompt = try XCTUnwrap(StubOllama.requests.first?.json["prompt"] as? String)
        XCTAssertTrue(prompt.contains("Text: ask Claud"))
        XCTAssertTrue(prompt.contains("Text: about it"))
    }

    func testAFailedFixKeepsWhispersText() async {
        StubOllama.install(.failure(.cannotConnectToHost))

        let outcome = await Pipeline.fix(transcript([seg("ask Claud", -0.8, flagged: true)]),
                                         settings: settings(), scope: .flagged)

        XCTAssertTrue(outcome.askedOllama)
        XCTAssertEqual(outcome.text, "ask Claud")
        XCTAssertNotNil(outcome.error)
    }

    func testTheWholeScopeRewritesEverythingAsBefore() async {
        StubOllama.install(.json(["response": "All sure, yes.", "done": true]))

        let outcome = await Pipeline.fix(transcript([seg("all sure", flagged: false), seg("yes")]),
                                         settings: settings(), scope: .whole)

        XCTAssertTrue(outcome.askedOllama)
        XCTAssertEqual(outcome.text, "All sure, yes.")
        XCTAssertEqual(outcome.edits, [])
        XCTAssertEqual(StubOllama.requests.first?.json["format"] == nil, true)
    }
}

final class FixEditStoreTests: StoreTestCase {
    func testEveryEditIsStoredWithItsDictationAndReadBack() throws {
        var d = try dictation(mode: .fix, text: "ask Claud", segments: [segment("ask Claud")])
        d.finalText = "ask Claude"
        d.fixEdits = [FixEdit(segment: 0, span: "Claud", replacement: "Claude", keyTerm: "Claude", offset: 4),
                      FixEdit(segment: 0, span: "ask", replacement: "Ask", rejected: .ambiguous)]
        try store.insert(d)

        let read = try XCTUnwrap(try CallStore(url: databaseURL).dictation(d.id))

        XCTAssertEqual(read.fixEdits, d.fixEdits)
        XCTAssertEqual(read.mode, .fix)
        XCTAssertEqual(read.finalText, "ask Claude")
    }

    func testAFixWithNoEditsReadsAsEmptyAndAPlainDictationAsNone() throws {
        var fixed = try dictation(mode: .fix)
        fixed.fixEdits = []
        try store.insert(fixed)
        let plain = try dictation()
        try store.insert(plain)
        let calls = try CallStore(url: databaseURL)

        XCTAssertEqual(try calls.dictation(fixed.id)?.fixEdits, [])
        XCTAssertNil(try calls.dictation(plain.id)?.fixEdits)
    }

    func testEditsGoWithTheirDictation() throws {
        var old = try dictation(ageDays: 40, mode: .fix)
        old.fixEdits = [FixEdit(segment: 0, span: "hello", replacement: "Hello", offset: 0)]
        try store.insert(old)
        var kept = try dictation(mode: .fix)
        kept.fixEdits = old.fixEdits
        try store.insert(kept)
        var deleted = try dictation(mode: .fix)
        deleted.fixEdits = old.fixEdits
        try store.insert(deleted)

        store.prune(before: Date().addingTimeInterval(-30 * 24 * 3600))
        store.delete(deleted.id)

        XCTAssertEqual(count("SELECT count(*) FROM fix_edits"), 1)
        XCTAssertEqual(count("SELECT count(*) FROM fix_edits WHERE dictation_id = '\(kept.id)'"), 1)
    }

    func testReinsertingADictationReplacesItsEdits() throws {
        var d = try dictation(mode: .fix)
        d.fixEdits = [FixEdit(segment: 0, span: "hello", replacement: "Hello", offset: 0),
                      FixEdit(segment: 0, span: "x", replacement: "y", rejected: .noMatch)]
        try store.insert(d)
        d.fixEdits = [FixEdit(segment: 0, span: "world", replacement: "World", offset: 6)]
        try store.insert(d)

        XCTAssertEqual(count("SELECT count(*) FROM fix_edits WHERE dictation_id = '\(d.id)'"), 1)
    }
}

/// Set from a @Sendable closure, read after it ran.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set_ = false
    func set() { lock.withLock { set_ = true } }
    var value: Bool { lock.withLock { set_ } }
}
