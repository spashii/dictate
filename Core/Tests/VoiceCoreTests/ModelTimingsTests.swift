import Foundation
import Testing
@testable import VoiceCore

@Suite struct ModelTimingsTests {
    private func file() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "timings-\(UUID().uuidString).sqlite")
        _ = try Store(url: url)
        return url
    }

    @Test func recordsAndReadsOldestFirst() throws {
        let url = try file()
        let now = Date()
        try ModelTimings.record(.init(createdAt: now, work: .fix, kind: .apple, outcome: .ok, totalMs: 900, modelMs: 700), at: url)
        try ModelTimings.record(.init(createdAt: now.addingTimeInterval(-60), work: .title, kind: .ollama, outcome: .empty,
                                      totalMs: 4000, modelMs: nil), at: url)
        try ModelTimings.record(.init(createdAt: now.addingTimeInterval(-40 * 24 * 3600), work: .fix, kind: .apple,
                                      outcome: .failed, totalMs: 1, modelMs: 1), at: url)
        let rows = try ModelTimings.read(url, now: now)
        #expect(rows.map(\.work) == [.title, .fix])
        #expect(rows[0].modelMs == nil)
        #expect(rows[1].totalMs == 900 && rows[1].modelMs == 700 && rows[1].outcome == .ok)
    }

    @Test func keepsTheNewestRows() throws {
        let url = try file()
        for i in 1...7 {
            try ModelTimings.record(.init(work: .fix, kind: .apple, outcome: .ok, totalMs: i, modelMs: i), at: url, keep: 5)
        }
        #expect(try ModelTimings.read(url).map(\.totalMs) == [3, 4, 5, 6, 7])
    }

    @Test func storesNoText() throws {
        let db = try SQLiteConnection(url: try file())
        let columns = try db.query("PRAGMA table_info(model_timings)") { $0.text(1) }
        #expect(columns == ["id", "created_at", "task", "model_kind", "outcome", "total_ms", "model_ms"])
    }

    @Test func rejectsAnUnknownTask() throws {
        let db = try SQLiteConnection(url: try file())
        #expect(throws: (any Error).self) {
            _ = try db.run("INSERT INTO model_timings (created_at, task, model_kind, outcome, total_ms) VALUES (0,'x','apple','ok',1)")
        }
    }

    @Test func retryDays() throws {
        let url = try file()
        let db = try SQLiteConnection(url: url)
        let now = Date()
        func row(_ at: Date, flagged: Int, retried: Bool, changed: Int, seconds: Double) throws {
            _ = try db.run("""
                INSERT INTO segment_retries (source, t0, t1, first_text, retried_text, logprob_before, flagged, kept,
                  retry_seconds, changed, created_at) VALUES ('dictation',0,1,'a',?,-1,?,1,?,?,?)
                """, [retried ? "b" : nil, flagged, seconds, changed, at.timeIntervalSince1970])
        }
        try row(now, flagged: 1, retried: true, changed: 1, seconds: 2)
        try row(now, flagged: 1, retried: false, changed: 0, seconds: 0)
        try row(now, flagged: 0, retried: false, changed: 0, seconds: 0)
        try row(now.addingTimeInterval(-3 * 24 * 3600), flagged: 1, retried: true, changed: 0, seconds: 4)
        try row(now.addingTimeInterval(-45 * 24 * 3600), flagged: 1, retried: true, changed: 1, seconds: 9)
        let result = try RetryStats.daily(url, now: now)
        #expect(result.days.count == 2)
        #expect(result.days.last.map { ($0.unsure, $0.retried, $0.changed) } ?? (0, 0, 0) == (2, 1, 1))
        #expect(result.retrySeconds.sorted() == [2, 4])
    }
}
