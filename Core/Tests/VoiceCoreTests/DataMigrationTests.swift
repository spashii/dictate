import Foundation
import Testing
@testable import VoiceCore

/// Every test works in its own temporary Application Support; none touches the real one.
@Suite struct DataMigrationTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "dictate-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeVoice(in root: URL) throws {
        let voice = root.appending(path: "Voice", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: voice.appending(path: "recordings"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: voice.appending(path: "voice.sqlite"))
        try Data("wal".utf8).write(to: voice.appending(path: "voice.sqlite-wal"))
        try Data("a".utf8).write(to: voice.appending(path: "recordings/1.wav"))
        try Data(String(repeating: "ab", count: 32).utf8).write(to: voice.appending(path: "mcp-token"))
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func movesTheFolderWithEverythingInIt() throws {
        let root = try root()
        try makeVoice(in: root)

        #expect(DataMigration.run(in: root) == .moved)

        let dictate = root.appending(path: "Dictate")
        #expect(text(dictate.appending(path: "voice.sqlite")) == "db")
        #expect(text(dictate.appending(path: "voice.sqlite-wal")) == "wal")
        #expect(text(dictate.appending(path: "recordings/1.wav")) == "a")
        #expect(FileManager.default.fileExists(atPath: dictate.appending(path: DataMigration.markerName).path))
        #expect(DataMigration.resolve(in: root).lastPathComponent == "Dictate")
    }

    @Test func theOldTokenPathStillReadsTheSameToken() throws {
        let root = try root()
        try makeVoice(in: root)
        DataMigration.run(in: root)

        let old = text(root.appending(path: "Voice/mcp-token"))
        #expect(old != nil)
        #expect(old == text(root.appending(path: "Dictate/mcp-token")))
    }

    @Test func aSecondLaunchDoesNothing() throws {
        let root = try root()
        try makeVoice(in: root)
        #expect(DataMigration.run(in: root) == .moved)
        try Data("new".utf8).write(to: root.appending(path: "Dictate/voice.sqlite"))

        #expect(DataMigration.run(in: root) == .nothingToDo)
        #expect(text(root.appending(path: "Dictate/voice.sqlite")) == "new")
    }

    @Test func aVoiceFolderThatReappearsAfterwardsIsNotMovedAgain() throws {
        let root = try root()
        try makeVoice(in: root)
        DataMigration.run(in: root)
        try FileManager.default.removeItem(at: root.appending(path: "Voice"))
        try makeVoice(in: root)

        #expect(DataMigration.run(in: root) == .nothingToDo)
        #expect(text(root.appending(path: "Voice/voice.sqlite")) == "db")
    }

    @Test func whenBothExistNeitherIsTouched() throws {
        let root = try root()
        try makeVoice(in: root)
        let dictate = root.appending(path: "Dictate", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dictate, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: dictate.appending(path: "voice.sqlite"))

        #expect(DataMigration.run(in: root) == .bothExist)

        #expect(text(dictate.appending(path: "voice.sqlite")) == "mine")
        #expect(text(root.appending(path: "Voice/voice.sqlite")) == "db")
        #expect(!FileManager.default.fileExists(atPath: dictate.appending(path: DataMigration.markerName).path))
        #expect(DataMigration.resolve(in: root).lastPathComponent == "Dictate")
    }

    @Test func aMissingVoiceFolderIsLeftAlone() throws {
        let root = try root()

        #expect(DataMigration.run(in: root) == .nothingToDo)

        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Dictate").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Voice").path))
        #expect(DataMigration.resolve(in: root).lastPathComponent == "Dictate")
    }

    @Test func aFailedMoveLosesNothingAndKeepsUsingVoice() throws {
        struct Boom: Error {}
        let root = try root()
        try makeVoice(in: root)

        let outcome = DataMigration.run(in: root, rename: { _, _ in throw Boom() })

        guard case .failed = outcome else { Issue.record("expected a failure, got \(outcome)"); return }
        #expect(text(root.appending(path: "Voice/voice.sqlite")) == "db")
        #expect(text(root.appending(path: "Voice/recordings/1.wav")) == "a")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Dictate").path))
        #expect(DataMigration.resolve(in: root).lastPathComponent == "Voice")

        // The next launch can still do it.
        #expect(DataMigration.run(in: root) == .moved)
        #expect(text(root.appending(path: "Dictate/voice.sqlite")) == "db")
    }

    @Test func theRealRenameFailsCleanlyWhenTheFolderCannotMove() throws {
        let root = try root()
        try makeVoice(in: root)
        // A read-only parent makes rename(2) fail for real.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        guard case .failed = DataMigration.run(in: root) else { Issue.record("expected a failure"); return }

        #expect(text(root.appending(path: "Voice/voice.sqlite")) == "db")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Dictate").path))
    }
}
