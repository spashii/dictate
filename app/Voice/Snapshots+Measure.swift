#if DEBUG
import AppKit
import SQLite3
import SwiftUI
import VoiceCore

/// The shots of About with Developer mode on and of the Advanced pane, with made-up numbers
/// in a temporary file. Numbers only.
extension Snapshots {
    static func measureShots(_ model: AppModel, into folder: URL, suffix: String, dark: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "dictate-measure-shots-\(UUID().uuidString).sqlite")
        defer { for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + ext) } }
        try seedMeasurements(file)
        model.preferences.developerMode = true
        defer { model.preferences.developerMode = false }
        await write(folder, "about-developer-\(suffix)", try await aboutWindow(model, dark: dark))
        await write(folder, "advanced-\(suffix)", try await settingsPane(
            model, .advanced, AdvancedPane(database: file), size: NSSize(width: 1060, height: 1060), dark: dark))
    }

    /// About 60 model timings and 40 retry records over 30 days, from a fixed sequence.
    private static func seedMeasurements(_ file: URL) throws {
        _ = try Store(url: file)
        var state: UInt64 = 20_261_113
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 33) / Double(1 << 31)
        }
        let now = Date()
        for index in 0..<60 {
            let fix = index % 3 != 0
            let ollama = index % 4 == 0
            let model = ollama ? 2.0 + next() * 5 : 0.4 + next() * 1.2
            let total = fix ? model + 0.4 + next() * 0.5 : model + (ollama ? 4 * next() * next() : 0.5 * next()) + (next() < 0.2 ? 25 * next() : 0)
            let outcome: ModelTimings.Outcome = index == 11 || index == 37 ? .failed : (!fix && index % 17 == 0 ? .empty : .ok)
            let at = now.addingTimeInterval(-Double(index) / 60 * 29 * 24 * 3600 - next() * 3600)
            try ModelTimings.record(.init(createdAt: at, work: fix ? .fix : .title, kind: ollama ? .ollama : .apple, outcome: outcome,
                                          totalMs: Int(total * 1000), modelMs: Int(model * 1000)), at: file)
        }
        var handle: OpaquePointer?
        guard sqlite3_open(file.path, &handle) == SQLITE_OK else { return }
        defer { sqlite3_close(handle) }
        for index in 0..<40 {
            let at = now.addingTimeInterval(-Double(index % 22) * 24 * 3600 * 1.3 - next() * 20_000).timeIntervalSince1970
            let retried = next() < 0.8
            let changed = retried && next() < 0.35
            let sql = """
                INSERT INTO segment_retries (source, t0, t1, first_text, retried_text, logprob_before, logprob_after, flagged, kept,
                  retry_seconds, changed, created_at, skipped)
                VALUES ('dictation', 0, 1, '', \(retried ? "''" : "NULL"), -1.2, \(retried ? "-0.6" : "NULL"), 1, \(retried ? 1 : 0),
                  \(retried ? 0.6 + next() * 2.4 : 0), \(changed ? 1 : 0), \(at), \(retried ? "NULL" : "'budget'"))
                """
            sqlite3_exec(handle, sql, nil, nil, nil)
        }
    }
}
#endif
