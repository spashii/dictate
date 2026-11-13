import AppKit

/// An older Voice.app can still be running (a login item started before the update), with
/// the same bundle id and the database open. Migrating the data folder under it would split
/// the file from its -wal and -shm, so it is asked to quit first, and when it won't, Dictate
/// does not migrate and quits itself.
enum OtherInstance {
    /// Asks the others to quit and waits up to `timeout` seconds. True when none is left.
    /// The steps are injected so the decision can be tested without another process.
    static func clear(running: () -> Int, askToQuit: () -> Void, pause: (Double) -> Void,
                      timeout: Double = 5, step: Double = 0.25) -> Bool {
        guard running() > 0 else { return true }
        askToQuit()
        var waited = 0.0
        while waited < timeout {
            pause(step)
            waited += step
            if running() == 0 { return true }
        }
        return running() == 0
    }

    private static func others() -> [NSRunningApplication] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// True when this is the only instance, after asking any other to quit. Otherwise it
    /// tells the person and returns false, and the caller quits without touching any data.
    @MainActor
    static func ensureSole() -> Bool {
        let cleared = clear(running: { others().count },
                            askToQuit: { others().forEach { _ = $0.terminate() } },
                            pause: { Thread.sleep(forTimeInterval: $0) })
        if cleared { return true }
        let alert = NSAlert()
        alert.messageText = "Another copy of Dictate is still running"
        alert.informativeText = "An older version (Voice) didn't quit when asked. Quit it from the menu bar, then open Dictate again."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        return false
    }
}
