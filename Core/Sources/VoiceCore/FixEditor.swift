import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The model call of the fix step, so the pipeline asks "propose edits" without knowing who
/// answers, and tests answer with a fake. Everything after the reply (validate, apply) is the
/// same for every editor.
public protocol FixEditor: Sendable {
    /// Whether whisper gives its memory back first. Only Ollama's runner competes with it for
    /// the GPU; Apple's model belongs to the system.
    var unloadsWhisper: Bool { get }
    /// Proposed edits to the segments sent, unchecked.
    func edits(_ segments: [Segment], flagged: [Int], settings: CleanupSettings) async throws -> [FixEdit]
    /// The whole text rewritten by the settings' prompt: the evaluation's scope only.
    func rewrite(_ text: String, settings: CleanupSettings) async throws -> String
}

public enum FixEditors {
    /// The editor for the settings' engine. Apple's without the model on this Mac fails like a
    /// stopped Ollama, so the text is pasted as whisper heard it.
    public static func editor(for settings: CleanupSettings) -> any FixEditor {
        switch settings.engine {
        case .ollama:
            return OllamaFixEditor()
        case .apple:
            #if canImport(FoundationModels)
            if #available(macOS 26, *), AppleModel.isAvailable { return AppleFixEditor() }
            #endif
            return UnavailableFixEditor(state: AppleModel.state)
        }
    }
}

public struct OllamaFixEditor: FixEditor {
    public var unloadsWhisper: Bool { true }

    public init() {}

    public func edits(_ segments: [Segment], flagged: [Int], settings: CleanupSettings) async throws -> [FixEdit] {
        try await Ollama().edits(segments, flagged: flagged, settings: settings).edits
    }

    public func rewrite(_ text: String, settings: CleanupSettings) async throws -> String {
        try await Ollama().cleanup(text, settings: settings).text
    }
}

struct UnavailableFixEditor: FixEditor {
    var unloadsWhisper: Bool { false }
    var state: AppleModelState

    /// The reason shown to the person, since "unavailable" alone doesn't say what to change.
    var reason: String {
        switch state {
        case .available, .unsupported: "Apple Intelligence isn't available on this Mac."
        case .turnedOff: "Apple Intelligence is turned off in System Settings."
        case .notReady: "Apple Intelligence isn't ready yet."
        case .needsNewerMacOS: "Apple Intelligence needs macOS 26."
        }
    }

    func edits(_ segments: [Segment], flagged: [Int], settings: CleanupSettings) async throws -> [FixEdit] {
        throw VoiceError.cleanup(reason)
    }

    func rewrite(_ text: String, settings: CleanupSettings) async throws -> String {
        throw VoiceError.cleanup(reason)
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct AppleEditList {
    var edits: [AppleEditReply]
}

/// The shape of TargetedFix.schema: the same four fields, the key term empty when none.
@available(macOS 26, *)
@Generable
struct AppleEditReply {
    var segment: Int
    var span: String
    var replacement: String
    var keyTerm: String
}

/// Apple's on-device model with the same instructions and prompt as Ollama's, answering in
/// guided generation so the reply is always a list of edits.
@available(macOS 26, *)
public struct AppleFixEditor: FixEditor {
    public var unloadsWhisper: Bool { false }

    public init() {}

    public func edits(_ segments: [Segment], flagged: [Int], settings: CleanupSettings) async throws -> [FixEdit] {
        let session = LanguageModelSession(instructions: TargetedFix.system)
        let response = try await session.respond(
            to: TargetedFix.prompt(segments, flagged: flagged, keyTerms: settings.keyTerms),
            generating: AppleEditList.self,
            options: GenerationOptions(temperature: settings.temperature))
        return response.content.edits.map { edit in
            let term = edit.keyTerm.trimmingCharacters(in: .whitespaces)
            return FixEdit(segment: edit.segment, span: edit.span, replacement: edit.replacement,
                           keyTerm: term.isEmpty ? nil : term)
        }
    }

    public func rewrite(_ text: String, settings: CleanupSettings) async throws -> String {
        let session = LanguageModelSession(instructions: settings.system)
        let response = try await session.respond(to: text, options: GenerationOptions(temperature: settings.temperature))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
