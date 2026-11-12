import Foundation

/// The agent server's settings as the app stores them in its defaults, so the app and
/// `dictate-cli mcp` read the same ones.
public enum AgentSettings {
    public static let domain = "io.github.spashii.voice"
    public static let disabledToolsKey = "agentDisabledTools"
    public static let hostKey = "agentHost"
    public static let portKey = "agentPort"

    /// UserDefaults won't open a suite named after the running bundle, which is the domain
    /// itself in that case.
    public static var appDefaults: UserDefaults {
        Bundle.main.bundleIdentifier == domain ? .standard : UserDefaults(suiteName: domain) ?? .standard
    }

    /// The tools an agent can't use. A stored list, even an empty one, is a person's (or an
    /// earlier version's) choice and is kept. With none stored, the writing and recording tools
    /// start off only on an install that has never run: anyone who already used Dictate, shown
    /// by a data folder or earlier preferences, keeps every tool on, as before this version.
    /// The result is stored at once, so a second launch can't mistake the folder this launch
    /// made for an earlier install.
    public static func disabledTools(in defaults: UserDefaults, existingInstall: Bool) -> Set<String> {
        if let stored = defaults.stringArray(forKey: disabledToolsKey) { return Set(stored) }
        let initial = existingInstall ? [] : MCPServer.offByDefault
        defaults.set(initial.sorted(), forKey: disabledToolsKey)
        return Set(initial)
    }

    /// True when this Mac has run Dictate (or Voice) before: either data folder exists, or the
    /// defaults hold any key besides the ones this launch may have written.
    public static func isExistingInstall(support root: URL = DataMigration.applicationSupport,
                                         defaults: UserDefaults = appDefaults, domain: String = domain) -> Bool {
        let fm = FileManager.default
        if [DataMigration.oldName, DataMigration.newName].contains(where: { fm.fileExists(atPath: root.appending(path: $0).path) }) {
            return true
        }
        let own = defaults.persistentDomain(forName: domain) ?? [:]
        return !own.isEmpty
    }

    /// The host and port the app's server uses; the defaults when none were set or they are invalid.
    public static func endpoint(in defaults: UserDefaults) -> (host: String, port: UInt16) {
        let host = defaults.string(forKey: hostKey).flatMap(MCPEndpoint.address(host:)) ?? MCPEndpoint.defaultHost
        let port = (defaults.object(forKey: portKey) as? Int).flatMap { UInt16(exactly: $0) } ?? MCPServer.defaultPort
        return (host, port)
    }

    /// The tool switches dictate-cli applies: the app's, or the new-install defaults while
    /// the app has never stored any. It never writes them.
    public static func disabledToolsForReading(in defaults: UserDefaults) -> Set<String> {
        defaults.stringArray(forKey: disabledToolsKey).map(Set.init) ?? MCPServer.offByDefault
    }
}
