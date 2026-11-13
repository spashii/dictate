import Foundation
import VoiceCore

/// A line per event in the data folder of a development build, so a test can read what
/// reached the app without watching its screen. Does nothing in the installed app.
enum DevLog {
    static func write(_ text: String) {
        guard BuildFlavor.isDev else { return }
        let url = Paths.support.appending(path: "dev-log.txt")
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) pid=\(ProcessInfo.processInfo.processIdentifier) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
