import VoiceCore

/// What a Mac that is not activated may reach. Everything that opens
/// a locked feature asks here, so the window, the hotkeys, the agent server and the menu
/// follow one rule. Updates, About and Welcome stay, so a broken activation can be fixed.
struct LockPolicy: Equatable {
    let unlocked: Bool

    @MainActor
    init(_ activation: Activation) {
        unlocked = activation.isActivated
    }

    init(unlocked: Bool) {
        self.unlocked = unlocked
    }

    var registersHotkeys: Bool { unlocked }
    var startsAgentServer: Bool { unlocked }
    var showsRecordingMenu: Bool { unlocked }

    func reaches(_ pane: MainPane) -> Bool {
        unlocked || pane == .welcome || pane == .about
    }

    /// The pane to show for a request: the one asked for, or Welcome while it is locked.
    func landing(for pane: MainPane) -> MainPane {
        reaches(pane) ? pane : .welcome
    }
}

/// Holds the global shortcuts only once Dictate is activated, so a locked Dictate does not
/// take a key from another app. The two actions are injected for tests.
@MainActor
final class Hotkeys {
    private let enable: () -> Void
    private let disable: () -> Void
    private var registered: Bool?

    init(enable: @escaping () -> Void, disable: @escaping () -> Void) {
        self.enable = enable
        self.disable = disable
    }

    var isRegistered: Bool { registered == true }

    /// `force` registers again even when nothing changed, for a handler added after the last call.
    func apply(_ policy: LockPolicy, force: Bool = false) {
        guard force || registered != policy.registersHotkeys else { return }
        registered = policy.registersHotkeys
        if policy.registersHotkeys { enable() } else { disable() }
    }
}
