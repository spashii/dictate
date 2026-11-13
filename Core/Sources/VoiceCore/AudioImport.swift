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
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AudioImportError("No file at \(path).")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard !isDirectory.boolValue, attributes?[.type] as? FileAttributeType == .typeRegular else {
            throw AudioImportError("\(path) is not a file.")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw AudioImportError("Dictate can't read \(path).")
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

    /// Keeps a copy of the file at `base` plus an extension, and returns it with the length of
    /// its audio. A file AVAudioFile reads and that has no video is copied as it is, so the
    /// original bytes are kept; anything else is reduced to its audio track as AAC in an .m4a.
    /// Nothing is left at the destination when this throws.
    public static func storeCopy(of source: URL, as base: URL) async throws -> (url: URL, duration: Double) {
        let ext = source.pathExtension.lowercased()
        let asIs = base.appendingPathExtension(ext)
        let m4a = base.appendingPathExtension("m4a")
        do {
            if let opened = try? AVAudioFile(forReading: source), !(await hasVideo(source)) {
                guard opened.length > 0 else { throw AudioImportError(noAudio) }
                try FileManager.default.copyItem(at: source, to: asIs)
                return (asIs, Double(opened.length) / opened.processingFormat.sampleRate)
            }
            try await exportAudio(of: source, to: m4a)
            let exported = try AVAudioFile(forReading: m4a)
            guard exported.length > 0 else { throw AudioImportError(noAudio) }
            return (m4a, Double(exported.length) / exported.processingFormat.sampleRate)
        } catch {
            try? FileManager.default.removeItem(at: asIs)
            try? FileManager.default.removeItem(at: m4a)
            throw error is AudioImportError ? error : AudioImportError("Dictate couldn't read this file's audio.")
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
