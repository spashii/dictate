import Foundation
import os

/// Moves the data folder from Application Support/Voice to Application Support/Dictate, once.
///
/// Only the app runs it, at launch before anything opens the database: renaming a folder
/// under an open SQLite file would split the file from its -wal and -shm. The move is one
/// rename(2) inside Application Support, so it is atomic and never a copy: it happens whole
/// or not at all, and a failure leaves Voice exactly as it was. Dictate wins whenever it
/// already exists, so nothing is ever merged or overwritten.
public enum DataMigration {
    public static let oldName = "Voice"
    public static let newName = "Dictate"
    /// Written inside the new folder after the move, so the migration never runs twice, even
    /// if a Voice folder reappears (an older build, a restored backup).
    public static let markerName = ".migrated-from-voice"

    public enum Outcome: Equatable, Sendable {
        case moved
        /// The marker is there, or there was no Voice folder to move.
        case nothingToDo
        /// Both folders exist. Neither is touched; Dictate is used.
        case bothExist
        case failed(String)
    }

    private static let log = Logger(subsystem: "io.github.spashii.voice", category: "migration")

    public static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
    }

    /// The folder to use: Dictate if it exists, else Voice if only that exists (not migrated
    /// yet, or the move failed), else Dictate, to be created.
    public static func resolve(in root: URL) -> URL {
        let new = root.appending(path: newName, directoryHint: .isDirectory)
        let old = root.appending(path: oldName, directoryHint: .isDirectory)
        let fm = FileManager.default
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) { return old }
        return new
    }

    /// `rename` is the one operation that changes the disk, injectable so a test can make it fail.
    @discardableResult
    public static func run(in root: URL = applicationSupport,
                           rename: (URL, URL) throws -> Void = { try moveItem($0, $1) }) -> Outcome {
        let outcome = migrate(in: root, rename: rename)
        switch outcome {
        case .moved: log.notice("Moved Application Support/Voice to Application Support/Dictate.")
        case .nothingToDo: break
        case .bothExist: log.notice("Application Support has both Voice and Dictate; left both alone and using Dictate.")
        case .failed(let reason): log.error("Couldn't move Application Support/Voice to Dictate, so Voice stays in use: \(reason, privacy: .public)")
        }
        return outcome
    }

    static func migrate(in root: URL, rename: (URL, URL) throws -> Void) -> Outcome {
        let fm = FileManager.default
        let new = root.appending(path: newName, directoryHint: .isDirectory)
        let old = root.appending(path: oldName, directoryHint: .isDirectory)
        if fm.fileExists(atPath: new.appending(path: markerName).path) {
            // Also retried on later launches, in case an earlier rewrite could not finish.
            rewriteAudioPaths(database: new.appending(path: "voice.sqlite"), from: old, to: new)
            return .nothingToDo
        }
        // A symlink at Voice (left by an earlier migration) isn't data to move.
        var isLink: Bool { (try? old.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
        guard fm.fileExists(atPath: old.path), !isLink else { return .nothingToDo }
        if fm.fileExists(atPath: new.path) { return .bothExist }
        do {
            try rename(old, new)
        } catch {
            return .failed("\(error)")
        }
        // Past this point the data has moved; neither step below can undo that.
        try? Data("\(Date())\n".utf8).write(to: new.appending(path: markerName))
        // Stored audio paths still name the Voice folder. They resolve through the link below
        // today, but the link is a courtesy that a user or a cleanup tool can delete, and
        // recovery compares paths to decide which recordings are orphans.
        rewriteAudioPaths(database: new.appending(path: "voice.sqlite"), from: old, to: new)
        // Agents and scripts that read the old token path keep working. It is a link, so
        // there is still one copy of the data.
        try? fm.createSymbolicLink(at: old, withDestinationURL: new)
        return .moved
    }

    /// Points every stored audio path under `old` at `new`. Safe to run again: rows already
    /// under `new` don't match. Tables that don't exist yet (an old database) are skipped.
    /// Returns how many rows changed.
    @discardableResult
    static func rewriteAudioPaths(database: URL, from old: URL, to new: URL) -> Int {
        guard isSQLiteFile(database), let db = try? SQLiteConnection(url: database) else { return 0 }
        let oldPrefix = old.path + "/"
        let newPrefix = new.path + "/"
        do {
            return try db.transaction {
                var changed = 0
                for table in ["dictations", "calls"] {
                    let exists = try db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [table]) { $0.int(0) }
                    guard !exists.isEmpty else { continue }
                    changed += try db.run("""
                        UPDATE \(table) SET audio_path = ? || substr(audio_path, ?)
                        WHERE audio_path IS NOT NULL AND substr(audio_path, 1, ?) = ?
                        """, [newPrefix, oldPrefix.count + 1, oldPrefix.count, oldPrefix])
                }
                return changed
            }
        } catch {
            log.error("Couldn't rewrite stored audio paths: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    /// Opening anything else with SQLite would treat its neighbours (-wal) as that database's.
    private static func isSQLiteFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 15)).map { String(decoding: $0, as: UTF8.self) == "SQLite format 3" } ?? false
    }

    public static func moveItem(_ from: URL, _ to: URL) throws {
        // rename(2) refuses to replace a non-empty folder and never copies across volumes;
        // FileManager.moveItem would fall back to copying.
        guard Foundation.rename(from.path, to.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
    }
}
