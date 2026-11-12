import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
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
    /// Another file for tests and renders; the app's own history otherwise.
    @ObservationIgnored private let databaseURL: URL

    init(databaseURL: URL = Paths.database) {
        self.databaseURL = databaseURL
    }

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
        let url = databaseURL
        store = try? await Task.detached { try CallStore(url: url) }.value
        return store
    }
}

/// Save As for a recording: the file in the format it is stored in, wherever the person says.
@MainActor
enum AudioSaver {
    static func save(_ entry: HistoryEntry) {
        guard let source = entry.audioFile, let name = entry.suggestedAudioName else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = UTType(filenameExtension: source.pathExtension).map { [$0] } ?? []
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try entry.saveAudio(to: destination)
        } catch {
            NSAlert(error: error).runModal()
        }
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
    @AppStorage(HistoryTimeMode.defaultsKey) private var times = HistoryTimeMode.standard

    var body: some View {
        NavigationSplitView {
            List(model.entries, selection: $model.selection) { entry in
                HistoryRow(entry: entry, copy: { await model.copy(entry) }, save: { AudioSaver.save(entry) })
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let detail = model.detail {
                HistoryDetailView(detail: detail, player: model.player, times: $times)
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
    /// Opens Save As for the entry's recording.
    var save: @MainActor () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(HistoryClock.date(entry, weekday: false))
                    if entry.kind == .call { SmallLabel("call") }
                    Spacer()
                    if entry.changes > 0 { Text("\(entry.changes)").monospacedDigit() }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(entry.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            // A call that heard nothing has nothing to copy, so it gets no button.
            if entry.hasText { CopyButton(copy: copy) }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Save Audio As…", action: save).disabled(entry.audioFile == nil)
        }
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
    @Binding var times: HistoryTimeMode

    var body: some View {
        ScrollView {
            HistoryDetailContent(detail: detail, player: player, times: $times)
        }
    }

    static func clock(_ seconds: Double) -> String { HistoryTime.elapsed(seconds) }
}

/// Dates as they read on the clock the recording was made on, with that zone's name when it
/// isn't the one this Mac is in now.
enum HistoryClock {
    static func date(_ entry: HistoryEntry, weekday: Bool) -> String {
        var style = Date.FormatStyle().month(.abbreviated).day().hour().minute()
        if weekday { style = style.weekday() }
        style.timeZone = entry.zone
        let text = entry.at.formatted(style)
        return entry.originalZoneLabel.map { "\(text) \($0)" } ?? text
    }
}

/// The entry's lines and changes, apart from the scroll view so it can be rendered alone.
struct HistoryDetailContent: View {
    let detail: HistoryDetail
    let player: SegmentPlayer
    @Binding var times: HistoryTimeMode

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(HistoryClock.date(detail.entry, weekday: true))
                Text(HistoryDetailView.clock(detail.entry.duration)).monospacedDigit()
                Spacer(minLength: 8)
                Picker("Times", selection: $times) {
                    ForEach(HistoryTimeMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Show lines at the time they were spoken, or at how far into the recording")
                Button("Save As…") { AudioSaver.save(detail.entry) }
                    .disabled(detail.entry.audioFile == nil)
            }
            .controlSize(.small)
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(detail.lines) { line in
                HistoryLineView(line: line, entry: detail.entry, audioPath: detail.audioPath, player: player,
                                times: times)
            }
            ForEach(detail.textChanges) { change in
                ChangeRow(change: change).padding(.leading, HistoryLineView.gutter)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HistoryLineView: View {
    let line: HistoryLine
    let entry: HistoryEntry
    let audioPath: String?
    let player: SegmentPlayer
    let times: HistoryTimeMode

    /// The time, the play button and their gaps: where a line's text starts.
    static let gutter: CGFloat = 62 + 14 + 16

    var body: some View {
        let key = "\(line.id)"
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(HistoryTime.line(start: entry.at, offset: line.t0, zone: entry.timeZone, mode: times))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .trailing)
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
                    // Takes no height of its own: a bare Color.clear is greedy and
                    // makes a line's height depend on its neighbours.
                    Color.clear.frame(height: 0)
                }
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let speaker = line.speaker {
                        Text(speaker).foregroundStyle(speaker == "Me" ? Color.blue : Color.purple)
                    }
                    Text(line.whisper).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if line.flagged { SmallLabel("unsure").fixedSize() }
                }
                ForEach(line.changes) { change in
                    ChangeRow(change: change)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
