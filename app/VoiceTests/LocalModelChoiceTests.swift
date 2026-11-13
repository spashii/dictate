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

    private func effective(stored: LocalModel? = nil, configured: Bool = false) -> LocalModel {
        LocalModelChoice.effective(stored: stored, ollamaConfigured: configured, ollamaModel: "qwen3.5:9b")
    }

    func testNothingStoredIsApple() {
        XCTAssertEqual(effective(), .apple)
    }

    func testExplicitPicksWinBothWays() {
        XCTAssertEqual(effective(stored: .apple, configured: true), .apple)
        XCTAssertEqual(effective(stored: .ollama("x")), .ollama("qwen3.5:9b"))
    }

    func testAnOllamaSetupBeforeKeepsOllama() {
        XCTAssertFalse(LocalModelChoice.ollamaConfigured(in: defaults()))
        XCTAssertFalse(LocalModelChoice.ollamaConfigured(in: defaults(["runPrompt": false])))
        XCTAssertTrue(LocalModelChoice.ollamaConfigured(in: defaults(["runPrompt": true])))
        XCTAssertTrue(LocalModelChoice.ollamaConfigured(in: defaults(["ollamaModel": "llama3"])))
        XCTAssertEqual(effective(configured: true), .ollama("qwen3.5:9b"))
    }

    func testTurningOnTheFixLaterDoesNotMoveAFreshInstallToOllama() {
        let store = defaults()
        XCTAssertFalse(LocalModelChoice.ollamaConfigured(in: store))
        XCTAssertEqual(effective(configured: LocalModelChoice.ollamaConfigured(in: store)), .apple)

        store.set(true, forKey: "runPrompt")
        store.set("llama3", forKey: "ollamaModel")

        let configured = LocalModelChoice.ollamaConfigured(in: store)
        XCTAssertFalse(configured)
        XCTAssertEqual(effective(configured: configured), .apple)
    }

    func testAnInstallThatHadTheFixOnKeepsOllamaWhateverHappensAfter() {
        let store = defaults(["runPrompt": true])
        XCTAssertTrue(LocalModelChoice.ollamaConfigured(in: store))
        store.set(false, forKey: "runPrompt")
        XCTAssertTrue(LocalModelChoice.ollamaConfigured(in: store))
        XCTAssertEqual(effective(configured: true), .ollama("qwen3.5:9b"))
    }

    private func keepOllama(_ values: [String: Any], apple: AppleModelState) -> UserDefaults {
        let store = defaults(values)
        LocalModelChoice.keepOllamaInUse(in: store, appleState: apple)
        return store
    }

    func testAFreshInstallStoresNothingAndSetsTheGuard() {
        let store = keepOllama([:], apple: .turnedOff)
        XCTAssertNil(store.object(forKey: "localModel"))
        XCTAssertTrue(store.bool(forKey: "intelligenceDefaultChecked"))
    }

    func testTheFixOnOllamaWithoutAppleKeepsOllama() {
        let store = keepOllama(["runPrompt": true, "ollamaConfiguredBefore": false], apple: .turnedOff)
        XCTAssertEqual(store.string(forKey: "localModel"), "ollama")
    }

    func testAnAvailableAppleOrAFixTurnedOffKeepsNothing() {
        XCTAssertNil(keepOllama(["runPrompt": true, "ollamaConfiguredBefore": false], apple: .available).object(forKey: "localModel"))
        XCTAssertNil(keepOllama(["runPrompt": false, "ollamaConfiguredBefore": false], apple: .turnedOff).object(forKey: "localModel"))
        XCTAssertNil(keepOllama(["runPrompt": true, "ollamaConfiguredBefore": false], apple: .notReady).object(forKey: "localModel"))
        XCTAssertNil(keepOllama(["runPrompt": true, "ollamaConfiguredBefore": true], apple: .turnedOff).object(forKey: "localModel"))
    }

    func testAStoredPickIsLeftAlone() {
        let store = keepOllama(["runPrompt": true, "ollamaConfiguredBefore": false, "localModel": "apple"], apple: .turnedOff)
        XCTAssertEqual(store.string(forKey: "localModel"), "apple")
    }

    func testTheRuleRunsOnOneLaunchOnly() {
        let store = keepOllama([:], apple: .turnedOff)
        store.set(true, forKey: "runPrompt")
        store.set(false, forKey: "ollamaConfiguredBefore")
        LocalModelChoice.keepOllamaInUse(in: store, appleState: .turnedOff)
        XCTAssertNil(store.object(forKey: "localModel"))
    }

    func testTitlesAreOnUnlessChosenOff() {
        XCTAssertTrue(TitleCallsDefault.load(from: defaults()))
        XCTAssertTrue(TitleCallsDefault.load(from: defaults(["titleCalls": false])))
        XCTAssertFalse(TitleCallsDefault.load(from: defaults(["titleCalls": false, "titleCallsChosen": true])))
        XCTAssertTrue(TitleCallsDefault.load(from: defaults(["titleCalls": true, "titleCallsChosen": true])))
    }

    func testSavingTitlesWritesTheMarker() {
        let store = defaults()
        TitleCallsDefault.save(false, to: store)
        XCTAssertFalse(TitleCallsDefault.load(from: store))
        TitleCallsDefault.save(true, to: store)
        XCTAssertTrue(TitleCallsDefault.load(from: store))
    }

    private func options(_ apple: AppleModelState = .available, current: LocalModel = .apple,
                         ollama: [String]? = ["a", "b"], stored: String = "a") -> LocalModelChoice.Options {
        LocalModelChoice.pickerOptions(apple: apple, current: current, ollamaModels: ollama, ollamaModel: stored)
    }

    func testOllamaDownWithAppleAvailableListsOneStoppedEntry() {
        let result = options(ollama: nil, stored: "qwen3.5:9b")
        XCTAssertEqual(result.apple.title, "Apple Intelligence")
        XCTAssertEqual(result.ollama.map(\.title), ["qwen3.5:9b (Ollama is not running)"])
        XCTAssertEqual(result.ollama.map(\.model), [.ollama("qwen3.5:9b")])
    }

    func testAppleTitlesSayWhy() {
        XCTAssertEqual(options(.turnedOff).apple.title, "Apple Intelligence (turn it on in System Settings)")
        XCTAssertEqual(options(.notReady).apple.title, "Apple Intelligence (not ready yet)")
        XCTAssertEqual(options(.unsupported).apple.title, "Apple Intelligence (not available on this Mac)")
        XCTAssertEqual(options(.needsNewerMacOS).apple.title, "Apple Intelligence (needs macOS 26)")
        XCTAssertEqual(options(.needsNewerMacOS).apple.model, .apple)
    }

    func testACurrentOllamaPickNamesTheStoppedModel() {
        let result = options(current: .ollama("x"), ollama: nil, stored: "y")
        XCTAssertEqual(result.ollama.map(\.title), ["x (Ollama is not running)"])
        XCTAssertEqual(result.ollama.map(\.model), [.ollama("x")])
    }

    func testAMissingStoredModelIsListedAsNotInstalled() {
        let result = options(ollama: ["b"], stored: "a")
        XCTAssertEqual(result.ollama.map(\.title), ["b", "a (not installed)"])
        XCTAssertEqual(options(ollama: ["a:latest"], stored: "a").ollama.map(\.title), ["a:latest"])
    }

    func testAnEntryMatchedThroughLatestCarriesTheStoredNameForTheTag() {
        let entry = options(ollama: ["llama3:latest", "b"], stored: "llama3").ollama[0]
        XCTAssertEqual(entry.title, "llama3:latest")
        XCTAssertEqual(LocalModelChoice.tag(entry.model), LocalModelChoice.tag(.ollama("llama3")))
    }

    func testThePickerNeverComesBackEmpty() {
        for apple in [AppleModelState.available, .turnedOff, .notReady, .unsupported, .needsNewerMacOS] {
            for running in [nil, [], ["a"]] as [[String]?] {
                let result = options(apple, ollama: running)
                XCTAssertFalse(result.apple.title.isEmpty)
                XCTAssertFalse(result.ollama.isEmpty)
            }
        }
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

    func testNoModelCanRunNeedsBothToBeOut() {
        XCTAssertTrue(LocalModelChoice.noModelCanRun(apple: .turnedOff, ollamaModels: nil))
        XCTAssertTrue(LocalModelChoice.noModelCanRun(apple: .unsupported, ollamaModels: []))
        XCTAssertFalse(LocalModelChoice.noModelCanRun(apple: .available, ollamaModels: nil))
        XCTAssertFalse(LocalModelChoice.noModelCanRun(apple: .notReady, ollamaModels: ["qwen3.5:9b"]))
    }

    func testNoModelHintByState() {
        XCTAssertEqual(LocalModelChoice.noModelHint(apple: .turnedOff, ollamaModels: nil), "Start Ollama or turn on Apple Intelligence.")
        XCTAssertEqual(LocalModelChoice.noModelHint(apple: .turnedOff, ollamaModels: []), "Add a model in Ollama or turn on Apple Intelligence.")
        XCTAssertEqual(LocalModelChoice.noModelHint(apple: .notReady, ollamaModels: nil), "Apple Intelligence is still getting ready.")
        XCTAssertEqual(LocalModelChoice.noModelHint(apple: .unsupported, ollamaModels: nil), "Start Ollama to fix text and title calls.")
        XCTAssertEqual(LocalModelChoice.noModelHint(apple: .needsNewerMacOS, ollamaModels: []), "Add a model in Ollama to fix text and title calls.")
    }
}
