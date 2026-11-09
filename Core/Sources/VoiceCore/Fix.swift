import Foundation

/// Which part of a dictation the fix step sees.
public enum FixScope: String, Sendable, Codable {
    /// Every segment, and the model answers with edits: what the app sends. Whisper is as
    /// sure of a misheard name as of any other word, so no signal of its own finds them.
    case every
    /// Only the segments the retry signals flagged, each with its neighbours, and the model
    /// answers with edits. A dictation with none flagged never reaches Ollama. Kept for the
    /// evaluation (voice-cli fix-batch --scope flagged).
    case flagged
    /// All of the text, rewritten by the prompt: the fix step before 0.7.0, kept for the
    /// evaluation (voice-cli fix-batch --whole).
    case whole
}

/// One edit the fix step proposed for a segment it was sent: `span`, copied from the segment's
/// text, becomes `replacement`. Every proposed edit is stored with its dictation, the
/// rejected ones with why, so what the model asked for can be checked against what was
/// pasted.
public struct FixEdit: Sendable, Codable, Equatable {
    /// Why an edit was not applied, stored as its raw value.
    public enum Rejection: String, Sendable, Codable, Equatable {
        /// It named a segment that wasn't sent, or none that exists.
        case notFlagged = "not-flagged"
        /// The span isn't in the segment's text, nor anywhere near it.
        case noMatch = "no-match"
        /// The span reaches into the text around the segment.
        case outsideSegment = "outside-segment"
        /// The span is in the segment more than once, so where it goes is a guess.
        case ambiguous
        /// The replacement is the span.
        case noChange = "no-change"
        /// It overlaps an edit already applied to the segment.
        case overlaps
        /// The replacement has more than two words beyond the span's, or a line break: new
        /// text rather than a misheard word put right.
        case addsWords = "adds-words"
    }

    /// The segment's index in the dictation.
    public var segment: Int
    public var span: String
    public var replacement: String
    /// The key term the replacement restores, when the model named one.
    public var keyTerm: String?
    /// Characters from the start of the segment's text to the span; nil when it has no
    /// single place there.
    public var offset: Int?
    public var rejected: Rejection?

    public var applied: Bool { rejected == nil }

    public init(segment: Int, span: String, replacement: String, keyTerm: String? = nil, offset: Int? = nil,
                rejected: Rejection? = nil) {
        self.segment = segment
        self.span = span
        self.replacement = replacement
        self.keyTerm = keyTerm
        self.offset = offset
        self.rejected = rejected
    }
}

/// What the fix step did to one dictation.
public struct FixOutcome: Sendable, Codable {
    /// The text to paste: whisper's when nothing was applied.
    public var text: String
    /// The segments sent, by index.
    public var flagged: [Int]
    public var edits: [FixEdit]
    /// Whether Ollama was asked at all.
    public var askedOllama: Bool
    /// The fix step's own time, Ollama's answer included; 0 when it wasn't asked.
    public var seconds: Double
    public var error: String?
}

/// The fix step as edits to segments: the request, the reply's edits, their checks, and
/// applying them. Everything after the reply is deterministic, so the same reply always
/// makes the same text.
public enum TargetedFix {
    public static let system = """
        You correct words a speech recognizer misheard. You get numbered segments of a \
        dictation, and the speaker's key terms: names and words spelled as they should be. A \
        segment sent without its neighbours comes with the words before and after it.

        Answer with edits only. An edit gives the segment's number, a span copied exactly from \
        that segment's text, its replacement, and the key term the replacement restores, or an \
        empty key_term when none. Change only words that were misheard, keep everything else \
        as it is, and never add or rewrite sentences. When nothing was misheard, answer with \
        no edits.
        """

    /// Ollama's structured output: a JSON object with an array of edits and nothing else.
    public static var schema: [String: Any] {
        let edit: [String: Any] = [
            "type": "object",
            "properties": [
                "segment": ["type": "integer"],
                "span": ["type": "string"],
                "replacement": ["type": "string"],
                "key_term": ["type": "string"],
            ],
            "required": ["segment", "span", "replacement", "key_term"],
        ]
        return ["type": "object", "properties": ["edits": ["type": "array", "items": edit]], "required": ["edits"]]
    }

    /// A segment is flagged when the retry pass flagged it, or, with no record, when its
    /// mean log probability is under the retry threshold.
    public static func flagged(_ segments: [Segment], below threshold: Double) -> [Int] {
        segments.indices.filter { i in
            let segment = segments[i]
            guard !segment.text.isEmpty else { return false }
            return segment.retry?.flagged ?? (segment.avgLogprob < threshold)
        }
    }

    /// The segments the edits may touch: every one with text, or the flagged ones.
    public static func sent(_ segments: [Segment], scope: FixScope, flagBelow: Double) -> [Int] {
        switch scope {
        case .flagged: flagged(segments, below: flagBelow)
        case .every, .whole: segments.indices.filter { !segments[$0].text.isEmpty }
        }
    }

    /// The user message: the key terms, then each segment sent. One whose neighbour isn't
    /// sent gets that side's words, so the model reads the sentence; when every segment goes,
    /// the list is the dictation and repeating it would only lengthen the wait.
    public static func prompt(_ segments: [Segment], flagged: [Int], keyTerms: [String]) -> String {
        let terms = keyTerms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var parts = ["Key terms: " + (terms.isEmpty ? "none" : terms.joined(separator: ", "))]
        let sent = Set(flagged)
        for i in flagged {
            var lines = ["Segment \(i)"]
            let previous = segments[..<i].lastIndex { !$0.text.isEmpty }
            let next = segments[(i + 1)...].firstIndex { !$0.text.isEmpty }
            let before = previous.map(sent.contains) == true ? "" : context(segments, before: i)
            let after = next.map(sent.contains) == true ? "" : context(segments, after: i)
            if !before.isEmpty { lines.append("Before: " + before) }
            lines.append("Text: " + segments[i].text)
            if !after.isEmpty { lines.append("After: " + after) }
            parts.append(lines.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// About 20 words on each side, enough to read the sentence a segment sits in.
    static func context(_ segments: [Segment], before i: Int) -> String {
        let text = segments[..<i].map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        return text.split(separator: " ").suffix(20).joined(separator: " ")
    }

    static func context(_ segments: [Segment], after i: Int) -> String {
        let text = segments[(i + 1)...].map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        return text.split(separator: " ").prefix(20).joined(separator: " ")
    }

    /// The edits in the model's answer, in its order, before any check.
    public static func parse(_ reply: String) throws -> [FixEdit] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
              let edits = object["edits"] as? [[String: Any]] else {
            throw VoiceError.cleanup("The fix step's answer wasn't a list of edits.")
        }
        return edits.compactMap { edit in
            guard let span = edit["span"] as? String, let replacement = edit["replacement"] as? String else { return nil }
            let segment = (edit["segment"] as? Int) ?? (edit["segment"] as? String).flatMap(Int.init) ?? -1
            let term = (edit["key_term"] as? String)?.trimmingCharacters(in: .whitespaces)
            return FixEdit(segment: segment, span: span, replacement: replacement,
                           keyTerm: term?.isEmpty == false ? term : nil)
        }
    }

    /// Checks each proposed edit against the segments, in order, and marks the ones that
    /// can't be applied with why. An accepted edit has its offset set.
    public static func validate(_ proposed: [FixEdit], segments: [Segment], flagged: [Int]) -> [FixEdit] {
        let allowed = Set(flagged)
        var taken: [Int: [Range<Int>]] = [:]
        return proposed.map { edit in
            var edit = edit
            edit.rejected = rejection(&edit, segments: segments, allowed: allowed, taken: &taken)
            return edit
        }
    }

    private static func rejection(_ edit: inout FixEdit, segments: [Segment], allowed: Set<Int>,
                                  taken: inout [Int: [Range<Int>]]) -> FixEdit.Rejection? {
        guard allowed.contains(edit.segment), segments.indices.contains(edit.segment) else { return .notFlagged }
        let text = segments[edit.segment].text
        guard !edit.span.isEmpty else { return .noMatch }
        let places = occurrences(of: edit.span, in: text)
        if places.isEmpty {
            let around = context(segments, before: edit.segment) + " " + text + " "
                + context(segments, after: edit.segment)
            return around.contains(edit.span) ? .outsideSegment : .noMatch
        }
        guard places.count == 1 else { return .ambiguous }
        let start = places[0]
        edit.offset = start
        guard edit.replacement != edit.span else { return .noChange }
        if edit.replacement.contains(where: \.isNewline) { return .addsWords }
        let spanWords = edit.span.split(whereSeparator: \.isWhitespace).count
        let newWords = edit.replacement.split(whereSeparator: \.isWhitespace).count
        guard newWords <= spanWords + 2 else { return .addsWords }
        let range = start..<(start + edit.span.count)
        guard !(taken[edit.segment] ?? []).contains(where: { $0.overlaps(range) }) else { return .overlaps }
        taken[edit.segment, default: []].append(range)
        return nil
    }

    /// Where `span` starts in `text`, in characters, overlapping matches included.
    static func occurrences(of span: String, in text: String) -> [Int] {
        var found: [Int] = []
        var from = text.startIndex
        while from < text.endIndex, let range = text.range(of: span, range: from..<text.endIndex) {
            found.append(text.distance(from: text.startIndex, to: range.lowerBound))
            from = text.index(after: range.lowerBound)
        }
        return found
    }

    /// The segments' texts with the applied edits in place.
    public static func apply(_ edits: [FixEdit], to segments: [Segment]) -> [String] {
        apply(edits, toTexts: segments.map(\.text))
    }

    public static func apply(_ edits: [FixEdit], toTexts texts: [String]) -> [String] {
        var texts = texts
        let applied = edits.filter(\.applied).sorted { ($0.segment, $0.offset ?? 0) > ($1.segment, $1.offset ?? 0) }
        for edit in applied {
            guard let offset = edit.offset, texts.indices.contains(edit.segment),
                  offset + edit.span.count <= texts[edit.segment].count else { continue }
            var text = texts[edit.segment]
            let lower = text.index(text.startIndex, offsetBy: offset)
            let upper = text.index(lower, offsetBy: edit.span.count)
            text.replaceSubrange(lower..<upper, with: edit.replacement)
            texts[edit.segment] = text
        }
        return texts
    }

    /// The text a dictation pastes: its segments joined as whisper's text is.
    public static func join(_ texts: [String]) -> String {
        texts.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

extension Ollama {
    /// Asks for edits to the segments sent, as structured output, and returns them as
    /// proposed, unchecked, with the seconds the answer took.
    public func edits(_ segments: [Segment], flagged: [Int],
                      settings: CleanupSettings) async throws -> (edits: [FixEdit], seconds: Double) {
        let body: [String: Any] = [
            "model": settings.model,
            "system": TargetedFix.system,
            "prompt": TargetedFix.prompt(segments, flagged: flagged, keyTerms: settings.keyTerms),
            "format": TargetedFix.schema,
            // Thinking would multiply the wait for an edit that doesn't need it.
            "think": false,
            "stream": false,
            "keep_alive": "2m",
            "options": ["temperature": settings.temperature],
        ]
        let result = try await generate(body, settings: settings)
        return (try TargetedFix.parse(result.text), result.seconds)
    }
}
