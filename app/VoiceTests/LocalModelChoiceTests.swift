import VoiceCore
import XCTest

final class LocalModelChoiceTests: XCTestCase {
    private func defaults(_ values: [String: Any] = [:]) -> UserDefaults {
        let name = "model-choice-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        for (key, value) in values { defaults.set(value, forKey: key) }
        return defaults
    }

    func testNothingStoredFollowsTheMac() {
        XCTAssertEqual(LocalModelChoice.effective(defaults: defaults(), ollamaModel: "qwen3.5:9b", appleAvailable: true), .apple)
        XCTAssertEqual(LocalModelChoice.effective(defaults: defaults(), ollamaModel: "qwen3.5:9b", appleAvailable: false),
                       .ollama("qwen3.5:9b"))
    }

    func testAnOllamaSetupBeforeKeepsOllama() {
        XCTAssertFalse(LocalModelChoice.ollamaConfigured(in: defaults()))
        XCTAssertFalse(LocalModelChoice.ollamaConfigured(in: defaults(["runPrompt": false])))
        XCTAssertTrue(LocalModelChoice.ollamaConfigured(in: defaults(["runPrompt": true])))
        XCTAssertTrue(LocalModelChoice.ollamaConfigured(in: defaults(["ollamaModel": "llama3"])))
        XCTAssertEqual(LocalModelChoice.effective(defaults: defaults(["runPrompt": true]), ollamaModel: "qwen3.5:9b",
                                                  appleAvailable: true), .ollama("qwen3.5:9b"))
    }

    func testAPickWins() {
        XCTAssertEqual(LocalModelChoice.effective(defaults: defaults(["localModel": "apple", "ollamaModel": "x"]),
                                                  ollamaModel: "x", appleAvailable: false), .apple)
        XCTAssertEqual(LocalModelChoice.effective(defaults: defaults(["localModel": "ollama"]), ollamaModel: "x",
                                                  appleAvailable: true), .ollama("x"))
    }

    func testCanRun() {
        XCTAssertTrue(LocalModelChoice.canRun(.apple, appleAvailable: true, ollamaModels: nil))
        XCTAssertFalse(LocalModelChoice.canRun(.apple, appleAvailable: false, ollamaModels: ["a"]))
        XCTAssertTrue(LocalModelChoice.canRun(.ollama("a"), appleAvailable: false, ollamaModels: ["a:latest"]))
        XCTAssertFalse(LocalModelChoice.canRun(.ollama("a"), appleAvailable: true, ollamaModels: ["b"]))
        XCTAssertFalse(LocalModelChoice.canRun(.ollama("a"), appleAvailable: true, ollamaModels: nil))
    }

    func testTagsRoundTrip() {
        for model in [LocalModel.apple, .ollama("qwen3.5:9b")] {
            XCTAssertEqual(LocalModelChoice.model(tag: LocalModelChoice.tag(model)), model)
        }
        XCTAssertNil(LocalModelChoice.model(tag: "other"))
    }

    func testTheGateIgnoresACallAppInACall() {
        XCTAssertTrue(TitleGate.mayAsk(Activity(callAppInCall: true)))
        XCTAssertFalse(TitleGate.mayAsk(Activity(dictationRecording: true)))
        XCTAssertFalse(TitleGate.mayAsk(Activity(dictationTranscribing: true)))
        XCTAssertFalse(TitleGate.mayAsk(Activity(fixing: true)))
        XCTAssertFalse(TitleGate.mayAsk(Activity(callRecording: true)))
        XCTAssertFalse(TitleGate.mayAsk(Activity(callTranscribing: true)))
    }

    @MainActor
    func testWaitingEndsWhenQuietOrAtTheTimeout() async {
        var busy = 3
        let quiet = await TitleGate.waitUntilQuiet(activity: {
            busy -= 1
            return Activity(fixing: busy > 0)
        }, timeout: .seconds(5), poll: .milliseconds(1))
        XCTAssertTrue(quiet)
        let gaveUp = await TitleGate.waitUntilQuiet(activity: { Activity(callRecording: true) },
                                                    timeout: .milliseconds(20), poll: .milliseconds(5))
        XCTAssertFalse(gaveUp)
    }
}
