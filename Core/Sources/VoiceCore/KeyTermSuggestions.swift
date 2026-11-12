import Foundation

/// A key term proposed from an agent's correction: the words the correction wrote where
/// whisper wrote others. Nothing reaches the key terms until Add is tapped in Settings.
public struct TermSuggestion: Sendable, Codable, Equatable, Identifiable {
    public enum Status: String, Sendable, Codable, CaseIterable {
        case pending, accepted, dismissed
    }

    public var id: Int64
    /// As the correction spelled it.
    public var term: String
    /// What whisper wrote there, each spelling once, first seen first.
    public var heard: [String]
    public var status: Status
    /// The correction that first proposed it.
    public var editID: Int64
    /// How many corrections proposed it.
    public var corrections: Int
    public var createdAt: Date
    /// The edit that added or dismissed it, while that edit stands.
    public var decisionEditID: Int64?
    public var decidedAt: Date?
}

/// The key terms a correction proposes: each stretch of words it replaced, as the
/// correction wrote it, with what whisper had written; and each name it only re-cased, such
/// as "T3 code" corrected to "T3 Code". WordDiff aligns the two texts, so a change of
/// punctuation alone is no change, and a change of case counts only where it makes a name.
public enum TermProposals {
    public struct Proposal: Sendable, Equatable {
        public var term: String
        public var heard: [String]

        public init(term: String, heard: [String]) {
            self.term = term
            self.heard = heard
        }
    }

    /// A longer replacement is a rewrite rather than a name whisper misheard.
    static let maxWords = 4

    /// Hesitations and the commonest function words: a change made only of these is
    /// grammar or filler, and at either end of a change they are not part of the name.
    static let filler: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "eh", "hmm", "mm", "mhm", "like", "so", "well", "okay",
        "ok", "yeah", "yep", "right", "actually", "basically", "just", "you", "know", "i", "mean",
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "from", "by", "as",
        "is", "are", "was", "were", "be", "it", "it's", "its", "this", "that", "these", "those", "there",
        "their", "they're", "then", "than", "we", "he", "she", "they", "my", "our", "your",
    ]

    /// The proposals, one per term in the order the correction makes them, leaving out
    /// pure additions and removals, filler, numbers, rewrites longer than `maxWords`, case
    /// changes that make no name (a sentence's first word, a word put in lower case), and
    /// terms `known` already has in any case.
    public static func from(original: String, corrected: String, known: [String] = []) -> [Proposal] {
        let a = WordDiff.wordRanges(original), b = WordDiff.wordRanges(corrected)
        let wordsA = a.map { String(original[$0]) }, wordsB = b.map { String(corrected[$0]) }
        let diff = WordDiff(original, corrected)
        func gap(_ j: Int) -> Substring { corrected[b[j - 1].upperBound..<b[j].lowerBound] }
        func opens(_ j: Int) -> Bool { startsSentence(corrected, at: b[j].lowerBound) }
        // Ranges of words, whisper's and the correction's, each a candidate term.
        var candidates: [(before: Range<Int>, after: Range<Int>)] = []
        var taken = Set<Int>()

        for (index, span) in diff.spans.enumerated() {
            var before = span.before, after = span.after
            trim(&before, wordsA)
            trim(&after, wordsB)
            // Only a replacement says how whisper heard the words.
            guard !before.isEmpty, !after.isEmpty else { continue }
            // Neighbours the correction only re-cased belong to the name: "tea three code"
            // corrected to "T3 Code" proposes "T3 Code", not "T3". A neighbour left as it was
            // stays out, so "cloud.md" corrected to "Claude.md" proposes "Claude".
            let previousEnd = index > 0 ? diff.spans[index - 1].after.upperBound : 0
            let nextStart = index + 1 < diff.spans.count ? diff.spans[index + 1].after.lowerBound : b.count
            if after.upperBound == span.after.upperBound, before.upperBound == span.before.upperBound {
                var i = before.upperBound, j = after.upperBound
                while j < nextStart, i < a.count, wordsA[i] != wordsB[j], joined(gap(j)) {
                    i += 1
                    j += 1
                }
                before = before.lowerBound..<i
                after = after.lowerBound..<j
            }
            if after.lowerBound == span.after.lowerBound, before.lowerBound == span.before.lowerBound {
                var i = before.lowerBound, j = after.lowerBound
                while j > previousEnd, i > 0, wordsA[i - 1] != wordsB[j - 1], joined(gap(j)), !opens(j - 1) {
                    i -= 1
                    j -= 1
                }
                before = i..<before.upperBound
                after = j..<after.upperBound
            }
            taken.formUnion(after)
            candidates.append((before, after))
        }

        // The words both texts share, paired in order: the stretches between the changes.
        var shared: [(i: Int, j: Int)] = []
        for k in 0...diff.spans.count {
            let i0 = k == 0 ? 0 : diff.spans[k - 1].before.upperBound
            let j0 = k == 0 ? 0 : diff.spans[k - 1].after.upperBound
            let j1 = k < diff.spans.count ? diff.spans[k].after.lowerBound : b.count
            for offset in 0..<max(0, j1 - j0) { shared.append((i0 + offset, j0 + offset)) }
        }
        // A word only re-cased is a name when the correction gave it a capital that sentence
        // case doesn't explain: "blend" to "Blend" mid-sentence, "t3 code" to "T3 Code"
        // anywhere, but not "send" to "Send" at the start of a sentence.
        func recased(_ p: Int) -> Bool {
            let (i, j) = shared[p]
            return wordsA[i] != wordsB[j] && !taken.contains(j) && !filler.contains(WordDiff.key(wordsB[j]))
        }
        var p = 0
        while p < shared.count {
            guard recased(p) else {
                p += 1
                continue
            }
            var q = p + 1
            while q < shared.count, recased(q), shared[q].j == shared[q - 1].j + 1, joined(gap(shared[q].j)) { q += 1 }
            defer { p = q }
            // A sentence's first word, re-cased beside a name, isn't part of it.
            func isName(_ r: Int) -> Bool { named(wordsB[shared[r].j], opensSentence: opens(shared[r].j)) }
            var lower = p, upper = q
            while lower < upper, !isName(lower) { lower += 1 }
            while lower < upper, !isName(upper - 1) { upper -= 1 }
            guard lower < upper else { continue }
            // Words already written as a name join it: "T3 code" corrected to "T3 Code"
            // proposes "T3 Code".
            func keeps(_ r: Int) -> Bool {
                let (i, j) = shared[r]
                return wordsA[i] == wordsB[j] && !taken.contains(j) && !filler.contains(WordDiff.key(wordsB[j]))
                    && named(wordsB[j], opensSentence: opens(j))
            }
            while lower > 0, upper - lower < maxWords, shared[lower - 1].j == shared[lower].j - 1,
                  joined(gap(shared[lower].j)), keeps(lower - 1) { lower -= 1 }
            while upper < shared.count, upper - lower < maxWords, shared[upper].j == shared[upper - 1].j + 1,
                  joined(gap(shared[upper].j)), keeps(upper) { upper += 1 }
            let before = shared[lower].i..<shared[upper - 1].i + 1, after = shared[lower].j..<shared[upper - 1].j + 1
            taken.formUnion(after)
            candidates.append((before, after))
        }

        let knownKeys = Set(known.map(key))
        var proposals: [Proposal] = []
        for (before, after) in candidates.sorted(by: { $0.after.lowerBound < $1.after.lowerBound }) {
            guard after.count <= maxWords, before.count <= maxWords else { continue }
            // Two words joined by a comma or a full stop are two things, not one name.
            guard (after.lowerBound + 1..<after.upperBound).allSatisfy({ joined(gap($0)) }) else { continue }
            guard !wordsB[after].allSatisfy({ $0.allSatisfy(\.isNumber) }) else { continue }
            let term = possessive(String(corrected[b[after.lowerBound].lowerBound..<b[after.upperBound - 1].upperBound]))
            let heard = possessive(String(original[a[before.lowerBound].lowerBound..<a[before.upperBound - 1].upperBound]))
            guard !knownKeys.contains(key(term)) else { continue }
            if let same = proposals.firstIndex(where: { key($0.term) == key(term) }) {
                if !proposals[same].heard.contains(heard) { proposals[same].heard.append(heard) }
            } else {
                proposals.append(Proposal(term: term, heard: [heard]))
            }
        }
        return proposals
    }

    /// Written as a name: a digit, a capital past the first letter, or a first capital
    /// where no sentence starts.
    static func named(_ word: String, opensSentence: Bool) -> Bool {
        if word.contains(where: \.isNumber) || word.dropFirst().contains(where: \.isUppercase) { return true }
        return !opensSentence && (word.first?.isUppercase ?? false)
    }

    static func key(_ term: String) -> String { term.lowercased() }

    /// Drops filler words from either end of a range of words.
    private static func trim(_ range: inout Range<Int>, _ words: [String]) {
        while !range.isEmpty, filler.contains(WordDiff.key(words[range.lowerBound])) {
            range = range.lowerBound + 1..<range.upperBound
        }
        while !range.isEmpty, filler.contains(WordDiff.key(words[range.upperBound - 1])) {
            range = range.lowerBound..<range.upperBound - 1
        }
    }

    /// Words with only spaces between them, on one line.
    private static func spaced(_ gap: Substring) -> Bool {
        !gap.isEmpty && gap.allSatisfy { $0 == " " }
    }

    /// Between two words of one name: spaces, or joiners such as the dot in whisper.cpp or
    /// the hyphen in T3-Code.
    private static func joined(_ gap: Substring) -> Bool {
        spaced(gap) || (!gap.isEmpty && gap.allSatisfy { "-._/&+@".contains($0) })
    }

    /// Whether the word starting here opens the text or a sentence, where a capital says
    /// nothing about a name.
    private static func startsSentence(_ text: String, at index: String.Index) -> Bool {
        let before = text[..<index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = before.last else { return true }
        return ".!?".contains(last)
    }

    /// "Claude's" proposes "Claude".
    private static func possessive(_ text: String) -> String {
        for suffix in ["'s", "’s"] where text.count > suffix.count + 1 && text.hasSuffix(suffix) {
            return String(text.dropLast(suffix.count))
        }
        return text
    }
}

extension CallStore {
    /// Records the key terms a correction proposes, skipping those in `known` (the list as
    /// it is now). A term already suggested and still pending gains the new spelling
    /// whisper wrote; one accepted or dismissed is left alone. Returns the suggestions this
    /// correction made or added to. Terms made only of everyday English words are not
    /// suggested.
    @discardableResult
    public func suggestKeyTerms(from edit: Edit, known: [String],
                                dictionary: CommonWords.Dictionary = CommonWords.system) throws -> [TermSuggestion] {
        guard edit.kind == .correctDictation || edit.kind == .correctSegment,
              edit.after?.corrected == true,
              let original = edit.before?.text, let corrected = edit.after?.text else { return [] }
        let proposals = TermProposals.from(original: original, corrected: corrected, known: known)
            .filter { !CommonWords.covers($0.term, in: dictionary) }
        guard !proposals.isEmpty else { return [] }
        let ids = try queue.sync {
            try db.transaction { () -> [Int64] in
                var ids: [Int64] = []
                for proposal in proposals {
                    let existing = try db.query("SELECT \(Self.suggestionColumns) \(Self.suggestionFrom) WHERE s.term = ?",
                                                [proposal.term], Self.readSuggestion).first
                    guard let existing else {
                        try db.run("""
                            INSERT INTO key_term_suggestions (term, heard, edit_id, created_at) VALUES (?,?,?,?)
                            """, [proposal.term, Self.joinHeard(proposal.heard), edit.id, Date()])
                        ids.append(db.lastInsertRowID)
                        continue
                    }
                    guard existing.status == .pending else { continue }
                    var heard = existing.heard
                    for form in proposal.heard where !heard.contains(form) { heard.append(form) }
                    // A decision that was undone no longer counts.
                    try db.run("""
                        UPDATE key_term_suggestions SET heard = ?, corrections = corrections + 1, status = 'pending',
                          decision_edit = NULL, decided_at = NULL WHERE id = ?
                        """, [Self.joinHeard(heard), existing.id])
                    ids.append(existing.id)
                }
                return ids
            }
        }
        return try ids.compactMap { try termSuggestion($0) }
    }

    /// Suggestions with this status, or all with nil: the most often proposed first, then the newest.
    public func termSuggestions(status: TermSuggestion.Status? = .pending, limit: Int = 50) throws -> [TermSuggestion] {
        try queue.sync {
            try db.query("""
                SELECT * FROM (SELECT \(Self.suggestionColumns) \(Self.suggestionFrom))
                WHERE ?1 IS NULL OR status = ?1 ORDER BY corrections DESC, id DESC LIMIT ?2
                """, [status?.rawValue, limit], Self.readSuggestion)
        }
    }

    public func termSuggestion(_ id: Int64) throws -> TermSuggestion? {
        try queue.sync {
            try db.query("SELECT \(Self.suggestionColumns) \(Self.suggestionFrom) WHERE s.id = ?", [id],
                         Self.readSuggestion).first
        }
    }

    /// Settings' Dismiss: the suggestion stops showing, recorded as an edit that undo_edit reverts.
    @discardableResult
    public func dismissTermSuggestion(_ id: Int64, client: String?) throws -> Edit {
        try queue.sync {
            try db.transaction { () -> Edit in
                let suggestion = try pendingSuggestion(id)
                let edit = try insertEdit(.dismissKeyTerm, target: Edit.target(suggestion: id), client: client,
                                          before: Edit.Value(terms: [suggestion.term], status: TermSuggestion.Status.pending.rawValue),
                                          after: Edit.Value(terms: [suggestion.term], status: TermSuggestion.Status.dismissed.rawValue))
                try decide(id, .dismissed, edit: edit.id)
                return edit
            }
        }
    }

    /// Marks a suggestion accepted once its term is in the list; `edit` is the add that put it
    /// there, nil when the term was already listed.
    func acceptTermSuggestion(_ id: Int64, edit: Int64?) throws {
        try queue.sync {
            try db.transaction {
                _ = try pendingSuggestion(id)
                try decide(id, .accepted, edit: edit)
            }
        }
    }

    /// Records the undo of a dismissal; the suggestion reads as pending again because its
    /// decision is undone.
    @discardableResult
    func undoDismissal(_ id: Int64, client: String?) throws -> Edit {
        let edit = try checkUndoable(id)
        return try recordUndo(of: id, client: client,
                              before: Edit.Value(terms: edit.after?.terms, status: TermSuggestion.Status.dismissed.rawValue),
                              after: Edit.Value(terms: edit.before?.terms, status: TermSuggestion.Status.pending.rawValue))
    }

    // MARK: Helpers

    /// On the queue, in the caller's transaction.
    private func pendingSuggestion(_ id: Int64) throws -> TermSuggestion {
        guard let suggestion = try db.query("SELECT \(Self.suggestionColumns) \(Self.suggestionFrom) WHERE s.id = ?", [id],
                                            Self.readSuggestion).first else {
            throw VoiceError.store("No suggested key term \(id).")
        }
        guard suggestion.status == .pending else {
            throw VoiceError.store("\(suggestion.term) was already \(suggestion.status.rawValue).")
        }
        return suggestion
    }

    private func decide(_ id: Int64, _ status: TermSuggestion.Status, edit: Int64?) throws {
        try db.run("UPDATE key_term_suggestions SET status = ?, decision_edit = ?, decided_at = ? WHERE id = ?",
                   [status.rawValue, edit, Date(), id])
    }

    /// The status reads as pending when the edit that decided it was undone.
    private static let suggestionColumns = """
        s.id, s.term, s.heard,
        CASE WHEN e.undone_by IS NOT NULL THEN 'pending' ELSE s.status END AS status,
        s.edit_id, s.corrections, s.created_at,
        CASE WHEN e.undone_by IS NOT NULL THEN NULL ELSE s.decision_edit END,
        CASE WHEN e.undone_by IS NOT NULL THEN NULL ELSE s.decided_at END
        """
    private static let suggestionFrom = "FROM key_term_suggestions s LEFT JOIN edits e ON e.id = s.decision_edit"

    private static func readSuggestion(_ row: SQLiteRow) -> TermSuggestion {
        TermSuggestion(id: row.int64(0), term: row.text(1),
                       heard: row.text(2).split(separator: "\u{1F}").map(String.init),
                       status: TermSuggestion.Status(rawValue: row.text(3)) ?? .pending, editID: row.int64(4),
                       corrections: row.int(5), createdAt: row.date(6),
                       decisionEditID: row.isNull(7) ? nil : row.int64(7), decidedAt: row.optionalDate(8))
    }

    private static func joinHeard(_ heard: [String]) -> String { heard.joined(separator: "\u{1F}") }
}

extension Edit {
    public static func target(suggestion id: Int64) -> String { "key_term_suggestion:\(id)" }
}

/// Settings' Add and Dismiss on the suggested key terms. Add goes through the same path as
/// add_key_terms, refused the same way past whisper's prompt limit, and is recorded as an
/// add_key_terms edit by `client`; Dismiss is a dismiss_key_term edit. undo_edit reverts
/// either, and the suggestion shows again.
public actor KeyTermSuggestions {
    public static let settingsClient = "Dictate Settings"

    private let store: CallStore
    private let editor: KeyTermsEditor
    private let dictionary: CommonWords.Dictionary

    public init(store: CallStore, settings: any KeyTermsSettings, tokenizer: any PromptTokenizer = WhisperTokenizer(),
                dictionary: @escaping CommonWords.Dictionary = CommonWords.system) {
        self.dictionary = dictionary
        self.store = store
        editor = KeyTermsEditor(settings: settings, tokenizer: tokenizer, store: store)
    }

    /// The pending suggestions whose term isn't in the list yet, at most `limit`. Ones made
    /// of everyday words stay hidden, including any stored before that was checked.
    public func pending(limit: Int = 5) async throws -> [TermSuggestion] {
        let known = Set(KeyTerms.parse(await editor.settings.keyTerms()).map(TermProposals.key))
        let dictionary = dictionary
        return Array(try store.termSuggestions(status: .pending, limit: 200)
            .filter { !known.contains(TermProposals.key($0.term)) && !CommonWords.covers($0.term, in: dictionary) }
            .prefix(limit))
    }

    /// Adds the term to the key terms. Throws, with add_key_terms' words, when whisper's
    /// prompt would pass its limit; the suggestion then stays pending.
    @discardableResult
    public func accept(_ id: Int64, client: String = settingsClient) async throws -> Edit? {
        guard let suggestion = try store.termSuggestion(id) else { throw VoiceError.store("No suggested key term \(id).") }
        guard suggestion.status == .pending else {
            throw VoiceError.store("\(suggestion.term) was already \(suggestion.status.rawValue).")
        }
        let change: KeyTermsChange
        do {
            change = try await editor.add([suggestion.term], client: client)
        } catch let error as ToolError {
            throw VoiceError.store(error.message)
        }
        try store.acceptTermSuggestion(id, edit: change.edit?.id)
        return change.edit
    }

    @discardableResult
    public func dismiss(_ id: Int64, client: String = settingsClient) throws -> Edit {
        try store.dismissTermSuggestion(id, client: client)
    }
}
