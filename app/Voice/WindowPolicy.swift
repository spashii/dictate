import AppKit

/// Voice lives in the menu bar and has no Dock icon, until it opens a window: then it is an
/// ordinary app, so the window comes forward and can be found in the Dock and the app
/// switcher. When the last window closes it goes back to the menu bar.
enum WindowPolicy {
    /// What decides whether a window counts, read off the NSWindow so the rule can be tested.
    struct Info {
        var isPanel: Bool
        var isTitled: Bool
        var isVisible: Bool
        var isMiniaturized: Bool
    }

    /// A window the person works in. Panels are excluded: the live pills and the call prompt
    /// float over other apps and must not take focus, and open and save panels belong to a
    /// window that already counts. A minimized window still counts, since the Dock holds it.
    static func counts(_ window: Info) -> Bool {
        !window.isPanel && window.isTitled && (window.isVisible || window.isMiniaturized)
    }

    static func policy(openWindows: Int) -> NSApplication.ActivationPolicy {
        openWindows > 0 ? .regular : .accessory
    }
}

/// Applies WindowPolicy as windows open and close.
@MainActor
final class WindowActivation {
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                // Delivered on the main queue, so the window is only ever touched there.
                nonisolated(unsafe) let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    if let window, Self.counts(window) { Self.bringForward() }
                }
            })
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                nonisolated(unsafe) let closing = note.object as? NSWindow
                MainActor.assumeIsolated { self?.settle(closing: closing) }
            })
        }
    }

    /// Opens the Dock icon and brings the app forward. The policy has to be regular before
    /// the activation, or an accessory app is left behind the app that was in front.
    static func bringForward() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Back to the menu bar once no window is left. A window that is closing still reads as
    /// visible while its notification runs, so it is left out of the count.
    func settle(closing: NSWindow?) {
        let open = NSApp.windows.filter { $0 !== closing && Self.counts($0) }.count
        let policy = WindowPolicy.policy(openWindows: open)
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    private static func counts(_ window: NSWindow) -> Bool {
        WindowPolicy.counts(.init(isPanel: window is NSPanel, isTitled: window.styleMask.contains(.titled),
                                  isVisible: window.isVisible, isMiniaturized: window.isMiniaturized))
    }
}
