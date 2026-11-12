import Foundation

/// Versions before 0.12.0 were installed as Voice.app. Sparkle installs an update over the
/// path it runs from and has no setting to rename it, so the new Dictate renames its own
/// bundle once, never over a Dictate.app that already exists. The bundle id is unchanged, so
/// settings, permissions and updates carry over.
///
/// Once the bundle has moved, the running process still has the old path in its Bundle,
/// resources and Sparkle's paths. It therefore starts again from the new path and exits before
/// anything else initialises, so nothing runs from a path that no longer exists.
enum BundleRename {
    static let oldName = "Voice.app"
    static let newName = "Dictate.app"

    /// Where the bundle at `url` should move to, or nil when it should stay.
    static func destination(for url: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        guard url.lastPathComponent == oldName else { return nil }
        let target = url.deletingLastPathComponent().appending(path: newName)
        return exists(target) ? nil : target
    }

    /// Moves the running bundle and returns where it went, to start again from there. A
    /// folder that can't be written (an app in a protected place) leaves the bundle where it
    /// is and returns nil, which still works.
    static func renameIfNeeded(bundle: URL = Bundle.main.bundleURL,
                               exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                               move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) -> URL? {
        guard let target = destination(for: bundle, exists: exists) else { return nil }
        do {
            try move(bundle, target)
            return target
        } catch {
            return nil
        }
    }

    /// `open -n` starts a second instance even though one with this bundle id is running.
    static func relaunchCommand(for bundle: URL) -> (executable: String, arguments: [String]) {
        ("/usr/bin/open", ["-n", bundle.path])
    }

    /// Starts the bundle at its new path and ends this process. Does not return.
    static func relaunchAndExit(_ bundle: URL) -> Never {
        let command = relaunchCommand(for: bundle)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        try? process.run()
        process.waitUntilExit()
        exit(0)
    }
}
