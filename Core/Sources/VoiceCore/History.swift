import Foundation

/// What the History window lists: one row per dictation or call, newest first.
public struct HistoryEntry: Sendable, Identifiable, Equatable, Hashable {
    public enum Kind: String, Sendable {
        case dictation
        case call
    }

    public var kind: Kind
    /// The dictation's or call's id.
    public var ref: String
    public var at: Date
    /// The IANA zone it was recorded in; nil when unknown, which shows as the current zone.
    public var timeZone: String? = nil
    public var duration: Double
    /// The text's start, or the call's name.
    public var title: String
    /// The first words spoken, which is what a list row shows. Empty until read; `title`
    /// stands in for it.
    public var firstLine = ""
    /// How many changes it holds: retries that changed words, fix edits and corrections.
    public var changes: Int
    /// Whether it has words to copy. A dictation listed always has; a call still recording
    /// or transcribing may not yet.
    public var hasText = true
    /// The recording the entry keeps, whether or not the file is still there.
    public var audioPath: String? = nil

    public var id: String { "\(kind.rawValue):\(ref)" }
}

/// One dictation or call, line by line, with everything that changed its words.
public struct HistoryDetail: Sendable, Equatable {
    public var entry: HistoryEntry
    /// The recording the play buttons read; nil when it is gone.
    public var audioPath: String?
    public var lines: [HistoryLine]
    /// Changes to all of the text rather than one line: a dictation's corrections, and a fix
    /// edit naming a line that isn't there.
    public var textChanges: [HistoryChange]

    /// Every change, line by line and then the text's own.
    public var allChanges: [HistoryChange] { lines.flatMap(\.changes) + textChanges }
}

/// A segment: whisper's text, its time in the recording, and what changed it.
public struct HistoryLine: Sendable, Equatable, Identifiable {
    public var id: Int
    /// "Me" or "Call" on a split call; nil for a dictation and for mixed audio.
    public var speaker: String?
    public var t0: Double
    public var t1: Double
    /// Whisper's text, before any retry, fix or correction.
    public var whisper: String
    /// The text as it reads now: after the retry, the fixes and any correction.
    public var text: String
    /// The retry signals marked it unsure.
    public var flagged: Bool
    public var changes: [HistoryChange]

    /// Worth hearing again: whisper was unsure of it, or something changed its words.
    public var playable: Bool { flagged || !changes.isEmpty }
}

/// One change to the words, from whichever step made it.
public struct HistoryChange: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable {
        case retry
        case fix
        case correction
        /// A key term a correction suggested, and Settings' Add or Dismiss on it: an event
        /// for the key-term list, kept beside the correction it came from, not an edit of
        /// the transcript.
        case keyTerm = "key term"
    }

    public var source: Source
    public var before: String
    public var after: String
    /// The words that differ, case counted.
    public var diff: WordDiff
    /// False for a fix edit that was checked and rejected.
    public var applied: Bool
    /// The key term a fix restored, why it was rejected, the client that corrected it, or
    /// what became of a suggested key term (added, dismissed, suggested).
    public var note: String?
    /// The stored row it was read from, as `table:id`: segment_retries, fix_edits or edits,
    /// or key_term_suggestions for a suggestion nothing has decided.
    public var record: String
    /// Whisper's confidence in the segment before and after a retry, 0 to 1; nil for a change
    /// no confidence was measured for.
    public var confidenceBefore: Double?
    public var confidenceAfter: Double?

    public var id: String { record }

    init(_ source: Source, before: String, after: String, applied: Bool = true, note: String? = nil,
         record: String, confidenceBefore: Double? = nil, confidenceAfter: Double? = nil) {
        self.confidenceBefore = confidenceBefore
        self.confidenceAfter = confidenceAfter
        self.source = source
        self.before = before
        self.after = after
        self.diff = WordDiff(before, after, ignoringCase: false)
        self.applied = applied
        self.note = note
        self.record = record
    }
}

extension CallStore {
    /// Dictations with text and calls, newest first. Calls that heard nothing are left out. With
    /// `matching`, only those the transcript search finds (the index `search_transcripts`
    /// reads) or whose text holds it anywhere, in any case. The index matches whole words and
    /// the start of the last one; the text match is what finds the middle of a word, so a
    /// word half typed never reads as no result.
    public func historyEntries(limit: Int = 200, matching query: String? = nil) throws -> [HistoryEntry] {
        let text = query?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        // The found recordings' ids as a JSON array for SQLite to read; nil when not searching.
        let found: String? = try text.map {
            String(decoding: try JSONEncoder().encode(try recordingsMatching($0, prefixOnLast: true).sorted()),
                   as: UTF8.self)
        }
        let like = text.map {
            "%" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
        }
        return try queue.sync {
            let dictations = try db.query("""
                SELECT d.id, d.created_at, d.duration, coalesce(d.corrected_text, d.final_text), d.time_zone, d.audio_path,
                  (SELECT count(*) FROM segment_retries r WHERE r.dictation_id = d.id AND r.kept = 1 AND r.changed = 1)
                  + (SELECT count(*) FROM fix_edits f WHERE f.dictation_id = d.id)
                  + (SELECT count(*) FROM edits e WHERE e.target = 'dictation:' || d.id)
                FROM dictations d WHERE d.duration >= ? AND coalesce(d.corrected_text, d.final_text) <> ''
                  AND (?3 IS NULL OR d.id IN (SELECT value FROM json_each(?3))
                       OR coalesce(d.corrected_text, d.final_text) LIKE ?4 ESCAPE '\\')
                ORDER BY d.created_at DESC LIMIT ?2
                """, [Dictation.tooShort, limit, found, like]) { row in
                HistoryEntry(kind: .dictation, ref: row.text(0), at: row.date(1), timeZone: row.string(4),
                             duration: row.double(2), title: Self.preview(row.text(3)), firstLine: Self.preview(row.text(3)),
                             changes: row.int(6), audioPath: row.string(5))
            }
            let calls = try db.query("""
                SELECT c.id, c.started_at, coalesce(c.ended_at, c.started_at) - c.started_at,
                  coalesce(c.title, c.app_name || ' call', 'Call'), c.time_zone, c.audio_path,
                  (SELECT count(*) FROM segment_retries r WHERE r.call_id = c.id AND r.kept = 1 AND r.changed = 1)
                  + (SELECT count(*) FROM edits e WHERE e.target LIKE 'call:' || c.id || '/segment:%'),
                  EXISTS (SELECT 1 FROM call_segments s WHERE s.call_id = c.id
                          AND trim(coalesce(s.corrected_text, s.text), ' ' || char(9, 10, 13)) <> ''),
                  (SELECT trim(coalesce(s.corrected_text, s.text)) FROM call_segments s WHERE s.call_id = c.id
                   AND trim(coalesce(s.corrected_text, s.text), ' ' || char(9, 10, 13)) <> ''
                   ORDER BY s.start_ms, s.id LIMIT 1)
                FROM calls c WHERE \(Self.heardSomething("c"))
                  AND (?2 IS NULL OR c.id IN (SELECT value FROM json_each(?2))
                       OR coalesce(c.title, '') LIKE ?3 ESCAPE '\\' OR EXISTS (
                         SELECT 1 FROM call_segments s WHERE s.call_id = c.id
                         AND coalesce(s.corrected_text, s.text) LIKE ?3 ESCAPE '\\'))
                ORDER BY c.started_at DESC LIMIT ?1
                """, [limit, found, like]) { row in
                HistoryEntry(kind: .call, ref: row.text(0), at: row.date(1), timeZone: row.string(4),
                             duration: row.double(2), title: row.text(3), firstLine: row.string(8).map(Self.preview) ?? "",
                             changes: row.int(6), hasText: row.int(7) != 0, audioPath: row.string(5))
            }
            return Array((dictations + calls).sorted { $0.at > $1.at }.prefix(limit))
        }
    }

    /// One entry's lines and changes, read in one go.
    public func historyDetail(_ entry: HistoryEntry) throws -> HistoryDetail? {
        try queue.sync {
            switch entry.kind {
            case .dictation: try dictationHistory(entry)
            case .call: try callHistory(entry)
            }
        }
    }

    private struct RetryRow {
        var id: Int64
        var key: Int64
        var first: String
        var retried: String?
        var flagged: Bool
        var kept: Bool
        var changed: Bool
        var logprobBefore: Double?
        var logprobAfter: Double?
    }

    private func retryRows(_ column: String, _ keyColumn: String, _ ref: String) throws -> [Int64: RetryRow] {
        let rows = try db.query("""
            SELECT id, \(keyColumn), first_text, retried_text, flagged, kept, changed, logprob_before, logprob_after
            FROM segment_retries WHERE \(column) = ? ORDER BY id
            """, [ref]) { row in
            RetryRow(id: row.int64(0), key: row.int64(1), first: row.text(2), retried: row.string(3),
                     flagged: row.int(4) != 0, kept: row.int(5) != 0, changed: row.int(6) != 0,
                     logprobBefore: row.optionalDouble(7), logprobAfter: row.optionalDouble(8))
        }
        return Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
    }

    private func retryChange(_ retry: RetryRow?) -> [HistoryChange] {
        guard let retry, retry.kept, retry.changed, let retried = retry.retried else { return [] }
        return [HistoryChange(.retry, before: retry.first, after: retried, record: "segment_retries:\(retry.id)",
                              confidenceBefore: retry.logprobBefore.map(exp), confidenceAfter: retry.logprobAfter.map(exp))]
    }

    /// Corrections and their undos, oldest first, each as the text it found and left, then
    /// the key terms those corrections suggested and what Settings did with them. Keyed by
    /// call segment id, or -1 for a dictation.
    private func correctionChanges(_ target: String) throws -> [Int64: [HistoryChange]] {
        let edits = try db.query("""
            SELECT id, client, old_value, new_value, target FROM edits
            WHERE (target = ?1 OR target LIKE ?1 || '/segment:%') AND kind IN ('correct_dictation', 'correct_segment', 'undo')
            ORDER BY id
            """, [target]) { row in
            (id: row.int64(0), client: row.string(1), before: Self.editText(row.string(2)),
             after: Self.editText(row.string(3)), target: row.text(4))
        }
        var byLine: [Int64: [HistoryChange]] = [:]
        var lineOfEdit: [Int64: Int64] = [:]
        for edit in edits {
            let line = edit.target.range(of: "/segment:").flatMap { Int64(edit.target[$0.upperBound...]) } ?? -1
            lineOfEdit[edit.id] = line
            byLine[line, default: []].append(HistoryChange(.correction, before: edit.before ?? "", after: edit.after ?? "",
                                                           note: edit.client, record: "edits:\(edit.id)"))
        }
        guard !edits.isEmpty else { return byLine }
        // A decision whose edit was undone reads as pending again, as list_key_term_suggestions has it.
        let suggestions = try db.query("""
            SELECT s.id, s.term, s.heard, s.edit_id,
              CASE WHEN e.undone_by IS NOT NULL THEN 'pending' ELSE s.status END,
              CASE WHEN e.undone_by IS NOT NULL THEN NULL ELSE s.decision_edit END
            FROM key_term_suggestions s LEFT JOIN edits e ON e.id = s.decision_edit
            WHERE s.edit_id IN (\(edits.map { String($0.id) }.joined(separator: ",")))
            ORDER BY s.id
            """) { row in
            (id: row.int64(0), term: row.text(1), heard: row.text(2).split(separator: "\u{1F}").first.map(String.init) ?? "",
             edit: row.int64(3), status: row.text(4), decision: row.isNull(5) ? nil : row.int64(5))
        }
        for suggestion in suggestions {
            let note = ["accepted": "added", "dismissed": "dismissed"][suggestion.status] ?? "suggested"
            let record = suggestion.decision.map { "edits:\($0)" } ?? "key_term_suggestions:\(suggestion.id)"
            byLine[lineOfEdit[suggestion.edit] ?? -1, default: []].append(
                HistoryChange(.keyTerm, before: suggestion.heard, after: suggestion.term, note: note, record: record))
        }
        return byLine
    }

    private func dictationHistory(_ entry: HistoryEntry) throws -> HistoryDetail? {
        guard let found = try db.query("SELECT audio_path, corrected_text FROM dictations WHERE id = ?", [entry.ref],
                                       { (audio: $0.string(0), corrected: $0.string(1)) }).first else { return nil }
        let audio = found.audio
        let segments = try db.query("""
            SELECT idx, t0, t1, text, avg_logprob FROM segments WHERE dictation_id = ? ORDER BY idx
            """, [entry.ref]) { (idx: $0.int64(0), t0: $0.double(1), t1: $0.double(2), text: $0.text(3), logprob: $0.double(4)) }
        let retries = try retryRows("dictation_id", "segment_idx", entry.ref)
        let fixes = try db.query("""
            SELECT id, segment_idx, span, replacement, key_term, char_offset, rejected
            FROM fix_edits WHERE dictation_id = ? ORDER BY idx
            """, [entry.ref]) { row in
            (id: row.int64(0), edit: FixEdit(segment: row.int(1), span: row.text(2), replacement: row.text(3),
                                             keyTerm: row.string(4), offset: row.optionalInt(5),
                                             rejected: row.string(6).flatMap(FixEdit.Rejection.init)))
        }
        let threshold = SegmentRetry().logprobBelow
        let texts = TargetedFix.apply(fixes.map(\.edit), toTexts: segments.map(\.text))
        var lines = segments.enumerated().map { index, s in
            let retry = retries[s.idx]
            return HistoryLine(id: Int(s.idx), speaker: nil, t0: s.t0, t1: s.t1, whisper: retry?.first ?? s.text,
                               text: texts[index], flagged: retry?.flagged ?? (s.logprob < threshold),
                               changes: retryChange(retry))
        }
        var textChanges: [HistoryChange] = []
        for fix in fixes {
            let edit = fix.edit
            let record = "fix_edits:\(fix.id)"
            let change: HistoryChange
            if edit.applied, lines.indices.contains(edit.segment) {
                let text = segments[edit.segment].text
                var alone = edit
                alone.segment = 0
                change = HistoryChange(.fix, before: text, after: TargetedFix.apply([alone], toTexts: [text])[0],
                                       note: edit.keyTerm, record: record)
            } else {
                // A rejected edit is shown as the model asked for it, with why it wasn't applied.
                change = HistoryChange(.fix, before: edit.span, after: edit.replacement, applied: edit.applied,
                                       note: edit.rejected?.rawValue ?? edit.keyTerm, record: record)
            }
            if lines.indices.contains(edit.segment) {
                lines[edit.segment].changes.append(change)
            } else {
                textChanges.append(change)
            }
        }
        textChanges += try correctionChanges("dictation:\(entry.ref)")[-1] ?? []
        // An agent's correction replaces the whole text, so the list, Copy and the detail all
        // show it. It no longer lines up with the segments, so the detail is one block over
        // the whole recording, which still plays from the start; the segments' own retry and
        // fix changes stay on it.
        if let corrected = found.corrected, let first = lines.first, let last = lines.last {
            lines = [HistoryLine(id: first.id, speaker: nil, t0: first.t0, t1: last.t1,
                                 whisper: lines.map(\.whisper).joined(separator: " "), text: corrected,
                                 flagged: false, changes: lines.flatMap(\.changes))]
        }
        return HistoryDetail(entry: entry, audioPath: audio, lines: lines, textChanges: textChanges)
    }

    private func callHistory(_ entry: HistoryEntry) throws -> HistoryDetail? {
        guard let call = try db.query("SELECT \(Self.callHistoryColumns) FROM calls WHERE id = ?", [entry.ref],
                                      { (audio: $0.string(0), speakers: $0.string(1)) }).first else { return nil }
        let speakers = call.speakers.map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init) }
        let segments = try db.query("""
            SELECT id, channel, start_ms, end_ms, text, avg_logprob, corrected_text FROM call_segments
            WHERE call_id = ? ORDER BY start_ms, id
            """, [entry.ref]) { row in
            (id: row.int64(0), channel: CallSegment.Channel(rawValue: row.text(1)) ?? .mix, start: row.int(2),
             end: row.int(3), text: row.text(4), logprob: row.optionalDouble(5), corrected: row.string(6))
        }
        let retries = try retryRows("call_id", "call_segment_id", entry.ref)
        let corrections = try correctionChanges("call:\(entry.ref)")
        let threshold = SegmentRetry().logprobBelow
        let lines = segments.map { s in
            let retry = retries[s.id]
            let speaker: String? = switch s.channel {
            case .me: speakers?.first ?? "Me"
            case .call: speakers?.last ?? "Call"
            case .mix: nil
            }
            return HistoryLine(id: Int(s.id), speaker: speaker, t0: Double(s.start) / 1000, t1: Double(s.end) / 1000,
                               whisper: retry?.first ?? s.text, text: s.corrected ?? s.text,
                               flagged: retry?.flagged ?? ((s.logprob ?? 0) < threshold),
                               changes: retryChange(retry) + (corrections[s.id] ?? []))
        }
        return HistoryDetail(entry: entry, audioPath: call.audio, lines: lines, textChanges: [])
    }

    private static let callHistoryColumns = "audio_path, speakers"

    private static func editText(_ json: String?) -> String? {
        json.flatMap { try? JSONDecoder().decode(Edit.Value.self, from: Data($0.utf8)) }?.text
    }

    static func preview(_ text: String) -> String {
        text.count > 80 ? String(text.prefix(80)) + "…" : text
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
