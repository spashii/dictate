import Foundation
import VoiceCore

/// The facts the app feeds VoiceCore's `LocalModel.resolve`, and what the choice means for
/// the fix step and for titling. Kept apart from Preferences so it can be tested without the
/// app's global state.
enum LocalModelChoice {
    /// The person set up Ollama before Apple's model existed: they turned the fix on, or
    /// picked an Ollama model. Read from what is stored, since a default isn't a choice.
    static func ollamaConfigured(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "runPrompt") || defaults.object(forKey: "ollamaModel") != nil
    }

    static func effective(defaults: UserDefaults = .standard, ollamaModel: String,
                          appleAvailable: Bool) -> LocalModel {
        LocalModel.resolve(stored: defaults.string(forKey: "localModel"),
                           ollamaConfigured: ollamaConfigured(in: defaults),
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
