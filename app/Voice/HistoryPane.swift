import AppKit
import SwiftUI
import VoiceCore

/// The list and the selected entry, read from the database off the main thread.
@MainActor @Observable
final class HistoryModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case dictations = "Dictations"
        case calls = "Calls"

        var id: String { rawValue }
    }

    private var entries: [HistoryEntry] = []
    var filter: Filter = .all
    var search = ""
    var selection: HistoryEntry.ID?
    private(set) var detail: HistoryDetail?
    private(set) var waveform: [Float] = []
    let player = HistoryPlayer()
    @ObservationIgnored private var store: CallStore?
    @ObservationIgnored private var loading: Task<Void, Never>?

    var visible: [HistoryEntry] {
        switch filter {
        case .all: entries
        case .dictations: entries.filter { $0.kind == .dictation }
        case .calls: entries.filter { $0.kind == .call }
        }
    }

    var selected: HistoryEntry? { visible.first { $0.id == selection } }

    /// The list as it is now, for the search text; the selection stays when its entry is still there.
    func reload() {
        let query = search
        Task {
            let store = await openStore()
            let read = (try? await Task.detached { try store?.historyEntries(matching: query) ?? [] }.value) ?? []
            guard query == search else { return }
            entries = read
            keepSelection()
        }
    }

    /// Called when the filter changes: a selection the filter hides moves to the first row.
    func keepSelection() {
        if !visible.contains(where: { $0.id == selection }) { selection = visible.first?.id }
        select(selection)
    }

    func select(_ id: HistoryEntry.ID?) {
        loading?.cancel()
        player.stop()
        guard let entry = visible.first(where: { $0.id == id }) else {
            detail = nil
            waveform = []
            return
        }
        loading = Task {
            let store = await openStore()
            let read = try? await Task.detached { try store?.historyDetail(entry) }.value
            guard !Task.isCancelled else { return }
            detail = read ?? nil
            let audio = entry.audioFile
            player.load(audio)
            waveform = []
            if let audio {
                let peaks = await Task.detached(priority: .utility) { try? Waveform.peaks(of: audio, count: 96) }.value
                guard !Task.isCancelled else { return }
                waveform = peaks ?? []
            }
        }
    }

    /// Puts an entry's text on the clipboard, read as it is now, and says whether there was any.
    @discardableResult
    func copy(_ entry: HistoryEntry) async -> Bool {
        guard let store = await openStore() else { return false }
        let item: TranscriptCopy.Item? = switch entry.kind {
        case .call: .call(entry.ref)
        case .dictation: (try? store.dictation(entry.ref)).map { TranscriptCopy.Item.dictation($0) }
        }
        return item.map { TranscriptCopy.copy($0, in: store) } ?? false
    }

    /// Save As for a recording: the file in the format it is stored in, wherever the person says.
    func saveAudio(_ entry: HistoryEntry) {
        guard let name = entry.suggestedAudioName else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try entry.saveAudio(to: destination)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't save the recording"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    private func openStore() async -> CallStore? {
        if let store { return store }
        store = try? await Task.detached { try CallStore(url: Paths.database) }.value
        return store
    }
}

/// History: the list of recordings, and the selected one's transcript with its play bar.
struct HistoryPane: View {
    @Environment(AppModel.self) private var model
    let history: HistoryModel

    var body: some View {
        @Bindable var history = history
        HSplitView {
            HistoryList(history: history)
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 400)
            Group {
                if let entry = history.selected, let detail = history.detail, detail.entry.id == entry.id {
                    HistoryDetailView(history: history, detail: detail)
                } else {
                    ContentUnavailableView("Select a recording", systemImage: "waveform")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity)
        }
        .onAppear { history.reload() }
        .task(id: history.search) {
            // Typing settles for a moment before the database is asked.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            history.reload()
        }
        .onChange(of: history.filter) { history.keepSelection() }
        .onChange(of: history.selection) { _, id in history.select(id) }
    }
}

private struct HistoryList: View {
    @Bindable var history: HistoryModel
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Button {
                    searching.toggle()
                    if searching { searchFocused = true } else { history.search = "" }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Search")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            if searching {
                TextField("Search", text: $history.search)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            Picker("Show", selection: $history.filter) {
                ForEach(HistoryModel.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            if history.visible.isEmpty {
                if history.search.isEmpty {
                    ContentUnavailableView("Nothing yet", systemImage: "clock",
                                           description: Text("Dictations and calls you record show up here."))
                } else {
                    ContentUnavailableView.search(text: history.search)
                }
            } else {
                List(history.visible, selection: $history.selection) { entry in
                    HistoryRow(entry: entry)
                        .contextMenu {
                            Button("Copy") { Task { await history.copy(entry) } }
                        }
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.kind == .call ? "phone" : "mic")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(HistoryTime.title(start: entry.at, zone: entry.timeZone)).fontWeight(.semibold)
                    if let zone = entry.originalZoneLabel {
                        Text(zone).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(HistoryTime.elapsed(entry.duration)).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(entry.firstLine.isEmpty ? entry.title : entry.firstLine)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: Detail

private struct HistoryDetailView: View {
    @Environment(AppModel.self) private var model
    let history: HistoryModel
    let detail: HistoryDetail

    var body: some View {
        let preferences = model.preferences
        let blocks = TranscriptBlocks.make(detail)
        let playing = history.player.hasStarted ? detail.line(at: history.player.currentTime) : nil
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(HistoryTime.title(start: detail.entry.at, zone: detail.entry.timeZone))
                    .font(.title3.weight(.semibold))
                Text("\(detail.entry.kind == .call ? "Call" : "Dictation") \u{00B7} \(HistoryTime.elapsed(detail.entry.duration))")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(blocks) { block in
                            TranscriptBlockView(block: block, detail: detail, playing: playing?.id,
                                                times: preferences.historyTimes,
                                                showCorrections: preferences.showCorrections,
                                                play: { history.player.play(from: $0) })
                                .id(block.id)
                        }
                        if preferences.showCorrections {
                            ForEach(detail.textChanges) { ChangeRow(change: $0).padding(.leading, 20) }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: playing?.id) { _, id in
                    guard history.player.isPlaying, let id,
                          let block = blocks.first(where: { $0.lines.contains { $0.id == id } }) else { return }
                    proxy.scrollTo(block.id)
                }
            }
            Divider()
            PlayBar(player: history.player, waveform: history.waveform, duration: detail.entry.duration)
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    @Bindable var preferences = model.preferences
                    Picker("Time", selection: $preferences.historyTimes) {
                        ForEach(HistoryTimeMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Show corrections", isOn: $preferences.showCorrections)
                    Divider()
                    Button("Save As\u{2026}") { history.saveAudio(detail.entry) }
                        .disabled(detail.entry.audioFile == nil)
                    Button("Copy") { Task { await history.copy(detail.entry) } }
                        .disabled(!detail.entry.hasText)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("More")
            }
        }
    }
}

/// One block of the transcript: its time, who spoke, and the words, laid out so the time, the
/// label and the first line of text share a baseline.
private struct TranscriptBlockView: View {
    let block: TranscriptBlock
    let detail: HistoryDetail
    let playing: Int?
    let times: HistoryTimeMode
    let showCorrections: Bool
    let play: (Double) -> Void
    @State private var hovered: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(HistoryTime.line(start: detail.entry.at, offset: block.start, zone: detail.entry.timeZone, mode: times))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .trailing)
                .overlay(alignment: .leading) {
                    if hovered != nil {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tint)
                            .offset(y: -1)
                    }
                }
            if detail.entry.kind == .call {
                Text(block.speaker ?? "")
                    .fontWeight(.semibold)
                    .foregroundStyle(block.speaker == "Me" ? .primary : .secondary)
                    .frame(width: 40, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                FlowLayout(lineSpacing: 3) {
                    ForEach(block.lines) { line in
                        ForEach(Array(line.words.enumerated()), id: \.offset) { _, word in
                            WordView(word: word, playing: playing == line.id, hovered: hovered == line.id)
                                .onHover { inside in
                                    if inside { hovered = line.id } else if hovered == line.id { hovered = nil }
                                }
                                .onTapGesture { play(line.t0) }
                        }
                    }
                }
                if showCorrections {
                    ForEach(block.lines.flatMap(\.changes)) { ChangeRow(change: $0) }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A word and the space after it, so a highlight over a line has no gaps. A corrected word has a
/// dotted underline, and hovering it says what it was.
private struct WordView: View {
    let word: LineWord
    let playing: Bool
    let hovered: Bool
    @State private var showing = false

    var body: some View {
        HStack(spacing: 0) {
            Text(word.text).underline(word.correction != nil, pattern: .dot)
            Text(" ")
        }
        .background(playing ? Color.accentColor.opacity(0.16) : hovered ? Color.primary.opacity(0.07) : .clear)
        .contentShape(Rectangle())
        .onHover { inside in
            guard word.correction != nil else { return }
            showing = inside
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            if let correction = word.correction { CorrectionPopover(correction: correction) }
        }
    }
}

private struct CorrectionPopover: View {
    let correction: TextCorrection

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            row("Before") { Text(correction.before.isEmpty ? "(nothing)" : correction.before).strikethrough().foregroundStyle(.red) }
            row("After") { Text(correction.after).fontWeight(.semibold).foregroundStyle(.green) }
            row("Made by") { Text(correction.source == .correction ? "Agent correction" : correction.source.rawValue.capitalized) }
            if let before = correction.confidenceBefore {
                row("Confidence before") { Text(Self.percent(before)).monospacedDigit() }
            }
            if let after = correction.confidenceAfter {
                row("Confidence after") { Text(Self.percent(after)).monospacedDigit() }
            }
        }
        .padding(12)
        .font(.callout)
    }

    private func row<Value: View>(_ label: String, @ViewBuilder _ value: () -> Value) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            value()
        }
    }

    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
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
        .font(.callout)
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

// MARK: Play bar

private struct PlayBar: View {
    let player: HistoryPlayer
    let waveform: [Float]
    let duration: Double

    var body: some View {
        let total = player.isLoaded ? player.duration : duration
        HStack(spacing: 12) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!player.isLoaded)
            .help(player.isPlaying ? "Pause" : "Play")
            Text(HistoryTime.elapsed(player.currentTime)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            WaveformScrubber(peaks: waveform, progress: total > 0 ? player.currentTime / total : 0,
                             enabled: player.isLoaded) { player.seek(to: $0 * total) }
                .frame(height: 30)
            Text(HistoryTime.elapsed(total)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }
}

/// Bars for the loudness of the recording, the played part in the accent colour. Click or drag to
/// move the playhead.
private struct WaveformScrubber: View {
    let peaks: [Float]
    let progress: Double
    let enabled: Bool
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let count = max(peaks.count, 1)
                let slot = size.width / CGFloat(count)
                for (index, peak) in peaks.enumerated() {
                    let height = max(2, CGFloat(peak) * size.height)
                    let rect = CGRect(x: CGFloat(index) * slot + slot * 0.2, y: (size.height - height) / 2,
                                      width: slot * 0.6, height: height)
                    let played = Double(index) / Double(count) < progress
                    context.fill(Path(roundedRect: rect, cornerRadius: 1),
                                 with: played ? .color(.accentColor) : .color(.secondary.opacity(0.55)))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard enabled, proxy.size.width > 0 else { return }
                seek(min(max(0, value.location.x / proxy.size.width), 1))
            })
        }
    }
}

// MARK: Layout

/// Words that wrap like text. Each row's height is its tallest word, and the first row's
/// baseline is the layout's, so the time and label beside it line up with the first line.
struct FlowLayout: Layout {
    var lineSpacing: CGFloat = 0

    private struct Arrangement {
        var frames: [CGRect]
        var size: CGSize
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> Arrangement {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width
            widest = max(widest, x)
            rowHeight = max(rowHeight, size.height)
        }
        return Arrangement(frames: frames, size: CGSize(width: widest, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let arranged = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? arranged.size.width, height: arranged.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, arranged.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline, let first = subviews.first else { return nil }
        return bounds.minY + first.dimensions(in: .unspecified)[.firstTextBaseline]
    }
}
