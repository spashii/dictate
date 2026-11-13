import AVFoundation
import CryptoKit
import Foundation

/// Why a file can't be imported, in words for the person who chose it.
public struct AudioImportError: Error, CustomStringConvertible {
    public let description: String

    init(_ description: String) { self.description = description }
}

/// Checks and stores an audio or video file that becomes a one-track call.
public enum AudioImport {
    /// Lower case, without the dot.
    public static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "aifc", "caf", "aac", "flac", "m4b"]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    public static let supportedExtensions = audioExtensions.union(videoExtensions)

    /// Larger files are refused: the copy kept beside the calls would be as large.
    public static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024

    static let unreadable = "Dictate couldn't read this file's audio."
    static let noAudio = "This file has no audio Dictate can read."

    /// The file a path names, with symlinks resolved, once it is known to be a readable
    /// audio or video file of a size Dictate takes. The path is absolute or starts with `~/`.
    public static func validate(path: String) throws -> URL {
        guard !path.contains("\0") else { throw AudioImportError("That isn't a valid file path.") }
        let expanded: String
        if path.hasPrefix("~/") {
            expanded = NSHomeDirectory() + String(path.dropFirst())
        } else if path.hasPrefix("/") {
            expanded = path
        } else {
            throw AudioImportError("Use the full path to the file, starting with / or ~/.")
        }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        guard !isInsideOwnFolders(url) else { throw AudioImportError("Dictate's own files can't be imported.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AudioImportError("No file at \(expanded).")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard !isDirectory.boolValue, attributes?[.type] as? FileAttributeType == .typeRegular else {
            throw AudioImportError("\(expanded) is not a file.")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw AudioImportError("Dictate can't read \(expanded).")
        }
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw AudioImportError("Only audio and video files can be imported.")
        }
        if let size = (attributes?[.size] as? NSNumber)?.int64Value, size > maxBytes {
            throw AudioImportError("Files over 2 GB can't be imported.")
        }
        return url
    }

    /// The file's SHA-256 in hex, read a megabyte at a time so a long recording never sits
    /// in memory.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let more = try autoreleasepool { () -> Bool in
                guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { return false }
                hash.update(data: data)
                return true
            }
            if !more { break }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Dictate's own data folders. Anything else under ~/Library, such as Voice Memos, may be imported.
    private static func isInsideOwnFolders(_ url: URL) -> Bool {
        let support = DataMigration.applicationSupport
        let folders = [Paths.support, support.appending(path: "Dictate", directoryHint: .isDirectory),
                       support.appending(path: "Voice", directoryHint: .isDirectory)]
        // A folder that doesn't exist yet can't be resolved the way one that does is, so a
        // path is compared both as written and with its symlinks resolved.
        let paths = [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
        let roots = folders.flatMap { [$0.standardizedFileURL.path, $0.standardizedFileURL.resolvingSymlinksInPath().path] }
        // APFS ignores case by default, so /users/x/Library/... names the same folder.
        return paths.contains { path in
            roots.contains { root in
                let (a, b) = (path.lowercased(), root.lowercased())
                return a == b || a.hasPrefix(b + "/")
            }
        }
    }

    /// Opens `url` and fails unless it is a regular file of a size Dictate takes, judged on the open
    /// descriptor so a path swapped for a pipe or a device after validation can't make the copy or
    /// the hash wait for ever. The descriptor stays non-blocking until it is copied from, so the
    /// path is opened once and what was checked is what is copied. The caller closes it.
    static func openRegularFile(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { throw AudioImportError("Dictate can't read \(url.path).") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw AudioImportError("\(url.path) is not a file.")
        }
        guard Int64(info.st_size) <= maxBytes else {
            close(descriptor)
            throw AudioImportError("Files over 2 GB can't be imported.")
        }
        return descriptor
    }

    /// Writes the open file to `partial`, which the caller renames once the row exists, so a quit
    /// mid-copy never leaves something that looks like audio. On APFS the copy is a clone.
    static func copy(descriptor: Int32, to partial: URL) throws {
        try? FileManager.default.removeItem(at: partial)
        if fclonefileat(descriptor, AT_FDCWD, partial.path, 0) == 0 { return }
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) }
        let output = open(partial.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard output >= 0 else { throw AudioImportError("Dictate couldn't copy this file.") }
        defer { close(output) }
        guard fcopyfile(descriptor, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
            try? FileManager.default.removeItem(at: partial)
            throw AudioImportError("Dictate couldn't copy this file.")
        }
    }

    /// What `prepare` made of a stored copy: the file to read and the length of its audio.
    struct Prepared {
        var url: URL
        var duration: Double
        /// The raw copy an export replaced. The caller removes it once the call's path names `url`,
        /// so a quit before that still finds a copy the row points at.
        var superseded: URL?
    }

    /// Makes sure the stored copy can be read as audio. A copy AVAudioFile opens and that has no
    /// video stays as it is; anything else is reduced to its audio track as AAC in an .m4a beside
    /// it. Nothing is left behind when this throws, and a cancellation is rethrown as it is.
    static func prepare(copy: URL) async throws -> Prepared {
        do {
            if let opened = try? AVAudioFile(forReading: copy), !(await hasVideo(copy)) {
                guard opened.length > 0 else { throw AudioImportError(noAudio) }
                return Prepared(url: copy, duration: Double(opened.length) / opened.processingFormat.sampleRate)
            }
            let m4a = copy.deletingPathExtension().appendingPathExtension("m4a")
            let partial = m4a.appendingPathExtension("partial")
            try? FileManager.default.removeItem(at: partial)
            do {
                try await exportAudio(of: copy, to: partial)
                try Task.checkCancellation()
                let exported = try AVAudioFile(forReading: partial)
                guard exported.length > 0 else { throw AudioImportError(noAudio) }
                let duration = Double(exported.length) / exported.processingFormat.sampleRate
                if m4a == copy {
                    _ = try FileManager.default.replaceItemAt(m4a, withItemAt: partial)
                    return Prepared(url: m4a, duration: duration)
                }
                try FileManager.default.moveItem(at: partial, to: m4a)
                return Prepared(url: m4a, duration: duration, superseded: copy)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw error
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw error is AudioImportError ? error : AudioImportError(unreadable)
        }
    }

    private static func hasVideo(_ url: URL) async -> Bool {
        guard let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video) else { return false }
        return !tracks.isEmpty
    }

    private static func exportAudio(of source: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioImportError(noAudio)
        }
        try await session.export(to: output, as: .m4a)
    }
}
