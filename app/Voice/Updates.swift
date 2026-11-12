import Foundation
import Observation
import Sparkle

/// Updates come through Sparkle. It reads the appcast from apps.firstversion.in, the update host, which
/// counts the checks, verifies each update against the signing key in Info.plist, and asks
/// before installing. On the second launch it asks whether to check automatically. Apart
/// from the speech model downloads, nothing else in Dictate goes online.
///
/// An update Sparkle downloads on its own waits for Dictate to quit, and a menu bar app that
/// opens at login is almost never quit, so it could stay staged for weeks. Dictate takes the
/// install over instead and runs it the first time it is quiet (AppModel).
@MainActor
@Observable
final class Updates {
    /// Sparkle holds its delegate weakly, so this keeps it alive.
    @ObservationIgnored private let delegate: UpdaterDelegate
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// Sparkle's install-now block for a staged update, kept until Dictate is quiet.
    @ObservationIgnored private var stagedInstall: (() -> Void)?
    /// Told when Sparkle stages an update.
    @ObservationIgnored var onStaged: (() -> Void)?

    /// False while a check is already under way.
    private(set) var canCheck = false
    var automatic: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automatic }
    }

    init() {
        let delegate = UpdaterDelegate()
        self.delegate = delegate
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate,
                                                  userDriverDelegate: nil)
        automatic = controller.updater.automaticallyChecksForUpdates
        canCheck = controller.updater.canCheckForUpdates
        // Sparkle changes both on the main thread.
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated { self?.canCheck = value }
            },
            // Sparkle's own first-run question changes this behind the toggle's back.
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                MainActor.assumeIsolated {
                    if self?.automatic != value { self?.automatic = value }
                }
            },
        ]
        delegate.staged = { [weak self] install in
            MainActor.assumeIsolated {
                self?.stagedInstall = install
                self?.onStaged?()
            }
        }
    }

    func check() {
        controller.checkForUpdates(nil)
    }

    var hasStagedUpdate: Bool { stagedInstall != nil }

    /// Quits Dictate, installs the staged update and relaunches it.
    func installStagedUpdate() {
        let install = stagedInstall
        stagedInstall = nil
        install?()
    }
}

/// Marks update checks from the owner's own Macs (the OwnerMac default), so the counts at
/// update server can leave them out. Sparkle adds the pair to the appcast's query; every
/// other Mac sends no parameters, and the system profile stays off.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    /// Takes Sparkle's install-now block for a staged update; set by Updates.
    var staged: ((@escaping () -> Void) -> Void)?

    /// True tells Sparkle Dictate will install the update itself, by calling the block.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard let staged else { return false }
        staged(immediateInstallHandler)
        return true
    }

    func feedParameters(for updater: SPUUpdater, sendingSystemProfile sendingProfile: Bool) -> [[String: String]] {
        UserDefaults.standard.bool(forKey: "OwnerMac") ? [["key": "self", "value": "1"]] : []
    }
}
