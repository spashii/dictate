import AppKit
import Foundation

/// How the call audio picker groups apps, in the order it lists them.
public enum CallAppGroup: Int, Sendable, CaseIterable {
    case communication
    case browsers
    case other

    public var title: String {
        switch self {
        case .communication: "Calls and chat"
        case .browsers: "Browsers"
        case .other: "Other apps"
        }
    }

    /// An app using a microphone counts as a call app, so one Dictate doesn't know still
    /// lands in the first group while it is in a call.
    public static func of(_ bundleID: String, listening: Bool, browsers: Set<String> = CallApps.browsers) -> CallAppGroup {
        if CallApps.member(bundleID, of: CallApps.communication) != nil { return .communication }
        if browsers.contains(bundleID) { return .browsers }
        return listening ? .communication : .other
    }
}

/// An app that can be chosen as the call's other side.
public struct RunningCallApp: Sendable, Hashable, Identifiable {
    public var bundleID: String
    public var name: String
    public var group: CallAppGroup
    public var pid: pid_t
    /// Making sound now.
    public var playing: Bool
    /// Using a microphone now, as a call app does during a call.
    public var listening: Bool

    public var id: String { bundleID }
    public var target: CallTapTarget { CallTapTarget(bundleID: bundleID, name: name) }

    /// Groups in order, apps in a call first and then by name. Sound alone doesn't reorder
    /// them, so rows stay put while a person reaches for one.
    public static func grouped(_ apps: [RunningCallApp]) -> [(group: CallAppGroup, apps: [RunningCallApp])] {
        CallAppGroup.allCases.compactMap { group in
            let members = apps.filter { $0.group == group }.sorted {
                ($0.listening ? 0 : 1, $0.name.localizedLowercase) < ($1.listening ? 0 : 1, $1.name.localizedLowercase)
            }
            return members.isEmpty ? nil : (group, members)
        }
    }
}

extension CallApps {
    /// Running apps with a window or a Dock icon, Dictate and apps that only listen for a
    /// living left out, with what each is doing with sound. Asks coreaudiod, so not for the
    /// main thread.
    public static func running(ownBundleID: String? = Bundle.main.bundleIdentifier) -> [RunningCallApp] {
        var browsers = Self.browsers
        if let page = URL(string: "https://example.com"),
           let handler = NSWorkspace.shared.urlForApplication(toOpen: page),
           let id = Bundle(url: handler)?.bundleIdentifier {
            browsers.insert(id)
        }
        var playing: Set<pid_t> = []
        var listening: Set<pid_t> = []
        for process in processes() where process.pid > 0 {
            let owner = responsible(process.pid)
            if process.output { playing.insert(owner) }
            if process.input { listening.insert(owner) }
        }
        var apps: [RunningCallApp] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != ownBundleID,
                  member(id, of: excluded) == nil else { continue }
            let hears = listening.contains(app.processIdentifier)
            apps.append(RunningCallApp(bundleID: id, name: app.localizedName ?? id,
                                       group: CallAppGroup.of(id, listening: hears, browsers: browsers),
                                       pid: app.processIdentifier, playing: playing.contains(app.processIdentifier),
                                       listening: hears))
        }
        return apps
    }
}
