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

    /// The model in use from the observed pick, not from what is stored, so a pick in Settings
    /// shows at once.
    static func effective(stored: LocalModel?, ollamaConfigured: Bool, ollamaModel: String,
                          appleAvailable: Bool) -> LocalModel {
        LocalModel.resolve(stored: stored?.storedValue, ollamaConfigured: ollamaConfigured,
                           appleAvailable: appleAvailable, fixModel: ollamaModel)
    }

    /// Whether the model can answer now: Apple's is there, or Ollama runs and has the model.
    static func canRun(_ model: LocalModel, appleAvailable: Bool, ollamaModels: [String]?) -> Bool {
        switch model {
        case .apple: appleAvailable
        case .ollama(let name): ollamaModels.map { CallTitles.contains($0, name) } ?? false
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
