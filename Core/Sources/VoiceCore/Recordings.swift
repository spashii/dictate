import Foundation

extension CallStore {
    /// The table and id a `dictation:ID` or `call:ID` target names.
    static func recordingRow(_ target: String) throws -> (String, String) {
        if target.hasPrefix("dictation:") { return ("dictations", String(target.dropFirst("dictation:".count))) }
        if target.hasPrefix("call:") { return ("calls", String(target.dropFirst("call:".count))) }
        throw VoiceError.store("\(target) can't be renamed.")
    }

    /// A person's title is `user`; an agent's, or anyone else's, is `agent`.
    static func titleSource(client: String?) -> TitleSource {
        client == Edit.personClient ? .user : .agent
    }

    /// A call's or dictation's title and who set it, as stored; nil when no such recording exists.
    public func recordingTitle(_ kind: HistoryEntry.Kind, _ ref: String) throws -> (title: String?, source: TitleSource?)? {
        let table = kind == .call ? "calls" : "dictations"
        return try queue.sync {
            try db.query("SELECT title, title_source FROM \(table) WHERE id = ?", [ref],
                         { (title: $0.string(0), source: $0.string(1).flatMap(TitleSource.init(rawValue:))) }).first
        }
    }

    /// Gives a recording a title, or takes it away with nil or blank text. Recorded as an
    /// edit so an agent sees it and `undo_edit` reverts it. Nil when nothing changed. The title's
    /// source is `source`, else follows the client, also when the title is cleared, so an
    /// automatic title never comes back over one a person took away. An explicit source on an
    /// unchanged title still marks it, without an edit.
    @discardableResult
    public func rename(_ kind: HistoryEntry.Kind, _ ref: String, to title: String?, client: String? = Edit.personClient,
                       source: TitleSource? = nil) throws -> Edit? {
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let target = kind == .call ? Edit.target(call: ref) : Edit.target(dictation: ref)
        return try queue.sync {
            try db.transaction { () -> Edit? in
                let (table, id) = try Self.recordingRow(target)
                guard let row = try db.query("SELECT title, title_source FROM \(table) WHERE id = ?", [id],
                                             { ($0.string(0), $0.string(1)) }).first else {
                    throw VoiceError.store("No \(kind.rawValue) \(ref).")
                }
                let current = row.0
                let newSource = (source ?? Self.titleSource(client: client)).rawValue
                guard (current ?? "") != (name ?? "") else {
                    if source != nil, name != nil, row.1 != newSource {
                        try db.run("UPDATE \(table) SET title_source = ? WHERE id = ?", [newSource, id])
                    }
                    return nil
                }
                try db.run("UPDATE \(table) SET title = ?, title_source = ? WHERE id = ?", [name, newSource, id])
                return try insertEdit(.renameRecording, target: target, client: client,
                                      before: Edit.Value(text: current, source: row.1),
                                      after: Edit.Value(text: name, source: newSource))
            }
        }
    }

    /// Removes a dictation or call and everything kept for it: its segments, retries, fix
    /// edits, tags, the edits made to it (the key terms they suggested stay, since the terms
    /// are still wanted) and its search entries, then the audio file unless another row
    /// points at it. A call that is still recording or being transcribed is refused: its
    /// audio is what a rebuild reads.
    public func deleteRecording(_ kind: HistoryEntry.Kind, _ ref: String) throws {
        let audio: String? = try queue.sync {
            try db.transaction { () -> String? in
                let path: String?
                switch kind {
                case .call:
                    guard let row = try db.query("SELECT audio_path, status FROM calls WHERE id = ?", [ref],
                                                 { (path: $0.string(0), status: $0.text(1)) }).first else { return nil }
                    if Call.Status(rawValue: row.status)?.isLive == true {
                        throw VoiceError.store("Stop the recording before deleting it.")
                    }
                    path = row.path
                    // Foreign keys are off in SQLite by default, so the children go explicitly.
                    for child in ["call_segments", "call_tags", "segment_retries"] {
                        try db.run("DELETE FROM \(child) WHERE call_id = ?", [ref])
                    }
                    try db.run("DELETE FROM edits WHERE target = ?1 OR target LIKE ?1 || '/segment:%'",
                               [Edit.target(call: ref)])
                    try db.run("DELETE FROM calls WHERE id = ?", [ref])
                case .dictation:
                    guard let found = try db.query("SELECT audio_path FROM dictations WHERE id = ?", [ref],
                                                   { $0.string(0) }).first else { return nil }
                    path = found
                    for child in ["segments", "segment_retries", "fix_edits"] {
                        try db.run("DELETE FROM \(child) WHERE dictation_id = ?", [ref])
                    }
                    try db.run("DELETE FROM edits WHERE target = ?", [Edit.target(dictation: ref)])
                    try db.run("DELETE FROM dictations WHERE id = ?", [ref])
                }
                return path
            }
        }
        guard let audio else { return }
        let shared = try queue.sync {
            try db.query("""
                SELECT 1 WHERE EXISTS (SELECT 1 FROM dictations WHERE audio_path = ?1)
                  OR EXISTS (SELECT 1 FROM calls WHERE audio_path = ?1)
                """, [audio]) { _ in 1 }.isEmpty == false
        }
        if !shared { try? FileManager.default.removeItem(atPath: audio) }
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
