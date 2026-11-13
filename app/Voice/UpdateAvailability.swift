import Foundation

/// An update Sparkle found: the version and its notes as bullets.
struct AvailableUpdate: Equatable {
    var version: String
    var notes: [String]
}

/// What Sparkle last said about updates. Kept apart from Sparkle so it can be tested.
struct UpdateAvailability: Equatable {
    private(set) var available: AvailableUpdate?

    /// Sparkle offers whatever the feed has, so a version that is not newer than this one is
    /// not shown as an update.
    mutating func found(version: String, description: String?, currentVersion: String) {
        guard Changelog.isOlder(currentVersion, than: version) else { return }
        available = AvailableUpdate(version: version, notes: Changelog.bullets(fromDescription: description ?? ""))
    }

    mutating func notFound() {
        available = nil
    }
}

extension MainPane {
    /// The dot on a sidebar row: only About carries it, and only while an update waits.
    func showsUpdateDot(updateAvailable: Bool) -> Bool {
        updateAvailable && self == .about
    }
}
