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

    /// The model a Mac uses when nothing is stored: Ollama for anyone who already set it up
    /// (fix-up turned on, or a model picked), else Apple's when this Mac offers it, else
    /// Ollama's fix-up model. Computed each time and never stored, so turning on Apple
    /// Intelligence later takes effect without a pick.
    public static func resolve(stored: String?, ollamaConfigured: Bool, appleAvailable: Bool,
                               fixModel: String) -> LocalModel {
        switch stored {
        case "apple": return .apple
        case "ollama": return .ollama(fixModel)
        default: break
        }
        if ollamaConfigured { return .ollama(fixModel) }
        return appleAvailable ? .apple : .ollama(fixModel)
    }
}

/// Whether Apple's on-device model can answer now. Read at the moment of use: the person
/// can turn Apple Intelligence on or off while the app runs. False before macOS 26, where the
/// framework doesn't exist, so a build for macOS 15 still runs.
public enum AppleModel {
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }
}
