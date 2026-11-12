import AppKit
import SwiftUI

/// The panes of the main window, in the sidebar's order.
enum MainPane: String, CaseIterable, Identifiable {
    case general, history, model, calls

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .history: "History"
        case .model: "Model"
        case .calls: "Calls"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .history: "clock.arrow.circlepath"
        case .model: "waveform"
        case .calls: "phone"
        }
    }
}

/// The one window: Settings and History in a sidebar, opened from the menu, at launch while
/// setup is unfinished, and from Command-comma.
@MainActor
final class MainWindow {
    static let minimumSize = NSSize(width: 720, height: 480)
    static let defaultSize = NSSize(width: 880, height: 600)

    private var window: NSWindow?
    let history = HistoryModel()

    var nsWindow: NSWindow? { window }

    func show(_ pane: MainPane, model: AppModel, calls: CallsModel) {
        model.pane = pane
        let window = window ?? makeWindow(model: model, calls: calls)
        if self.window == nil { window.center() }
        self.window = window
        history.reload()
        WindowActivation.bringForward()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow(model: AppModel, calls: CallsModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
                              defer: true)
        window.title = AppName.name
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = Self.minimumSize
        window.contentViewController = NSHostingController(
            rootView: MainView(history: history).environment(model).environment(calls))
        window.setContentSize(Self.defaultSize)
        // Closing the window stops a segment that is still playing.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { [history] _ in
            MainActor.assumeIsolated { history.player.stop() }
        }
        return window
    }
}

/// The sidebar and the selected pane, laid out like System Settings.
struct MainView: View {
    @Environment(AppModel.self) private var model
    let history: HistoryModel

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.pane) {
                ForEach(MainPane.allCases) { pane in
                    HStack {
                        Label(pane.title, systemImage: pane.symbol)
                        Spacer()
                        if pane == .general, !model.setupComplete {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                                .help("Setup isn't finished")
                        }
                    }
                    .tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            Group {
                switch model.pane {
                case .general: GeneralPane()
                case .history: HistoryView(model: history)
                case .model: ModelPane()
                case .calls: CallsPane()
                }
            }
            .navigationTitle(model.pane.title)
        }
        .onChange(of: model.pane) { old, _ in
            if old == .history { history.player.stop() }
        }
    }
}
