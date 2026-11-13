import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The one on-device model that fixes the text and titles calls: Apple's, or a model Ollama
/// serves. One choice for both jobs, because both are short local text jobs.
public enum LocalModel: Codable, Hashable, Sendable {
    case apple
    case ollama(String)

    /// What the app stores under the "localModel" key after a pick in Settings. An Ollama
    /// pick stores only the kind: which model it is lives in the existing "ollamaModel" key.
    public var storedValue: String {
        switch self {
        case .apple: "apple"
        case .ollama: "ollama"
        }
    }

    /// Ollama for anyone who set it up before or picked it, else Apple's, whether or not this
    /// Mac has it now. Never stored, so someone who never picked follows the default.
    public static func resolve(stored: String?, ollamaConfigured: Bool, fixModel: String) -> LocalModel {
        switch stored {
        case "apple": return .apple
        case "ollama": return .ollama(fixModel)
        default: break
        }
        return ollamaConfigured ? .ollama(fixModel) : .apple
    }
}

/// Why Apple's on-device model can or can't answer now.
public enum AppleModelState: Sendable, Equatable {
    case available
    /// Apple Intelligence is off in System Settings.
    case turnedOff
    /// The model is still downloading or preparing.
    case notReady
    /// This Mac can't run it, or the framework reports a reason this version doesn't know.
    case unsupported
    /// macOS before 26, where the framework doesn't exist.
    case needsNewerMacOS
}

/// Whether Apple's on-device model can answer now. Read at the moment of use: the person
/// can turn Apple Intelligence on or off while the app runs. Unavailable before macOS 26, where the
/// framework doesn't exist, so a build for macOS 15 still runs.
public enum AppleModel {
    public static var state: AppleModelState {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.appleIntelligenceNotEnabled): return .turnedOff
            case .unavailable(.modelNotReady): return .notReady
            case .unavailable: return .unsupported
            }
        }
        #endif
        return .needsNewerMacOS
    }

    public static var isAvailable: Bool { state == .available }
}
