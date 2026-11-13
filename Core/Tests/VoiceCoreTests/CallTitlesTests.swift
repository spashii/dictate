import Foundation
import Testing
@testable import VoiceCore

@Suite struct CallTitlesTests {
    @Test(arguments: [
        ("Northwind rollout with Alex", "Northwind rollout with Alex"),
        ("\"Northwind rollout with Alex\"", "Northwind rollout with Alex"),
        ("\u{201C}Northwind rollout with Alex\u{201D}", "Northwind rollout with Alex"),
        ("\u{2018}Lakeside kickoff\u{2019}", "Lakeside kickoff"),
        ("`Lakeside kickoff`", "Lakeside kickoff"),
        ("Title: Lakeside kickoff", "Lakeside kickoff"),
        ("title: \"Lakeside kickoff\"", "Lakeside kickoff"),
        ("**Title:** Lakeside kickoff", "Lakeside kickoff"),
        ("**Lakeside kickoff**", "Lakeside kickoff"),
        ("# Lakeside kickoff", "Lakeside kickoff"),
        ("- Lakeside kickoff", "Lakeside kickoff"),
        ("Lakeside kickoff.", "Lakeside kickoff"),
        ("Lakeside kickoff...", "Lakeside kickoff"),
        ("Lakeside kickoff\u{2026}", "Lakeside kickoff"),
        ("Lakeside kickoff?", "Lakeside kickoff"),
        ("\"Lakeside kickoff.\"", "Lakeside kickoff"),
        ("  Lakeside   kickoff \n", "Lakeside kickoff"),
        ("<think>hmm, what is this about</think>\nLakeside kickoff", "Lakeside kickoff"),
        ("<think>never closed\nLakeside kickoff", nil),
        ("\nLakeside kickoff\nThis call was about the kickoff.", "Lakeside kickoff"),
        ("Planung des Northwind-Rollouts mit Alex", "Planung des Northwind-Rollouts mit Alex"),
        ("Rollout planning for Northwind with Alex and the whole team today", nil),
        ("one two three four five six seven eight nine ten eleven", nil),
        (String(repeating: "abcdefghi ", count: 8) + "abcdefghi", nil),
        ("Sorry, I can't help with that", nil),
        ("I'm sorry but there is no content", nil),
        ("I\u{2019}m sorry, nothing here", nil),
        ("I cannot title this", nil),
        ("As an AI, I do not know", nil),
        ("", nil),
        ("   \n  ", nil),
        ("...", nil),
        ("\"\"", nil),
        ("123 456", nil),
        ("Here is a title:\nLakeside kickoff", "Lakeside kickoff"),
        ("Here's a title for this call:\n\n\"Lakeside kickoff\"", "Lakeside kickoff"),
        ("Here\u{2019}s a title for this call:\nLakeside kickoff", "Lakeside kickoff"),
        ("Here is the title\nLakeside kickoff", "Lakeside kickoff"),
        ("Sure, here you go:\nLakeside kickoff", "Lakeside kickoff"),
        ("Here is a title:", nil),
    ] as [(String, String?)])
    func sanitize(raw: String, expected: String?) {
        #expect(CallTitles.sanitize(raw) == expected)
    }

    private func segment(_ id: Int64, _ channel: CallSegment.Channel, _ ms: Int, _ text: String) -> CallSegment {
        CallSegment(id: id, callID: "c", channel: channel, startMs: ms, endMs: ms + 1000, text: text,
                    createdAt: Date(timeIntervalSince1970: 0))
    }

    private let sentence = "We should plan the Northwind rollout with Alex before the end of the month."

    @Test func shortTranscriptsGetNoExcerpt() {
        #expect(CallTitles.excerpt([segment(1, .me, 0, "Hello, can you hear me")], speakers: nil) == nil)
        #expect(CallTitles.excerpt([], speakers: nil) == nil)
        // Eleven words is still too little, twelve is enough.
        #expect(CallTitles.excerpt([segment(1, .me, 0, "one two three four five six seven eight nine ten eleven")], speakers: nil) == nil)
        #expect(CallTitles.excerpt([segment(1, .me, 0, "one two three four five six seven eight nine ten eleven twelve")], speakers: nil) != nil)
    }

    @Test func linesAreLabeledInTimeOrderWithoutTimestamps() {
        let excerpt = CallTitles.excerpt([
            segment(2, .call, 5000, "Yes, the Lakeside budget is approved for the full year."),
            segment(1, .me, 0, sentence),
        ], speakers: nil)
        #expect(excerpt == "Me: \(sentence)\nCall: Yes, the Lakeside budget is approved for the full year.")
    }

    @Test func twoSpeakerCallsUseTheirNamesAndMixedAudioHasNoLabel() {
        let named = CallTitles.excerpt([
            segment(1, .me, 0, sentence),
            segment(2, .call, 5000, "Yes, the Lakeside budget is approved for the full year."),
        ], speakers: ["Sam", "Alex"])
        #expect(named?.hasPrefix("Sam: We should") == true)
        #expect(named?.contains("\nAlex: Yes") == true)
        let mixed = CallTitles.excerpt([segment(1, .mix, 0, sentence)], speakers: nil)
        #expect(mixed == sentence)
    }

    @Test func aLongTranscriptKeepsItsStartAndEnd() throws {
        var segments: [CallSegment] = []
        for i in 0..<200 {
            let marker = i == 0 ? "FIRSTLINE " : i == 199 ? "LASTLINE " : ""
            segments.append(segment(Int64(i + 1), i % 2 == 0 ? .me : .call, i * 1000, marker + sentence + " Line \(i)."))
        }
        let excerpt = try #require(CallTitles.excerpt(segments, speakers: nil))
        let lines = excerpt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(excerpt.count <= 6000 + 8)
        #expect(lines.first?.contains("FIRSTLINE") == true)
        #expect(lines.last?.contains("LASTLINE") == true)
        #expect(lines.filter { $0 == "[...]" }.count == 1)
        #expect(lines.contains { $0.hasSuffix("Line 100.") } == false)
        // Cut at line boundaries: every line is a whole one.
        #expect(lines.allSatisfy { $0 == "[...]" || $0.hasPrefix("Me: ") || $0.hasPrefix("Call: ") })
    }

    @Test func nonLatinTextGetsASmallerBudgetSplitTwoToOne() throws {
        #expect(CallTitles.Budget.nonLatin.head == 1333 && CallTitles.Budget.nonLatin.tail == 667)
        #expect(CallTitles.budget(for: "Northwind rollout met Alex") == .latin)
        #expect(CallTitles.budget(for: "Plan für Östergötland, café déjà vu") == .latin)
        #expect(CallTitles.budget(for: "我们讨论了北风项目的上线计划 and a word") == .nonLatin)

        var segments: [CallSegment] = []
        for i in 0..<120 {
            let marker = i == 0 ? "开始 " : i == 119 ? "结束 " : ""
            segments.append(segment(Int64(i + 1), i % 2 == 0 ? .me : .call, i * 1000,
                                    marker + "我们需要和亚历克斯一起规划北风项目本月的上线计划,第\(i)行。"))
        }
        let excerpt = try #require(CallTitles.excerpt(segments, speakers: nil))
        let lines = excerpt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(excerpt.count <= 2000 + 8)
        #expect(lines.first?.contains("开始") == true)
        #expect(lines.last?.contains("结束") == true)
        #expect(lines.filter { $0 == "[...]" }.count == 1)
    }

    @Test func aSingleHugeLineIsStillCut() throws {
        let huge = String(repeating: "word ", count: 3000)
        let excerpt = try #require(CallTitles.excerpt([segment(1, .mix, 0, huge)], speakers: nil))
        #expect(excerpt.count < 6100)
        #expect(excerpt.contains("[...]"))
    }

    @Test func theOllamaBodyIsSmallAndNotThinking() throws {
        let body = OllamaTitleModel.body(model: "qwen3.5:9b", instructions: "inst", prompt: "Transcript:\nx")
        #expect(body["model"] as? String == "qwen3.5:9b")
        #expect(body["system"] as? String == "inst")
        #expect(body["prompt"] as? String == "Transcript:\nx")
        #expect(body["think"] as? Bool == false)
        #expect(body["stream"] as? Bool == false)
        #expect(body["keep_alive"] as? String == "2m")
        let options = try #require(body["options"] as? [String: Any])
        #expect(options["temperature"] as? Double == 0.2)
        #expect(options["num_ctx"] == nil)
        #expect(options["num_predict"] as? Int == 32)
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test func titlingUsesTheChosenModelOnly() {
        let url = URL(string: "http://127.0.0.1:11434")!
        func names(_ choice: LocalModel, apple: Bool, _ installed: [String]?) -> [String] {
            CallTitles.models(choice: choice, appleAvailable: apple, ollamaModels: installed, ollamaURL: url).map(\.name)
        }
        let qwen = LocalModel.ollama("qwen3.5:9b")
        #expect(names(qwen, apple: false, nil) == [])
        #expect(names(qwen, apple: false, ["llama3:8b"]) == [])
        #expect(names(qwen, apple: false, ["qwen3.5:9b", "other"]) == ["ollama"])
        #expect(names(.ollama("qwen3.5"), apple: false, ["qwen3.5:latest"]) == ["ollama"])
        // No cross fallback: Ollama chosen and Apple available still means Ollama only.
        #expect(names(qwen, apple: true, ["qwen3.5:9b"]) == ["ollama"])
        #expect(names(qwen, apple: true, nil) == [])
        // Apple chosen but unavailable gives no model, even with Ollama installed.
        #expect(names(.apple, apple: false, ["qwen3.5:9b"]) == [])
        #expect(CallTitles.contains(["qwen3.5:latest"], "qwen3.5"))
        // Apple's model needs macOS 26 as well as the fact; the test host may be older.
        let apple = names(.apple, apple: true, ["qwen3.5:9b"])
        if #available(macOS 26, *) { #expect(apple == ["apple"]) } else { #expect(apple == []) }
    }
}

private struct FakeModel: TitleModel {
    enum Failure: Error { case failed }
    let name: String
    let answer: @Sendable () async throws -> String
    let asked = AskCount()

    func title(instructions: String, prompt: String) async throws -> String {
        asked.add()
        return try await answer()
    }
}

private final class AskCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite struct CallTitlerTests {
    private let speech = [
        NewCallSegment(channel: .me, startMs: 0, endMs: 4000, text: "We should plan the Northwind rollout with Alex this month."),
        NewCallSegment(channel: .call, startMs: 4000, endMs: 8000, text: "Agreed, Lakeside needs the new schedule by Friday afternoon."),
    ]

    private func call(title: String? = nil, source: TitleSource? = nil, segments: Bool = true) throws -> (CallStore, Call) {
        let store = try CallStore(url: temporaryCallDatabase())
        let created = try store.createCall(NewCall(split: true, title: title, titleSource: source ?? (title == nil ? nil : .user)))
        if segments { try store.appendSegments(created.id, speech) }
        return (store, created)
    }

    @Test func noModelsLeavesTheCallUntitled() async throws {
        let (store, created) = try call()
        #expect(await CallTitler().title(created.id, in: store, models: []) == nil)
        let read = try #require(try store.call(created.id))
        #expect(read.title == nil && read.titleSource == nil)
    }

    @Test func theFirstGoodAnswerIsStoredAsAuto() async throws {
        let (store, created) = try call()
        let model = FakeModel(name: "a") { "\"Northwind rollout with Alex.\"" }
        let title = await CallTitler().title(created.id, in: store, models: [model])
        #expect(title == "Northwind rollout with Alex")
        let read = try #require(try store.call(created.id))
        #expect(read.title == "Northwind rollout with Alex" && read.titleSource == .auto)
    }

    @Test func aThrowingModelFallsThroughToTheNext() async throws {
        let (store, created) = try call()
        let first = FakeModel(name: "a") { throw FakeModel.Failure.failed }
        let second = FakeModel(name: "b") { "Lakeside schedule" }
        #expect(await CallTitler().title(created.id, in: store, models: [first, second]) == "Lakeside schedule")
        #expect(first.asked.count == 1 && second.asked.count == 1)
    }

    @Test func junkCountsAsAFailure() async throws {
        let (store, created) = try call()
        let first = FakeModel(name: "a") { "Sorry, I can't help with that." }
        let second = FakeModel(name: "b") { "Lakeside schedule" }
        #expect(await CallTitler().title(created.id, in: store, models: [first, second]) == "Lakeside schedule")
    }

    @Test func nothingUsableLeavesTheCallUntitled() async throws {
        let (store, created) = try call()
        let first = FakeModel(name: "a") { throw FakeModel.Failure.failed }
        let second = FakeModel(name: "b") { "" }
        #expect(await CallTitler().title(created.id, in: store, models: [first, second]) == nil)
        #expect(try store.call(created.id)?.title == nil)
    }

    @Test func aTooShortCallAsksNoModel() async throws {
        let store = try CallStore(url: temporaryCallDatabase())
        let created = try store.createCall(NewCall(split: true))
        try store.appendSegments(created.id, [NewCallSegment(channel: .me, startMs: 0, endMs: 1000, text: "Hello there")])
        let model = FakeModel(name: "a") { "Greeting" }
        #expect(await CallTitler().title(created.id, in: store, models: [model]) == nil)
        #expect(model.asked.count == 0)
    }

    @Test func aTitledCallIsNeverAskedAbout() async throws {
        for source in [TitleSource.user, .agent, .auto] {
            let (store, created) = try call(title: "Lakeside kickoff", source: source)
            let model = FakeModel(name: "a") { "Something else" }
            #expect(await CallTitler().title(created.id, in: store, models: [model]) == nil)
            #expect(model.asked.count == 0)
            #expect(try store.call(created.id)?.title == "Lakeside kickoff")
        }
    }

    @Test func aClearedTitleStaysCleared() async throws {
        let (store, created) = try call()
        try store.rename(.call, created.id, to: "Temporary")
        try store.rename(.call, created.id, to: nil)
        let model = FakeModel(name: "a") { "Something else" }
        #expect(await CallTitler().title(created.id, in: store, models: [model]) == nil)
        #expect(model.asked.count == 0)
        #expect(try store.call(created.id)?.title == nil)
    }

    @Test func aPersonRenamingWhileTheModelAnswersWins() async throws {
        let (store, created) = try call()
        let id = created.id
        let model = FakeModel(name: "a") {
            try store.rename(.call, id, to: "Alex's own name")
            return "Northwind rollout with Alex"
        }
        #expect(await CallTitler().title(id, in: store, models: [model]) == nil)
        let read = try #require(try store.call(id))
        #expect(read.title == "Alex's own name" && read.titleSource == .user)
    }

    @Test func aMissingCallIsNil() async throws {
        let store = try CallStore(url: temporaryCallDatabase())
        let model = FakeModel(name: "a") { "Title here" }
        #expect(await CallTitler().title("nope", in: store, models: [model]) == nil)
        #expect(model.asked.count == 0)
    }
}
