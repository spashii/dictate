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
    /// Characters of transcript the model sees, split two thirds to the start and one third to
    /// the end. CJK and other non-Latin scripts take more tokens per character, so a call in
    /// one gets a third of the room to keep it inside the context the fix step also uses.
    struct Budget: Equatable {
        var total: Int
        var head: Int { total * 2 / 3 }
        var tail: Int { total - head }
        static let latin = Budget(total: 6000)
        static let nonLatin = Budget(total: 2000)
    }

    /// Non-Latin when most letters are outside the Latin blocks.
    static func budget(for text: String) -> Budget {
        var letters = 0
        var other = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            let value = scalar.value
            if !(value < 0x250 || (0x1E00...0x1EFF).contains(value)) { other += 1 }
        }
        return other * 2 > letters ? .nonLatin : .latin
    }

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
        let budget = budget(for: full)
        guard full.count > budget.total else { return full }
        let headBudget = budget.head
        let tailBudget = budget.tail

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
        var lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // "Here is a title for this call:" announces the answer: the answer is what follows
        // its colon, or else the next line. A lone "Q3 budget review:" is the title itself.
        if let first = lines.first, isLeadIn(first) {
            let after = first.lastIndex(of: ":").map { first[first.index(after: $0)...] }?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !after.isEmpty {
                lines[0] = after
            } else if lines.count > 1 || announces(first) {
                lines.removeFirst()
            }
        }
        guard var line = lines.first else { return nil }

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

    private static func isLeadIn(_ line: String) -> Bool {
        bare(line).hasSuffix(":") || announces(line)
    }

    private static func announces(_ line: String) -> Bool {
        let text = bare(line)
        return text.hasPrefix("here is") || text.hasPrefix("here's")
    }

    private static func bare(_ line: String) -> String {
        line.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_ \t"))
    }

    /// Ollama lists "name:latest" for a model pulled as "name". The same rule as the app's
    /// check for the fix-up model, so one setting names one model in both places.
    public static func contains(_ models: [String], _ name: String) -> Bool {
        models.contains(name) || models.contains(name + ":latest")
    }

    /// The model that titles calls: the chosen one only, with no fallback to the other, since
    /// someone who picked Apple does not want a 9B Ollama model loaded after each call. Empty
    /// when the chosen model isn't there, and the call keeps its label. The app passes facts
    /// and never builds a model.
    public static func models(choice: LocalModel, appleAvailable: Bool, ollamaModels: [String]?,
                              ollamaURL: URL) -> [any TitleModel] {
        switch choice {
        case .apple:
            #if canImport(FoundationModels)
            if appleAvailable, #available(macOS 26, *) { return [AppleTitleModel()] }
            #endif
            return []
        case .ollama(let model):
            guard let installed = ollamaModels, contains(installed, model) else { return [] }
            return [OllamaTitleModel(model: model, url: ollamaURL)]
        }
    }
}

/// Something that can name a call from a prompt. An error means the call stays untitled.
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
    /// run of calls doesn't hold memory the Mac needs for dictation. No `num_ctx`: the fix
    /// request sets none either, and a different one makes Ollama reload the model between them.
    static func body(model: String, instructions: String, prompt: String) -> [String: Any] {
        [
            "model": model,
            "system": instructions,
            "prompt": prompt,
            "think": false,
            "stream": false,
            "keep_alive": "2m",
            "options": ["temperature": 0.2, "num_predict": 32] as [String: Any],
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

    /// Whether a title could be made for the call now: it has none, nobody set one, and there
    /// is enough transcript. Cheap, so the app can ask before it frees memory for a model.
    public func isEligible(_ callID: String, in store: CallStore) -> Bool {
        guard let call = try? store.call(callID), call.title == nil, call.titleSource == nil,
              let segments = try? store.segments(callID) else { return false }
        return CallTitles.excerpt(segments, speakers: call.speakers) != nil
    }

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
                    if Task.isCancelled { return nil }
                    // The error type only: a model's message can quote the transcript.
                    Self.log.error("\(model.name, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)")
                    continue
                }
                // A dictation started and took the model's turn: the answer is dropped.
                if Task.isCancelled { return nil }
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
