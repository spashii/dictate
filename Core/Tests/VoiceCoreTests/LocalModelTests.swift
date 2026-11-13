import Foundation
import Testing
@testable import VoiceCore

@Suite struct LocalModelTests {
    @Test(arguments: [
        // stored, ollamaConfigured, expected
        ("apple", false, LocalModel.apple),
        ("apple", true, .apple),
        ("ollama", false, .ollama("qwen3.5:9b")),
        ("ollama", true, .ollama("qwen3.5:9b")),
        (nil, true, .ollama("qwen3.5:9b")),
        (nil, false, .apple),
        ("unknown", false, .apple),
        ("unknown", true, .ollama("qwen3.5:9b")),
    ] as [(String?, Bool, LocalModel)])
    func resolves(stored: String?, configured: Bool, expected: LocalModel) {
        #expect(LocalModel.resolve(stored: stored, ollamaConfigured: configured, fixModel: "qwen3.5:9b") == expected)
    }

    @Test func storedValuesRoundTripThroughTheResolver() {
        #expect(LocalModel.apple.storedValue == "apple")
        #expect(LocalModel.ollama("x").storedValue == "ollama")
        for choice in [LocalModel.apple, .ollama("m")] {
            #expect(LocalModel.resolve(stored: choice.storedValue, ollamaConfigured: false, fixModel: "m") == choice)
        }
    }

    @Test func theAppleEditorIsTheOneAvailabilityPicks() {
        // An editor that works exactly when the model is available, so the two never disagree.
        let editor = FixEditors.editor(for: CleanupSettings(engine: .apple))
        #expect((editor is UnavailableFixEditor) == !AppleModel.isAvailable)
        #expect(!editor.unloadsWhisper)
    }
}

@Suite struct CleanupSettingsEngineTests {
    @Test func dataSavedBeforeTheEngineExistedMeansOllama() throws {
        let old = """
            {"ollamaURL":"http://127.0.0.1:11434","model":"qwen3.5:9b","prompt":"p","keyTerms":["Alex"],"temperature":0.2}
            """
        let settings = try JSONDecoder().decode(CleanupSettings.self, from: Data(old.utf8))
        #expect(settings.engine == .ollama)
        #expect(settings.modelName == "qwen3.5:9b")
        #expect(settings.keyTerms == ["Alex"])
    }

    @Test func appleRoundTripsAndNamesItselfOnTheDictation() throws {
        let settings = CleanupSettings(engine: .apple, keyTerms: ["Northwind"])
        let back = try JSONDecoder().decode(CleanupSettings.self, from: JSONEncoder().encode(settings))
        #expect(back == settings)
        #expect(back.engine == .apple)
        #expect(back.modelName == "apple-on-device")
    }
}

private func seg(_ text: String) -> Segment {
    Segment(t0: 0, t1: 1, text: text, avgLogprob: -0.1, noSpeechProb: 0, compressionRatio: 1,
            speechSeconds: 1, wordsPerSecond: 2)
}

private func transcript(_ texts: [String]) -> Transcript {
    let segments = texts.map(seg)
    return Transcript(text: TargetedFix.join(texts), segments: segments, seconds: 1)
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

private struct FakeEditor: FixEditor {
    enum Failure: Error { case failed }
    var unloadsWhisper: Bool
    var proposed: [FixEdit] = []
    var fails = false
    var rewritten = ""

    func edits(_ segments: [Segment], flagged: [Int], settings: CleanupSettings) async throws -> [FixEdit] {
        if fails { throw Failure.failed }
        return proposed
    }

    func rewrite(_ text: String, settings: CleanupSettings) async throws -> String {
        if fails { throw Failure.failed }
        return rewritten
    }
}

@Suite struct AppleFixTests {
    let apple = CleanupSettings(engine: .apple, keyTerms: ["Northwind"])

    @Test func validEditsAreApplied() async {
        let editor = FakeEditor(unloadsWhisper: false, proposed: [
            FixEdit(segment: 1, span: "North wind", replacement: "Northwind", keyTerm: "Northwind")])

        let outcome = await Pipeline.fix(transcript(["call Alex", "about North wind today"]), settings: apple,
                                         scope: .every, editor: editor)

        #expect(outcome.text == "call Alex about Northwind today")
        #expect(outcome.edits.map(\.applied) == [true])
        #expect(outcome.askedOllama)
        #expect(outcome.error == nil)
    }

    @Test func invalidEditsAreRejectedAsBefore() async {
        let editor = FakeEditor(unloadsWhisper: false, proposed: [
            FixEdit(segment: 5, span: "x", replacement: "y"),
            FixEdit(segment: 0, span: "missing", replacement: "y"),
            FixEdit(segment: 0, span: "Alex", replacement: "Alex"),
        ])

        let outcome = await Pipeline.fix(transcript(["call Alex"]), settings: apple, scope: .every, editor: editor)

        #expect(outcome.edits.map(\.rejected) == [.notFlagged, .noMatch, .noChange])
        #expect(outcome.text == "call Alex")
    }

    @Test func aThrownErrorKeepsWhispersTextWithTheError() async {
        let editor = FakeEditor(unloadsWhisper: false, fails: true)

        let outcome = await Pipeline.fix(transcript(["call Alex"]), settings: apple, scope: .every, editor: editor)

        #expect(outcome.text == "call Alex")
        #expect(outcome.edits.isEmpty)
        #expect(outcome.error != nil)
    }

    @Test func theWholeScopeCanUsePlainText() async {
        let editor = FakeEditor(unloadsWhisper: false, rewritten: "Call Alex.")

        let outcome = await Pipeline.fix(transcript(["call Alex"]), settings: apple, scope: .whole, editor: editor)

        #expect(outcome.text == "Call Alex.")
    }

    @Test func whisperUnloadsForOllamaOnlyButTheStageChangesForBoth() async {
        for (unloads, expected) in [(false, ["model"]), (true, ["ollama", "model"])] {
            let calls = Calls()
            let editor = FakeEditor(unloadsWhisper: unloads)

            _ = await Pipeline.fix(transcript(["call Alex"]), settings: apple, scope: .every, editor: editor,
                                   beforeOllama: { calls.add("ollama") }, beforeModel: { calls.add("model") })

            #expect(calls.all == expected)
        }
    }

    @Test func noHookRunsWhenNothingIsSent() async {
        let calls = Calls()

        _ = await Pipeline.fix(transcript([""]), settings: apple, scope: .every,
                               editor: FakeEditor(unloadsWhisper: true),
                               beforeOllama: { calls.add("ollama") }, beforeModel: { calls.add("model") })

        #expect(calls.all == [])
    }

    @Test func theDefaultEditorFollowsTheEngine() {
        #expect(FixEditors.editor(for: CleanupSettings()).unloadsWhisper)
        #expect(!FixEditors.editor(for: apple).unloadsWhisper)
    }

    @Test func appleChosenButUnavailableFailsLikeAStoppedOllama() async throws {
        let outcome = await Pipeline.fix(transcript(["call Alex"]), settings: apple, scope: .every,
                                         editor: UnavailableFixEditor(state: .turnedOff))

        #expect(outcome.text == "call Alex")
        #expect(outcome.error?.contains("turned off in System Settings") == true)
    }

    @Test func theUnavailableReasonNamesWhatToChange() {
        #expect(UnavailableFixEditor(state: .notReady).reason == "Apple Intelligence isn't ready yet.")
        #expect(UnavailableFixEditor(state: .unsupported).reason == "Apple Intelligence isn't available on this Mac.")
        #expect(UnavailableFixEditor(state: .needsNewerMacOS).reason == "Apple Intelligence needs macOS 26.")
    }
}
