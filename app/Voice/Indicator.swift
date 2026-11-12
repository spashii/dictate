import AppKit
import KeyboardShortcuts
import SwiftUI
import VoiceCore

/// A small pill at the top of the screen while Voice listens or works, and a second one for
/// as long as a call records. It never takes focus, so the paste lands in the app that was
/// in front.
@MainActor
final class Indicator {
    private let model: AppModel
    private var panel: NSPanel?
    private let hover = PillHoverState()
    private var watch: Task<Void, Never>?
    /// Room for the dictation pill at its largest, with the live text, and the call pill
    /// under it with its lines; the panel is clear around them.
    private static let size = NSSize(width: 440, height: 190)

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // Clicks pass through to the app below, except on a notice with a button.
        if case .notice(_, .some) = model.phase {
            panel.ignoresMouseEvents = false
        } else {
            panel.ignoresMouseEvents = true
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.maxY - Self.size.height - 8))
        }
        panel.orderFrontRegardless()
        watchPointer()
    }

    func hide() {
        watch?.cancel()
        watch = nil
        hover.clear()
        panel?.orderOut(nil)
    }

    /// The panel ignores the mouse, so no view hears the pointer arrive. While the pills are
    /// up, the pointer's position is read a few times a second and compared with theirs.
    private func watchPointer() {
        guard watch == nil else { return }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let panel = self.panel {
                    self.hover.update(pointer: PillHover.inPanel(NSEvent.mouseLocation, panel: panel.frame))
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: IndicatorView().environment(model).environment(hover))
        return panel
    }
}

/// Where each live pill is in the panel and whether the pointer is over it.
@MainActor @Observable
final class PillHoverState {
    enum Pill { case dictation, call }

    private var frames: [Pill: CGRect] = [:]
    private(set) var hovered: Set<Pill> = []

    func place(_ pill: Pill, at frame: CGRect?) {
        frames[pill] = frame
        if frame == nil { hovered.remove(pill) }
    }

    func update(pointer: CGPoint) {
        let over = Set(frames.filter { PillHover.isOver(pointer, frames: [$0.value]) }.keys)
        if over != hovered { hovered = over }
    }

    #if DEBUG
    func force(_ pills: Set<Pill>) {
        hovered = pills
    }
    #endif

    func clear() {
        hovered = []
    }
}

extension View {
    /// Reports the view's frame to the hover state, and fades it while the pointer is over.
    func fadesUnderPointer(_ pill: PillHoverState.Pill, in state: PillHoverState, enabled: Bool = true) -> some View {
        self
            .opacity(PillHover.opacity(hovered: enabled && state.hovered.contains(pill)))
            .animation(.easeInOut(duration: PillHover.fade), value: state.hovered.contains(pill))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(IndicatorView.space)) } action: {
                state.place(pill, at: $0)
            }
            .onDisappear { state.place(pill, at: nil) }
    }
}

struct IndicatorView: View {
    @Environment(AppModel.self) private var model
    @Environment(PillHoverState.self) private var hover
    static let space = "indicator"

    var body: some View {
        VStack(spacing: 6) {
            if model.phase != .idle {
                dictation
                    .padding(.vertical, 6)
                    .frame(minHeight: 32)
                    // A capsule at one line's height, a rounded box once the text adds a second.
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    // A notice with a button stays solid: the button has to be read to be clicked.
                    .fadesUnderPointer(.dictation, in: hover, enabled: !hasButton)
            }
            if let call = model.calls?.recording {
                CallPill(startedAt: call.startedAt,
                         stopHint: KeyboardShortcuts.getShortcut(for: .recordCall).map { "\($0.description) stops" }
                             ?? "Stop it from the menu",
                         lines: model.calls?.live.lines ?? [])
                    .fadesUnderPointer(.call, in: hover)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: Self.space)
    }

    private var hasButton: Bool {
        if case .notice(_, .some) = model.phase { true } else { false }
    }

    private var dictation: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .recording(_, let began):
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        LevelBar(level: model.level)
                        Text(began, style: .timer).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if !model.liveText.isEmpty {
                        Text(Self.tail(model.liveText))
                            .lineLimit(2)
                            .truncationMode(.head)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 400, alignment: .leading)
                    }
                }
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing")
            case .cleaningUp:
                ProgressView().controlSize(.small)
                Text("Fixing")
            case .notice(let text, let action):
                Text(text).lineLimit(2).minimumScaleFactor(0.8)
                if let action {
                    Button("Allow…") { model.noticeAction(action) }
                        .controlSize(.small)
                }
            case .edits(let changes):
                EditsLine(changes: changes)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
    }

    /// About two lines of the running text, from a word boundary.
    static func tail(_ text: String) -> String {
        guard text.count > 130 else { return text }
        let end = text.suffix(130)
        return "…" + (end.firstIndex(of: " ").map { end[end.index(after: $0)...] } ?? end)
    }
}

private struct LevelBar: View {
    let level: Float

    var body: some View {
        Capsule().fill(.quaternary)
            .frame(width: 48, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(.green).frame(width: 48 * CGFloat(level), height: 4)
            }
    }
}

