import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The text side of titling a call: what the model is told, what it sees of the transcript
/// and how its answer is cleaned. Pure, so the app and the tests share one definition.
public enum CallTitles {
    public static let instructions = """
        You title recorded calls. Reply with only a title of 3 to 7 words that says what the call \
        was about, in the language of the transcript. Name the project, company or person when the \
        transcript makes them clear. No quotes, no trailing punctuation, nothing else.
        """

    public static let minimumWords = 12
    static let budget = 6000
    static let headBudget = 4000
    static let tailBudget = 2000

    public static func prompt(for excerpt: String) -> String { "Transcript:\n" + excerpt }

    /// The transcript as the model sees it: "Me: text" and "Call: text" lines in time order,
    /// without timestamps. Nil when there is too little said to name the call. A longer
    /// transcript keeps its start and its end, where a call says what it is for and what came
    /// of it; the middle is the part a title can do without.
    public static func excerpt(_ segments: [CallSegment], speakers: [String]?) -> String? {
        let ordered = segments.sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
        var lines: [String] = []
        var words = 0
        for segment in ordered {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            words += text.split(whereSeparator: \.isWhitespace).count
            let name = speakers.flatMap { names -> String? in
                switch segment.channel {
                case .me: names.first
                case .call: names.count > 1 ? names[1] : nil
                case .mix: nil
                }
            } ?? segment.channel.label
            lines.append(name.map { "\($0): \(text)" } ?? text)
        }
        guard words >= minimumWords else { return nil }
        let full = lines.joined(separator: "\n")
        guard full.count > budget else { return full }

        var head: [String] = []
        var used = 0
        for line in lines {
            let cost = line.count + 1
            if used + cost > headBudget { break }
            head.append(line)
            used += cost
        }
        var tail: [String] = []
        used = 0
        for line in lines.reversed() {
            let cost = line.count + 1
            if used + cost > tailBudget { break }
            tail.insert(line, at: 0)
            used += cost
        }
        // One enormous line (unsplit audio can produce one) has no boundary to cut at.
        if head.isEmpty, let first = lines.first { head = [String(first.prefix(headBudget))] }
        if tail.isEmpty, let last = lines.last { tail = [String(last.suffix(tailBudget))] }
        return (head + ["[...]"] + tail).joined(separator: "\n")
    }

    private static let leading = CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019}\u{AB}\u{BB}\u{201E}*_#-\u{2022}>")
        .union(.whitespaces)
    private static let trailing = CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019}\u{AB}\u{BB}\u{201E}*_.,;:!?\u{2026}\u{3002}\u{FF01}\u{FF1F}")
        .union(.whitespaces)
    private static let refusals = ["sorry", "i'm sorry", "i am sorry", "i can't", "i cannot", "as an ai"]

    /// A title from whatever the model wrote, or nil when it isn't one. A refusal or a
    /// paragraph stored as a title would be worse than the untitled row it replaces.
    public static func sanitize(_ raw: String) -> String? {
        var text = raw
        text = Ollama.stripThinking(text)
        if let open = text.range(of: "<think>") { text.removeSubrange(open.lowerBound..<text.endIndex) }
        guard var line = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }

        line = line.trimmingCharacters(in: leading)
        if line.lowercased().hasPrefix("title:") {
            line = String(line.dropFirst("title:".count)).trimmingCharacters(in: leading)
        }
        line = line.trimmingCharacters(in: trailing)
        line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        guard !line.isEmpty, line.contains(where: \.isLetter),
              line.count <= 80,
              line.split(separator: " ").count <= 10 else { return nil }
        let lowered = line.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if refusals.contains(where: { lowered.hasPrefix($0) }) { return nil }
        return line
    }

    /// Ollama lists "name:latest" for a model pulled as "name". The same rule as the app's
    /// check for the fix-up model, so one setting names one model in both places.
    public static func contains(_ models: [String], _ name: String) -> Bool {
        models.contains(name) || models.contains(name + ":latest")
    }

    /// The models to try, best first: Apple's on-device model when this Mac offers it, then
    /// Ollama when it has the fix-up model. The app passes facts and never builds a model.
    public static func models(appleAvailable: Bool, ollamaModels: [String]?, fixModel: String,
                              ollamaURL: URL) -> [any TitleModel] {
        var models: [any TitleModel] = []
        #if canImport(FoundationModels)
        if appleAvailable, #available(macOS 26, *) { models.append(AppleTitleModel()) }
        #endif
        if let installed = ollamaModels, contains(installed, fixModel) {
            models.append(OllamaTitleModel(model: fixModel, url: ollamaURL))
        }
        return models
    }
}

/// Something that can name a call from a prompt. Any error means "try the next one".
public protocol TitleModel: Sendable {
    var name: String { get }
    func title(instructions: String, prompt: String) async throws -> String
}

public struct OllamaTitleModel: TitleModel {
    public let model: String
    public let url: URL
    public var name: String { "ollama" }

    public init(model: String, url: URL) {
        self.model = model
        self.url = url
    }

    /// Short and cool: a title is a few words, and the model is kept for two minutes only so a
    /// run of calls doesn't hold memory the Mac needs for dictation.
    static func body(model: String, instructions: String, prompt: String) -> [String: Any] {
        [
            "model": model,
            "system": instructions,
            "prompt": prompt,
            "think": false,
            "stream": false,
            "keep_alive": "2m",
            "options": ["temperature": 0.2, "num_ctx": 4096, "num_predict": 32] as [String: Any],
        ]
    }

    public func title(instructions: String, prompt: String) async throws -> String {
        let settings = CleanupSettings(ollamaURL: url, model: model)
        return try await Ollama().generate(Self.body(model: model, instructions: instructions, prompt: prompt),
                                           settings: settings).text
    }
}

#if canImport(FoundationModels)
/// Apple's on-device model, macOS 26 with Apple Intelligence turned on.
@available(macOS 26, *)
public struct AppleTitleModel: TitleModel {
    public var name: String { "apple" }

    public init() {}

    public static var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    public func title(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt, options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 32))
        return response.content
    }
}
#endif

/// Names a finished call from its transcript. Nothing escapes it: a call that can't be
/// titled keeps today's label.
public struct CallTitler: Sendable {
    private static let log = Logger(subsystem: "io.github.spashii.voice", category: "call-titles")

    public init() {}

    /// The title stored, or nil when none was: the call already has one, is too short, no
    /// model gave a usable answer, or a person named it while the model was working.
    public func title(_ callID: String, in store: CallStore, models: [any TitleModel]) async -> String? {
        guard !models.isEmpty else { return nil }
        do {
            guard let call = try store.call(callID), call.title == nil, call.titleSource == nil,
                  let excerpt = CallTitles.excerpt(try store.segments(callID), speakers: call.speakers)
            else { return nil }
            let prompt = CallTitles.prompt(for: excerpt)
            for model in models {
                let raw: String
                do {
                    raw = try await model.title(instructions: CallTitles.instructions, prompt: prompt)
                } catch {
                    // The error type only: a model's message can quote the transcript.
                    Self.log.error("\(model.name, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)")
                    continue
                }
                guard let title = CallTitles.sanitize(raw) else {
                    Self.log.error("\(model.name, privacy: .public) answered with no usable title")
                    continue
                }
                // False when a person or an agent named the call in the meantime.
                return try store.setAutoTitle(callID, title) ? title : nil
            }
        } catch {
            Self.log.error("titling failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        return nil
    }
}
