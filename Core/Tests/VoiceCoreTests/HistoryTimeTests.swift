import SQLite3
import XCTest
@testable import VoiceCore

/// Recording times: stored as an instant and the zone they were made in, shown as the clock
/// of that zone, or as elapsed time.
final class HistoryTimeTests: StoreTestCase {
    private let amsterdam = TimeZone(identifier: "Europe/Amsterdam")!
    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!
    /// 2026-11-12 20:20:04 UTC: 21:20:04 in Amsterdam and 01:50:04 the next day in Kolkata.
    private let start = Date(timeIntervalSince1970: 1_794_514_804)

    // MARK: Storage

    func testAMigratedRowKeepsItsInstantAndHasNoZone() throws {
        let call = dir.appending(path: "old.sqlite")
        do {
            let before = try CallStore(url: call)
            try before.createCall(NewCall(id: "old-call", startedAt: start, split: true))
            try Store(url: call).insert(try dictation("old-dictation"))
        }
        // The file as an earlier version left it: no zone column, zones-1 not yet applied.
        try raw(call, """
            ALTER TABLE calls DROP COLUMN time_zone;
            ALTER TABLE dictations DROP COLUMN time_zone;
            DELETE FROM voice_migrations WHERE name = 'zones-1';
            """)

        let opened = try CallStore(url: call)

        XCTAssertTrue(try opened.appliedMigrations().contains("zones-1"))
        let migrated = try XCTUnwrap(try opened.call("old-call"))
        XCTAssertEqual(migrated.startedAt, start)
        XCTAssertNil(migrated.timeZone, "unknown is NULL, never a guess")
        XCTAssertNil(try opened.dictation("old-dictation")?.timeZone)
        let entries = try opened.historyEntries()
        XCTAssertEqual(entries.first { $0.ref == "old-call" }?.at, start)
        XCTAssertTrue(entries.allSatisfy { $0.timeZone == nil })
        // Unknown reads as the current zone, so nothing is labelled.
        XCTAssertNil(HistoryTime.originalZoneLabel(at: start, zone: nil, current: kolkata))
        XCTAssertEqual(HistoryTime.line(start: start, offset: 0, zone: nil, mode: .clock, current: amsterdam), "21:20:04")
        XCTAssertEqual(HistoryTime.line(start: start, offset: 0, zone: nil, mode: .clock, current: kolkata), "01:50:04")
    }

    func testANewCallStoresItsInstantAndTheZoneItWasRecordedIn() throws {
        let calls = try CallStore(url: databaseURL)
        let before = Date()

        let made = try calls.createCall(NewCall(id: "now", split: false))
        _ = try calls.createCall(NewCall(id: "away", startedAt: start, timeZone: "Asia/Kolkata", split: false))

        XCTAssertEqual(made.timeZone, TimeZone.current.identifier)
        XCTAssertLessThan(abs(made.startedAt.timeIntervalSince(before)), 5)
        XCTAssertEqual(try calls.call("away")?.timeZone, "Asia/Kolkata")
        XCTAssertEqual(try calls.call("away")?.startedAt, start)
    }

    func testANewDictationStoresItsZoneAndAnImportedOneHasNone() throws {
        var recorded = try dictation("recorded")
        recorded.timeZone = "America/New_York"
        try store.insert(recorded)
        try store.insert(try dictation("legacy"))
        let calls = try CallStore(url: databaseURL)

        XCTAssertEqual(try calls.dictation("recorded")?.timeZone, "America/New_York")
        XCTAssertEqual(store.recent(10).first { $0.id == "recorded" }?.timeZone, "America/New_York")
        XCTAssertNil(try calls.dictation("legacy")?.timeZone)
        XCTAssertEqual(try calls.historyEntries().first { $0.ref == "recorded" }?.timeZone, "America/New_York")

        // A row that only keeps its audio: made now it has this Mac's zone, recovered it has none.
        let fresh = Dictation(audio: dir.appending(path: "a.wav"), duration: 0.1, mode: .plain, whisperModel: "m",
                              error: "Too short.")
        let found = Dictation(audio: dir.appending(path: "b.wav"), createdAt: start, duration: 0.1, mode: .plain,
                              whisperModel: "m", error: "Too short.", origin: .recovered)
        XCTAssertEqual(fresh.timeZone, TimeZone.current.identifier)
        XCTAssertNil(found.timeZone)

        // A retry puts a row back at its original time and zone.
        try store.insert(try dictation("retry"))
        store.setOrigin("retry", nil, createdAt: start, timeZone: "Asia/Kolkata")
        XCTAssertEqual(try calls.dictation("retry")?.timeZone, "Asia/Kolkata")
        store.setOrigin("retry", .recovered, createdAt: start)
        XCTAssertNil(try calls.dictation("retry")?.timeZone)
    }

    // MARK: Formatting

    func testClockTimeIsTheCallStartPlusTheOffsetOnTheWallClock() {
        let at = { (offset: Double, zone: String?, current: TimeZone) in
            HistoryTime.line(start: self.start, offset: offset, zone: zone, mode: .clock, current: current)
        }
        XCTAssertEqual(at(0, "Europe/Amsterdam", amsterdam), "21:20:04")
        XCTAssertEqual(at(9, "Europe/Amsterdam", amsterdam), "21:20:13")
        XCTAssertEqual(at(3600 + 56, "Europe/Amsterdam", amsterdam), "22:21:00")
        XCTAssertEqual(at(0, "Asia/Kolkata", amsterdam), "01:50:04", "the clock of where it was recorded")
        XCTAssertEqual(at(0, "Garbage/Zone", kolkata), "01:50:04", "an unknown zone name reads as the current one")
        XCTAssertEqual(at(0, "UTC", amsterdam), "20:20:04")
        // Past midnight it wraps.
        XCTAssertEqual(at(3 * 3600 + 40 * 60, "Europe/Amsterdam", amsterdam), "01:00:04")
    }

    func testElapsedTimeCountsFromTheStart() {
        let at = { (offset: Double) in
            HistoryTime.line(start: self.start, offset: offset, zone: "Asia/Kolkata", mode: .elapsed, current: self.amsterdam)
        }
        XCTAssertEqual(at(0), "0:00")
        XCTAssertEqual(at(9), "0:09")
        XCTAssertEqual(at(125), "2:05")
        XCTAssertEqual(at(3723), "1:02:03")
    }

    func testTheZoneShowsOnlyWhenItDiffersFromTheCurrentOne() {
        XCTAssertNil(HistoryTime.originalZoneLabel(at: start, zone: "Europe/Amsterdam", current: amsterdam))
        XCTAssertNil(HistoryTime.originalZoneLabel(at: start, zone: nil, current: amsterdam))
        XCTAssertNil(HistoryTime.originalZoneLabel(at: start, zone: "Europe/Berlin", current: amsterdam),
                     "a different city on the same clock says nothing more")
        XCTAssertEqual(HistoryTime.originalZoneLabel(at: start, zone: "Asia/Kolkata", current: amsterdam), "IST")
        XCTAssertEqual(HistoryTime.originalZoneLabel(at: start, zone: "Europe/Amsterdam", current: kolkata), "CET")
        XCTAssertEqual(HistoryTime.originalZoneLabel(at: start, zone: "America/New_York", current: amsterdam), "EST")
    }

    func testASavedRecordingIsNamedByItsWallClockStartAndKind() {
        XCTAssertEqual(HistoryTime.fileName(start: start, zone: "Europe/Amsterdam", kind: .call, current: kolkata),
                       "2026-11-12 21.20.04 Call")
        XCTAssertEqual(HistoryTime.fileName(start: start, zone: nil, kind: .dictation, current: kolkata),
                       "2026-11-13 01.50.04 Dictation")
    }

    // MARK: Helpers

    private func raw(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for statement in sql.split(separator: ";") where !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            XCTAssertEqual(sqlite3_exec(db, String(statement), nil, nil, nil), SQLITE_OK, "\(statement)")
        }
    }
}

/// Save As copies the recording as stored, under a name made from its start.
final class HistorySaveAudioTests: StoreTestCase {
    private let start = Date(timeIntervalSince1970: 1_794_514_804)

    private func entry(_ audio: URL?, kind: HistoryEntry.Kind) -> HistoryEntry {
        HistoryEntry(kind: kind, ref: "x", at: start, timeZone: "Europe/Amsterdam", duration: 5, title: "t", changes: 0,
                     audioPath: audio?.path)
    }

    func testTheNameAndFormatFollowTheStoredFile() throws {
        let m4a = dir.appending(path: "1.m4a")
        let wav = dir.appending(path: "2.wav")
        try Data([1]).write(to: m4a)
        try Data([2]).write(to: wav)

        XCTAssertEqual(entry(m4a, kind: .call).suggestedAudioName, "2026-11-12 21.20.04 Call.m4a")
        XCTAssertEqual(entry(wav, kind: .dictation).suggestedAudioName, "2026-11-12 21.20.04 Dictation.wav")
    }

    func testAMissingFileCannotBeSaved() throws {
        let gone = entry(dir.appending(path: "gone.m4a"), kind: .call)

        XCTAssertNil(gone.audioFile)
        XCTAssertNil(gone.suggestedAudioName)
        XCTAssertNil(entry(nil, kind: .dictation).audioFile)
        XCTAssertThrowsError(try gone.saveAudio(to: dir.appending(path: "out.m4a")))
    }

    func testSavingCopiesTheBytesAndReplacesAnExistingFile() throws {
        let source = dir.appending(path: "call.m4a")
        let bytes = Data((0..<1000).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let target = dir.appending(path: "saved.m4a")

        try entry(source, kind: .call).saveAudio(to: target)
        XCTAssertEqual(try Data(contentsOf: target), bytes)

        try Data([9, 9]).write(to: target)
        try entry(source, kind: .call).saveAudio(to: target)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes, "the stored recording is untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".") }
            .filter { $0 != ".DS_Store" && !$0.hasPrefix("voice.sqlite") }, [], "no staging file is left behind")
    }
}
