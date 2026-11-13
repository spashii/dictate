import Foundation
import VoiceCore

/// The facts the app feeds VoiceCore's `LocalModel.resolve`, and what the choice means for
/// the fix step and for titling. Kept apart from Preferences so it can be tested without the
/// app's global state.
enum LocalModelChoice {
    static let configuredKey = "ollamaConfiguredBefore"

    /// Whether Ollama was set up before this version: the fix turned on, or a model picked.
    /// Worked out once, on the first launch that finds no answer stored, and kept under its
    /// own key. Read live it would flip a fresh install that defaults to Apple over to Ollama
    /// the moment the person turns the fix on.
    @discardableResult
    static func ollamaConfigured(in defaults: UserDefaults = .standard) -> Bool {
        if let stored = defaults.object(forKey: configuredKey) as? Bool { return stored }
        let configured = defaults.bool(forKey: "runPrompt") || defaults.object(forKey: "ollamaModel") != nil
        defaults.set(configured, forKey: configuredKey)
        return configured
    }

    static let intelligenceCheckedKey = "intelligenceDefaultChecked"

    /// Runs on one launch only. Someone whose fix ran on Ollama because Apple's model wasn't
    /// there would otherwise find it failing once the default became Apple's, so Ollama is
    /// stored for them.
    static func keepOllamaInUse(in defaults: UserDefaults, appleState: AppleModelState) {
        guard !defaults.bool(forKey: intelligenceCheckedKey) else { return }
        defaults.set(true, forKey: intelligenceCheckedKey)
        let usedOllamaForTheFix = defaults.bool(forKey: "runPrompt")
            && (defaults.object(forKey: configuredKey) as? Bool) == false
        if defaults.object(forKey: "localModel") == nil, usedOllamaForTheFix,
           appleState != .available, appleState != .notReady {
            defaults.set("ollama", forKey: "localModel")
        }
    }

    /// The model in use from the observed pick, not from what is stored, so a pick in Settings
    /// shows at once.
    static func effective(stored: LocalModel?, ollamaConfigured: Bool, ollamaModel: String) -> LocalModel {
        LocalModel.resolve(stored: stored?.storedValue, ollamaConfigured: ollamaConfigured, fixModel: ollamaModel)
    }

    /// What the model picker lists: Apple's entry first, then the Ollama ones, with a divider
    /// between the two groups. Never empty, so the person always sees both choices and why one
    /// may not work.
    struct Options {
        struct Entry: Hashable {
            var title: String
            var model: LocalModel
        }
        var apple: Entry
        var ollama: [Entry]
    }

    static func pickerOptions(apple: AppleModelState, current: LocalModel, ollamaModels: [String]?,
                              ollamaModel: String) -> Options {
        let appleTitle: String
        switch apple {
        case .available: appleTitle = "Apple Intelligence"
        case .turnedOff: appleTitle = "Apple Intelligence (turn it on in System Settings)"
        case .notReady: appleTitle = "Apple Intelligence (not ready yet)"
        case .unsupported: appleTitle = "Apple Intelligence (not available on this Mac)"
        case .needsNewerMacOS: appleTitle = "Apple Intelligence (needs macOS 26)"
        }
        var options = Options(apple: .init(title: appleTitle, model: .apple), ollama: [])
        if let models = ollamaModels {
            // The entry matching the stored name only through ":latest" takes the stored name, so
            // the picker's selection tag finds it.
            options.ollama = models.map { name in
                let isStored = name == ollamaModel || name == ollamaModel + ":latest"
                return .init(title: name, model: .ollama(isStored ? ollamaModel : name))
            }
            if !CallTitles.contains(models, ollamaModel) {
                options.ollama.append(.init(title: "\(ollamaModel) (not installed)", model: .ollama(ollamaModel)))
            }
        } else {
            var name = ollamaModel
            if case .ollama(let picked) = current { name = picked }
            options.ollama = [.init(title: "\(name) (Ollama is not running)", model: .ollama(name))]
        }
        return options
    }

    /// Whether the model can answer now: Apple's is there, or Ollama runs and has the model.
    static func canRun(_ model: LocalModel, appleAvailable: Bool, ollamaModels: [String]?) -> Bool {
        switch model {
        case .apple: appleAvailable
        case .ollama(let name): ollamaModels.map { CallTitles.contains($0, name) } ?? false
        }
    }

    /// Whether neither intelligence model can answer: Apple's is not available and Ollama is not
    /// running or has no models. What depends on a model is greyed out then.
    static func noModelCanRun(apple: AppleModelState, ollamaModels: [String]?) -> Bool {
        apple != .available && (ollamaModels?.isEmpty ?? true)
    }

    /// Why nothing can run and what to do, short enough to sit under the picker's label. Where
    /// Apple's model can never work on this Mac, only Ollama is left to suggest.
    static func noModelHint(apple: AppleModelState) -> String {
        switch apple {
        case .unsupported, .needsNewerMacOS: "Start Ollama to use these."
        default: "Start Ollama or turn on Apple Intelligence."
        }
    }

    /// The picker's tag for a model, and back.
    static func tag(_ model: LocalModel) -> String {
        switch model {
        case .apple: "apple"
        case .ollama(let name): "ollama:" + name
        }
    }

    static func model(tag: String) -> LocalModel? {
        if tag == "apple" { return .apple }
        guard tag.hasPrefix("ollama:") else { return nil }
        return .ollama(String(tag.dropFirst("ollama:".count)))
    }
}

/// When a title may be asked of Ollama: its model competes with whisper for the GPU, so it
/// waits for a quiet Mac. A call app being in a call doesn't count, since that can last for
/// hours and the call's own recording is what matters.
enum TitleGate {
    static func mayAsk(_ activity: Activity) -> Bool {
        !(activity.dictationRecording || activity.dictationTranscribing || activity.fixing
            || activity.callRecording || activity.callTranscribing)
    }

    /// False when the Mac stayed busy for the whole `timeout`.
    @MainActor
    static func waitUntilQuiet(activity: @MainActor () -> Activity, timeout: Duration = .seconds(600),
                               poll: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !mayAsk(activity()) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: poll)
            if Task.isCancelled { return false }
        }
        return true
    }
}

/// Automatic call titles are on unless the person turned them off with the Settings toggle: a
/// stored "titleCalls" counts only beside the "titleCallsChosen" marker that the toggle writes.
enum TitleCallsDefault {
    static let key = "titleCalls"
    static let chosenKey = "titleCallsChosen"

    static func load(from defaults: UserDefaults) -> Bool {
        guard defaults.bool(forKey: chosenKey) else { return true }
        return defaults.object(forKey: key) as? Bool ?? true
    }

    static func save(_ value: Bool, to defaults: UserDefaults) {
        defaults.set(value, forKey: key)
        defaults.set(true, forKey: chosenKey)
    }
}
