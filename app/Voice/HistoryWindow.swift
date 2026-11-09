import AppKit
import AVFoundation
import SwiftUI
import VoiceCore

/// Every dictation and call, with whisper's text and what changed it. Opened only from the
/// menu and Settings: it is never restored or shown at launch.
@MainActor
final class HistoryWindow {
    private var window: NSWindow?
    private let model = HistoryModel()

    func show() {
        let window = window ?? makeWindow()
        if self.window == nil { window.center() }
        self.window = window
        model.reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
                              defer: true)
        window.title = "History"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 560, height: 320)
        window.contentViewController = NSHostingController(rootView: HistoryView(model: model))
        window.setContentSize(NSSize(width: 820, height: 560))
        // Closing the window stops a segment that is still playing.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { [model] _ in
            MainActor.assumeIsolated { model.player.stop() }
        }
        return window
    }
}

/// The list and the selected entry, read from the database off the main thread.
@MainActor @Observable
final class HistoryModel {
    var entries: [HistoryEntry] = []
    var selection: HistoryEntry.ID?
    var detail: HistoryDetail?
    let player = SegmentPlayer()
    @ObservationIgnored private var store: CallStore?
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// The list as it is now; the selection stays when its entry is still there.
    func reload() {
        Task {
            let store = await openStore()
            entries = (try? await Task.detached { try store?.historyEntries() ?? [] }.value) ?? []
            if selection == nil || !entries.contains(where: { $0.id == selection }) { selection = entries.first?.id }
            select(selection)
        }
    }

    func select(_ id: HistoryEntry.ID?) {
        loading?.cancel()
        guard let entry = entries.first(where: { $0.id == id }) else {
            detail = nil
            return
        }
        loading = Task {
            let store = await openStore()
            let read = try? await Task.detached { try store?.historyDetail(entry) }.value
            guard !Task.isCancelled else { return }
            detail = read ?? nil
        }
    }

    /// Puts an entry's text on the clipboard, read as it is now, and says whether there was any.
    func copy(_ entry: HistoryEntry) async -> Bool {
        guard let store = await openStore() else { return false }
        let item: TranscriptCopy.Item? = switch entry.kind {
        case .call: .call(entry.ref)
        case .dictation: (try? store.dictation(entry.ref)).map { TranscriptCopy.Item.dictation($0) }
        }
        return item.map { TranscriptCopy.copy($0, in: store) } ?? false
    }

    private func openStore() async -> CallStore? {
        if let store { return store }
        store = try? await Task.detached { try CallStore(url: Paths.database) }.value
        return store
    }
}

/// Plays one segment's stretch of a recording through the default output, and only when
/// its button is clicked.
@MainActor @Observable
final class SegmentPlayer {
    private(set) var playing: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var end: Task<Void, Never>?

    /// Starts the line, or stops it when it is the one playing.
    func toggle(_ key: String, path: String, from t0: Double, to t1: Double) {
        if playing == key {
            stop()
            return
        }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return }
        // A little either side, so the first and last words aren't clipped.
        let start = max(0, t0 - 0.2)
        let length = min(player.duration, t1 + 0.2) - start
        guard length > 0 else { return }
        player.currentTime = start
        player.play()
        self.player = player
        playing = key
        end = Task {
            try? await Task.sleep(for: .seconds(length))
            guard !Task.isCancelled else { return }
            stop()
        }
    }

    func stop() {
        end?.cancel()
        player?.stop()
        player = nil
        playing = nil
    }
}

struct HistoryView: View {
    @Bindable var model: HistoryModel

    var body: some View {
        NavigationSplitView {
            List(model.entries, selection: $model.selection) { entry in
                HistoryRow(entry: entry) { await model.copy(entry) }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let detail = model.detail {
                HistoryDetailView(detail: detail, player: model.player)
            }
        }
        .onChange(of: model.selection) { _, id in
            model.player.stop()
            model.select(id)
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    /// Copies the entry's text; true once it is on the clipboard.
    let copy: @MainActor () async -> Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.at, format: .dateTime.month(.abbreviated).day().hour().minute())
                    if entry.kind == .call { SmallLabel("call") }
                    Spacer()
                    if entry.changes > 0 { Text("\(entry.changes)").monospacedDigit() }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(entry.title).lineLimit(2)
            }
            // A call that heard nothing has nothing to copy, so it gets no button.
            if entry.hasText { CopyButton(copy: copy) }
        }
        .padding(.vertical, 2)
    }
}

/// "Copy", and "Copied" for a moment once the text is on the clipboard. Nothing copied shows
/// nothing.
struct CopyButton: View {
    let copy: @MainActor () async -> Bool
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button {
            Task {
                guard await copy() else { return }
                copied = true
                reset?.cancel()
                reset = Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    copied = false
                }
            }
        } label: {
            // Both words take the same room, so the row doesn't shift when it changes.
            ZStack {
                Text("Copied").hidden()
                Text(copied ? "Copied" : "Copy")
            }
        }
        .controlSize(.small)
    }
}

struct HistoryDetailView: View {
    let detail: HistoryDetail
    let player: SegmentPlayer

    var body: some View {
        ScrollView {
            HistoryDetailContent(detail: detail, player: player)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The entry's lines and changes, apart from the scroll view so it can be rendered alone.
struct HistoryDetailContent: View {
    let detail: HistoryDetail
    let player: SegmentPlayer

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(detail.entry.at, format: .dateTime.weekday().month().day().hour().minute())
                Text(HistoryDetailView.clock(detail.entry.duration)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(detail.lines) { line in
                HistoryLineView(line: line, audioPath: detail.audioPath, player: player)
            }
            ForEach(detail.textChanges) { change in
                ChangeRow(change: change).padding(.leading, 62)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HistoryLineView: View {
    let line: HistoryLine
    let audioPath: String?
    let player: SegmentPlayer

    var body: some View {
        let key = "\(line.id)"
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(HistoryDetailView.clock(line.t0))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
            Group {
                if line.playable, let audioPath {
                    Button {
                        player.toggle(key, path: audioPath, from: line.t0, to: line.t1)
                    } label: {
                        Image(systemName: player.playing == key ? "stop.fill" : "play.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(player.playing == key ? "Stop" : "Play this part")
                } else {
                    Color.clear
                }
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let speaker = line.speaker {
                        Text(speaker).foregroundStyle(speaker == "Me" ? Color.blue : Color.purple)
                    }
                    Text(line.whisper).textSelection(.enabled)
                    if line.flagged { SmallLabel("unsure") }
                }
                ForEach(line.changes) { change in
                    ChangeRow(change: change)
                }
            }
        }
    }
}

/// A change in a line: its source, the changed words, and the key term, client or reason.
struct ChangeRow: View {
    let change: HistoryChange

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SmallLabel(change.source.rawValue)
            changed
            // A key term the replacement already spells out says nothing more.
            if let note = change.note, !(change.applied && change.source == .fix && change.after.contains(note)) {
                Text(note).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .opacity(change.applied ? 1 : 0.5)
    }

    /// The words that differ; a change of punctuation alone shows the whole text.
    private var changed: Text {
        let changes = change.diff.changes.isEmpty
            ? [WordDiff.Change(before: [change.before], after: [change.after])] : change.diff.changes
        return changes.enumerated().reduce(Text("")) { text, item in
            text + Text(item.offset == 0 ? "" : "   ") + DiffText.text(item.element)
        }
    }
}

struct SmallLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}
