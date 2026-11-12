import Foundation

/// Versions before 0.12.0 were installed as Voice.app. Sparkle installs an update over the
/// path it runs from and has no setting to rename it, so the new Dictate renames its own
/// bundle once, never over a Dictate.app that already exists. The bundle id is unchanged, so
/// settings, permissions and updates carry over.
enum BundleRename {
    static let oldName = "Voice.app"
    static let newName = "Dictate.app"

    /// Where the bundle at `url` should move to, or nil when it should stay.
    static func destination(for url: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        guard url.lastPathComponent == oldName else { return nil }
        let target = url.deletingLastPathComponent().appending(path: newName)
        return exists(target) ? nil : target
    }

    /// Moves the running bundle. A folder that can't be written (an app in a protected
    /// place) leaves it where it is, which still works.
    static func renameIfNeeded(bundle: URL = Bundle.main.bundleURL) {
        guard let target = destination(for: bundle) else { return }
        try? FileManager.default.moveItem(at: bundle, to: target)
    }
}
