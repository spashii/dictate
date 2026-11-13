import AppKit
import Carbon.HIToolbox
import IOKit

/// macOS stops delivering global shortcuts while any app has secure keyboard input on: a
/// focused password field, or an app that turned it on and never off. This finds out that it
/// is on and which app holds it, from public calls only, without logging anything but the
/// name shown in the menu.
enum SecureInput {
    struct Holder: Equatable {
        /// The app's name, nil when the holder isn't a running app that has one.
        var name: String?

        /// What the menu says, for a person who can't tell why the shortcuts do nothing.
        var menuText: String { "\(name ?? "Another app") has keyboard input locked, so shortcuts are paused." }
    }

    /// Nil while nothing holds it. The flag is a cheap call; the registry is read only when
    /// it is set, so an idle Mac pays for one call per check.
    static func holder() -> Holder? {
        guard IsSecureEventInputEnabled() else { return nil }
        guard let pid = pid(in: consoleUsers()) else { return Holder(name: nil) }
        // A field in Dictate's own windows is nothing to warn about.
        guard pid != getpid() else { return nil }
        return Holder(name: NSRunningApplication(processIdentifier: pid)?.localizedName)
    }

    /// The process holding secure input, from the console session's registry entries.
    static func pid(in users: [[String: Any]]) -> pid_t? {
        users.lazy.compactMap { ($0["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value }.first { $0 > 0 }
    }

    private static func consoleUsers() -> [[String: Any]] {
        let resources = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources")
        guard resources != 0 else { return [] }
        defer { IOObjectRelease(resources) }
        let value = IORegistryEntryCreateCFProperty(resources, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? [[String: Any]] ?? []
    }
}
