import Foundation

/// The Debug configuration is a separate app (bundle id ending in .dev) that runs beside the
/// installed Dictate. It has its own data folder, URL scheme and settings, and stays out of
/// everything the installed app owns: the login item, the shortcuts, the MCP port and updates.
enum BuildFlavor {
    static var isDev: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true }

    /// The first URL scheme this build registers, from its Info.plist.
    static var urlScheme: String? {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        return (types?.first?["CFBundleURLSchemes"] as? [String])?.first
    }

    /// Where the activation page is, from Info.plist so each configuration has its own.
    static var activationBase: URL {
        (Bundle.main.object(forInfoDictionaryKey: "DictateActivationURL") as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://dictate.firstversion.in")!
    }
}
