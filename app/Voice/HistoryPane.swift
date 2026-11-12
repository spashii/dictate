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
    /// The detail's blocks, made once when it loads instead of on every redraw.
    private(set) var blocks: [DisplayBlock] = []
    private(set) var detailTitle = ""
    @ObservationIgnored private var blockOfLine: [Int: Int] = [:]
    @ObservationIgnored private var loads = 0
    private(set) var waveform: [Float] = []
    let player = HistoryPlayer()
    @ObservationIgnored private var store: CallStore?
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// How many entries are read; the list grows by a page when its end comes into view.
    @ObservationIgnored private var limit = HistoryModel.page
    private static let page = 200

    var visible: [HistoryEntry] {
        switch filter {
        case .all: entries
        case .dictations: entries.filter { $0.kind == .dictation }
        case .calls: entries.filter { $0.kind == .call }
        }
    }

    var selected: HistoryEntry? { visible.first { $0.id == selection } }

    /// The list as it is now, for the search text. The selection and the open detail stay put,
    /// so a refresh while someone reads or listens changes nothing they are looking at, unless
    /// the selected entry itself changed (an agent corrected it) and nothing is playing.
    func reload() {
        let query = search
        let limit = limit
        Task {
            let store = await openStore()
            let read = (try? await Task.detached { try store?.historyEntries(limit: limit, matching: query) ?? [] }.value) ?? []
            guard query == search else { return }
            let before = selected
            guard read != entries else { return }
            entries = read
            if detail == nil || !visible.contains(where: { $0.id == selection }) {
                keepSelection()
            } else if let before, let now = selected, before != now, !player.isPlaying {
                select(selection)
            }
        }
    }

    /// Reads the next page when the last row is reached and the last read was full.
    func loadMoreIfNeeded(at entry: HistoryEntry) {
        guard entry.id == entries.last?.id, entries.count >= limit else { return }
        limit += Self.page
        reload()
    }

    /// Called when the filter changes: a selection the filter hides moves to the first row.
    func keepSelection() {
        if !visible.contains(where: { $0.id == selection }) { selection = visible.first?.id }
        select(selection)
    }

    /// The id of the block that holds a line, for scrolling to the one being heard.
    func blockID(ofLine line: Int?) -> Int? { line.flatMap { blockOfLine[$0] } }

    /// Opens an entry. What is shown stays until the new detail is read, then everything
    /// changes in one step: a selection never passes through an empty detail.
    func select(_ id: HistoryEntry.ID?) {
        loading?.cancel()
        player.stop()
        guard let entry = visible.first(where: { $0.id == id }) else {
            detail = nil
            blocks = []
            blockOfLine = [:]
            waveform = []
            return
        }
        loads += 1
        let generation = loads
        loading = Task {
            let store = await openStore()
            let read = await Task.detached { () -> (HistoryDetail, [DisplayBlock])? in
                guard let detail = try? store?.historyDetail(entry) else { return nil }
                return (detail, DisplayBlock.make(detail, generation: generation))
            }.value
            guard !Task.isCancelled else { return }
            let audio = entry.audioFile
            let shown = read?.0
            player.lineAt = { seconds in shown?.line(at: seconds)?.id }
            player.load(audio)
            detail = shown
            blocks = read?.1 ?? []
            blockOfLine = Dictionary(blocks.flatMap { block in block.lines.map { ($0.id, block.id) } },
                                     uniquingKeysWith: { first, _ in first })
            detailTitle = HistoryTime.title(start: entry.at, zone: entry.timeZone)
            waveform = []
            guard let audio else { return }
            // A long recording's bars take a moment; the transcript doesn't wait for them.
            let peaks = await Task.detached(priority: .utility) { try? Waveform.peaks(of: audio, count: 96) }.value
            guard !Task.isCancelled else { return }
            waveform = peaks ?? []
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
                // The detail on show stays until the next is read; see HistoryModel.select.
                if history.selection != nil, let detail = history.detail {
                    HistoryDetailView(history: history, detail: detail)
                } else {
                    ContentUnavailableView("Select a recording", systemImage: "waveform")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity)
        }
        .onAppear { history.reload() }
        .task {
            // Recordings finish and agents correct text while the window is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                history.reload()
            }
        }
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

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $history.search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.top, 12)
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
                        .equatable()
                        .onAppear { history.loadMoreIfNeeded(at: entry) }
                        .contextMenu {
                            Button("Copy") { Task { await history.copy(entry) } }
                        }
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct HistoryRow: View, @MainActor Equatable {
    let entry: HistoryEntry

    static func == (a: Self, b: Self) -> Bool { a.entry == b.entry }

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
        @Bindable var preferences = model.preferences
        let blocks = history.blocks
        let player = history.player
        // Read here, so a change of line redraws this body, and a tick of the clock does not.
        let playingLine = player.playingLine
        let playingBlock = history.blockID(ofLine: playingLine)
        let isCall = detail.entry.kind == .call
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(history.detailTitle)
                        .font(.title3.weight(.semibold))
                    Text("\(isCall ? "Call" : "Dictation") \u{00B7} \(HistoryTime.elapsed(detail.entry.duration))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
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
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    // Lazy, with a row's work done when the recording opened: scrolling only
                    // lays out the rows that come into view.
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(blocks) { block in
                            // Only the block holding the playing line is told which it is, so the
                            // others compare equal and are not redrawn when it moves.
                            TranscriptBlockView(block: block, isCall: isCall,
                                                playing: block.id == playingBlock ? playingLine : nil,
                                                times: preferences.historyTimes,
                                                showCorrections: preferences.showCorrections,
                                                play: { player.play(from: $0) })
                                .equatable()
                        }
                        if preferences.showCorrections {
                            ForEach(detail.textChanges) { ChangeRow(change: $0).padding(.leading, 20) }
                        }
                    }
                    .padding(.vertical, 12)
                }
                // A new recording starts at the top; the swap is still one step.
                .id(detail.entry.id)
                .onChange(of: playingBlock) { _, id in
                    guard player.isPlaying, let id else { return }
                    proxy.scrollTo(id)
                }
            }
            Divider()
            PlayBar(player: player, waveform: history.waveform, duration: detail.entry.duration)
        }
    }
}

/// One block of the transcript: its time, who spoke, and the words as one piece of text, so
/// wrapping, the dotted corrections and the highlight of the line being heard cost one text
/// layout per block. The whole row is the target: hovering anywhere in it shows the play
/// mark on the time, and a click plays from the block. To VoiceOver it is one element that
/// reads speaker, time and text, plays from here, and lists its corrections. Return plays it
/// from the keyboard.
private struct TranscriptBlockView: View, @MainActor Equatable {
    let block: DisplayBlock
    let isCall: Bool
    /// The line being heard, when it is in this block.
    let playing: Int?
    let times: HistoryTimeMode
    let showCorrections: Bool
    let play: (Double) -> Void
    @State private var hovered = false
    @State private var textWidth: CGFloat = 0
    @State private var layout: BlockTextLayout?
    @State private var hoveredMark: DisplayBlock.Mark?
    @State private var markFrame: CGRect = .zero

    static func == (a: Self, b: Self) -> Bool {
        a.block == b.block && a.isCall == b.isCall && a.playing == b.playing && a.times == b.times
            && a.showCorrections == b.showCorrections
    }

    var body: some View {
        let time = times == .clock ? block.clock : block.elapsed
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(time)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .trailing)
                .overlay(alignment: .leading) {
                    if hovered {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tint)
                            .offset(y: -1)
                    }
                }
            if isCall {
                Text(block.showsSpeaker ? block.speaker ?? "" : "")
                    .fontWeight(.semibold)
                    .foregroundStyle(SpeakerColors.color(for: block.speaker))
                    .frame(width: 40, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(block.text(heard: playing))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hoverText(at: point)
                        case .ended: hoveredMark = nil
                        }
                    }
                    .modifier(CorrectionPopoverHost(enabled: !block.marks.isEmpty, mark: $hoveredMark, frame: markFrame))
                    // A click in the text plays from the line it lands in; one anywhere else
                    // in the row plays from the block.
                    .gesture(SpatialTapGesture().onEnded { tap in
                        let offset = textLayout()?.offset(at: tap.location, nearest: true)
                        play(offset.map(block.start(at:)) ?? block.start)
                    })
                if showCorrections {
                    ForEach(block.changes) { ChangeRow(change: $0) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { play(block.start) }
        .focusable()
        .onKeyPress(.return) {
            play(block.start)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(block.spokenLabel(times))
        .accessibilityAction(named: "Play from here") { play(block.start) }
        .modifier(CorrectionContent(descriptions: block.correctionDescriptions))
    }
}

extension TranscriptBlockView {
    /// The layout for the row's current width, made when first needed.
    private func textLayout() -> BlockTextLayout? {
        guard textWidth > 0 else { return nil }
        if let layout, layout.width == textWidth { return layout }
        let made = BlockTextLayout(string: block.string, width: textWidth)
        layout = made
        return made
    }

    /// Opens the popover while the pointer is on a corrected word; blocks with no
    /// corrections do no work.
    private func hoverText(at point: CGPoint) {
        guard !block.marks.isEmpty, let layout = textLayout() else { return }
        let mark = layout.offset(at: point, nearest: false).flatMap { offset in
            block.marks.first { $0.range.contains(offset) }
        }
        guard mark != hoveredMark else { return }
        hoveredMark = mark
        markFrame = mark.map { layout.rect(of: $0.range) } ?? .zero
    }
}

/// The popover for the corrected word under the pointer, on rows that have any.
private struct CorrectionPopoverHost: ViewModifier {
    let enabled: Bool
    @Binding var mark: DisplayBlock.Mark?
    let frame: CGRect

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.popover(isPresented: Binding(get: { mark != nil }, set: { if !$0 { mark = nil } }),
                            attachmentAnchor: .rect(.rect(frame)), arrowEdge: .bottom) {
                if let mark { CorrectionPopover(correction: mark.correction) }
            }
        } else {
            content
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

/// Each correction as a detail VoiceOver reads on request, so none depends on hovering.
private struct CorrectionContent: ViewModifier {
    let descriptions: [String]

    func body(content: Content) -> some View {
        descriptions.enumerated().reduce(AnyView(content)) { view, item in
            AnyView(view.accessibilityCustomContent(AccessibilityCustomContentKey("Correction \(item.offset + 1)"), item.element))
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
                             enabled: player.isLoaded,
                             value: "\(HistoryTime.elapsed(player.currentTime)) of \(HistoryTime.elapsed(total))",
                             step: { player.seek(to: player.currentTime + Double($0) * 5) },
                             seek: { player.seek(to: $0 * total) })
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
    /// "0:12 of 1:05", read by VoiceOver.
    let value: String
    /// Moves the playhead by this many five-second steps, for VoiceOver's adjust gestures.
    let step: (Int) -> Void
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
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(value)
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }
}
