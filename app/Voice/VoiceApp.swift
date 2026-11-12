import KeyboardShortcuts
import SwiftUI
import VoiceCore

@main
struct VoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(delegate.model)
                .environment(delegate.calls)
        } label: {
            Image(delegate.model.menuBarImage)
                .accessibilityLabel("Dictate")
        }

        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") { delegate.model.openSettings() }
                    .keyboardShortcut(",")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let calls: CallsModel
    private let windows = WindowActivation()

    /// The data folder moves before anything can open the database.
    override init() {
        DataMigration.run()
        BundleRename.renameIfNeeded()
        model = AppModel()
        calls = CallsModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.agents.recording = calls
        model.agents.keyTerms = PreferencesKeyTerms(preferences: model.preferences)
        model.calls = calls
        windows.start()
        model.launch()
        calls.launch(model: model)
    }

    /// Whisper's model has to be freed before the process exits: ggml's Metal device
    /// asserts at exit while a model still holds it, and the quit would end in a crash report.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await calls.shutDown()
            await model.shutDown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MenuContent: View {
    @Environment(AppModel.self) private var model
    @Environment(CallsModel.self) private var calls

    var body: some View {
        Text(model.statusText)
        Button(model.isRecording ? "Stop and paste" : "Dictate  \(KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "")") {
            model.toggle()
        }
        .disabled(model.isWorking)
        CallMenuItems()
        if !model.recent.isEmpty || !calls.recent.isEmpty {
            Divider()
            Section("Recent") {
                ForEach(model.recent) { dictation in
                    Button(Self.label(dictation)) {
                        if RowMenu.rightClicked, !dictation.finalText.isEmpty {
                            RowMenu.copyTranscript { model.copy(dictation) }
                        } else {
                            model.open(dictation)
                        }
                    }
                        .help(dictation.finalText.isEmpty && dictation.error != nil ? "Click to try again" : "Click to copy")
                        .disabled(dictation.finalText.isEmpty && dictation.error == nil)
                }
                RecentCalls()
                Button("Open History") { model.openHistory() }
            }
        }
        Divider()
        Button("Settings…") { model.openSettings() }
            .keyboardShortcut(",")
        ForEach(SupportItem.allCases, id: \.self) { item in
            Button(item.title) { open(item) }
                .disabled(item == .checkForUpdates && !model.updates.canCheck)
        }
        Button("Quit Dictate") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ item: SupportItem) {
        switch item {
        case .checkForUpdates: model.updates.check()
        case .reportIssue: NSWorkspace.shared.open(SupportItem.issueURL)
        case .viewOnGitHub: NSWorkspace.shared.open(SupportItem.repository)
        }
    }

    private static func label(_ dictation: Dictation) -> String {
        let text: String
        if dictation.finalText.isEmpty {
            text = "Couldn't transcribe, click to try again"
        } else {
            text = preview(dictation.finalText)
        }
        return dictation.origin == .recovered ? "Recovered a recording: " + text : text
    }

    private static func preview(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(60)) + "…" : text
    }
}

/// A Recent row's right-click menu. NSMenu has no context menu for its items, but a right
/// click still picks one, so the row's action asks which button picked it: a right click
/// opens Copy Transcript at the pointer, and a left click does what it always did. Should
/// macOS not pass the right click through, the row acts as if left-clicked.
@MainActor
enum RowMenu {
    static var rightClicked: Bool {
        let type = NSApp.currentEvent?.type
        return type == .rightMouseUp || type == .rightMouseDown
    }

    static func copyTranscript(_ copy: @escaping @MainActor () -> Void) {
        let action = MenuAction(copy)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Copy Transcript", action: #selector(MenuAction.fire), keyEquivalent: "")
        item.target = action
        menu.addItem(item)
        let location = NSEvent.mouseLocation
        // Once the menu bar's menu has finished closing, so the two never track at once.
        Task {
            withExtendedLifetime(action) {
                _ = menu.popUp(positioning: nil, at: location, in: nil)
            }
        }
    }
}

@MainActor
private final class MenuAction: NSObject {
    private let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        self.run = run
    }

    @objc func fire() {
        run()
    }
}
