import AppKit
import SwiftUI
import VoiceCore

@MainActor @Observable
final class MainNavigation {
    var selection: MainPane? = .history
}

/// The one window: a sidebar with the Library and the Settings, and the pane chosen in it. It
/// replaces the separate Settings and History windows. Opened from the menu, by Cmd+, and at
/// launch while setup is unfinished; never restored.
@MainActor
final class MainWindow {
    private var window: NSWindow?
    private let model: AppModel
    private let navigation = MainNavigation()
    private let history = HistoryModel()

    init(model: AppModel) {
        self.model = model
    }

    func show(_ pane: MainPane, calls: CallsModel) {
        navigation.selection = pane
        let window = window ?? makeWindow(calls: calls)
        if self.window == nil { window.center() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        WindowActivation.bringForward()
    }

    private func makeWindow(calls: CallsModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = AppName.name
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 760, height: 460)
        let root = MainView(navigation: navigation, history: history)
            .environment(model)
            .environment(calls)
        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = [.title, .toolbars]
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1060, height: 680))
        // Closing the window stops a recording that is still playing.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { [history] _ in
            MainActor.assumeIsolated { history.player.stop() }
        }
        return window
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var activeState
    let navigation: MainNavigation
    let history: HistoryModel

    var body: some View {
        @Bindable var navigation = navigation
        let policy = model.lock
        NavigationSplitView {
            MainSidebar(navigation: navigation)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            let pane = policy.landing(for: navigation.selection ?? .history)
            Group {
                switch pane {
                case .welcome: WelcomePane()
                case .history: HistoryPane(history: history)
                case .setup: SetupPane()
                case .shortcuts: ShortcutsPane()
                case .microphones: MicrophonesPane()
                case .model: ModelPane()
                case .agents: AgentsPane()
                case .about: AboutPane()
                }
            }
            .navigationTitle(pane.title)
        }
        .onAppear {
            model.refreshDevices()
            model.refreshPermissions()
        }
        // macOS says nothing when Accessibility is granted, so the setup steps look every
        // second while one is open.
        .task(id: model.setupComplete) {
            while !Task.isCancelled && !model.setupComplete {
                try? await Task.sleep(for: .seconds(1))
                model.refreshPermissions()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }
}

/// The Library and Settings list. A view of its own so the app-shots run can draw it where
/// a bitmap draw of the window leaves the sidebar blank.
struct MainSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var activeState
    let navigation: MainNavigation

    var body: some View {
        @Bindable var navigation = navigation
        let policy = model.lock
        List(selection: $navigation.selection) {
            if !model.activation.isActivated {
                Section { row(.welcome) }
            }
            if policy.unlocked {
                Section("Library") {
                    ForEach(MainPane.library) { row($0) }
                }
            }
            Section("Settings") {
                ForEach(MainPane.settings.filter(policy.reaches)) { row($0) }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ pane: MainPane) -> some View {
        HStack {
            Label(pane.title, systemImage: pane.symbol)
            if pane == .setup, !model.setupComplete {
                Spacer()
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Setup is not finished")
            }
            if pane.showsUpdateDot(updateAvailable: model.updates.available != nil) {
                Spacer()
                // White on the selected row while the window is active, as its highlight is then
                // the accent colour itself.
                Circle()
                    .fill(navigation.selection == pane && activeState != .inactive ? Color.white : Color.accentColor)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Update available")
            }
        }
        .tag(pane)
    }
}
