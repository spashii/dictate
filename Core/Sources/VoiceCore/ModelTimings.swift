import Foundation

/// How long the intelligence model takes, one row per title and per fix, so Advanced can chart
/// it. Numbers only: no text, name or id is stored, and nothing leaves the Mac. The insert
/// keeps the newest `keep` rows.
public enum ModelTimings {
    public enum Work: String, Sendable, CaseIterable { case title, fix }
    public enum Kind: String, Sendable { case apple, ollama }
    /// `empty`: the model answered and nothing usable came of it.
    public enum Outcome: String, Sendable { case ok, failed, cancelled, empty }

    public struct Entry: Sendable, Equatable {
        public var createdAt: Date
        public var work: Work
        public var kind: Kind
        public var outcome: Outcome
        /// From when the model was needed to when it was done, waiting included.
        public var totalMs: Int
        /// The model's own call.
        public var modelMs: Int?

        public init(createdAt: Date = Date(), work: Work, kind: Kind, outcome: Outcome, totalMs: Int, modelMs: Int?) {
            self.createdAt = createdAt
            self.work = work
            self.kind = kind
            self.outcome = outcome
            self.totalMs = totalMs
            self.modelMs = modelMs
        }
    }

    public static let keep = 2000

    /// A failure to record is the caller's to ignore: a measurement never fails the work.
    public static func record(_ entry: Entry, at url: URL, keep: Int = ModelTimings.keep) throws {
        let db = try SQLiteConnection(url: url)
        try db.transaction {
            _ = try db.run("""
                INSERT INTO model_timings (created_at, task, model_kind, outcome, total_ms, model_ms)
                VALUES (?,?,?,?,?,?)
                """, [entry.createdAt.timeIntervalSince1970, entry.work.rawValue, entry.kind.rawValue,
                      entry.outcome.rawValue, entry.totalMs, entry.modelMs])
            _ = try db.run("""
                DELETE FROM model_timings WHERE id NOT IN (SELECT id FROM model_timings ORDER BY id DESC LIMIT ?)
                """, [keep])
        }
    }

    /// Oldest first, since `days` ago. Read through its own connection, so the app can call it
    /// off the main thread.
    public static func read(_ url: URL, days: Int = 30, now: Date = Date()) throws -> [Entry] {
        let db = try SQLiteConnection(url: url)
        let from = now.addingTimeInterval(-Double(days) * 24 * 3600).timeIntervalSince1970
        return try db.query("""
            SELECT created_at, task, model_kind, outcome, total_ms, model_ms FROM model_timings
            WHERE created_at >= ? ORDER BY created_at, id
            """, [from]) { row -> Entry? in
            guard let work = Work(rawValue: row.text(1)), let kind = Kind(rawValue: row.text(2)),
                  let outcome = Outcome(rawValue: row.text(3)) else { return nil }
            return Entry(createdAt: row.date(0), work: work, kind: kind, outcome: outcome,
                         totalMs: row.int(4), modelMs: row.optionalInt(5))
        }.compactMap { $0 }
    }
}

extension CallTitler {
    /// `title`, timed from `since` (when the call needed a name) and recorded once a model is
    /// asked. A call that cannot be titled in the first place records nothing.
    public func timedTitle(_ callID: String, in store: CallStore, models: [any TitleModel], kind: ModelTimings.Kind,
                           since: ContinuousClock.Instant) async -> String? {
        guard isEligible(callID, in: store) else { return nil }
        return await timed(.call, callID, force: false, in: store, models: models, kind: kind, since: since)
    }

    /// `retitle`, timed the same way. A recording with too little text records nothing.
    public func timedRetitle(_ recording: HistoryEntry.Kind, _ ref: String, in store: CallStore,
                             models: [any TitleModel], kind: ModelTimings.Kind,
                             since: ContinuousClock.Instant) async -> String? {
        guard canTitle(recording, ref, in: store) else { return nil }
        return await timed(recording, ref, force: true, in: store, models: models, kind: kind, since: since)
    }

    private func timed(_ recording: HistoryEntry.Kind, _ ref: String, force: Bool, in store: CallStore,
                       models: [any TitleModel], kind: ModelTimings.Kind, since: ContinuousClock.Instant) async -> String? {
        let began = ContinuousClock.now
        let attempt = await attempt(recording, ref, force: force, in: store, models: models)
        let now = ContinuousClock.now
        let outcome: ModelTimings.Outcome = attempt.title != nil ? .ok
            : Task.isCancelled ? .cancelled : attempt.failed ? .failed : .empty
        let entry = ModelTimings.Entry(work: .title, kind: kind, outcome: outcome,
                                       totalMs: (now - since).milliseconds, modelMs: (now - began).milliseconds)
        try? ModelTimings.record(entry, at: store.url)
        return attempt.title
    }
}

extension Duration {
    var milliseconds: Int {
        let parts = components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}
