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
    /// The row whose title is being edited, and the recording a Delete is waiting on.
    var renaming: HistoryEntry.ID?
    var pendingDelete: HistoryEntry?
    /// Told after a rename or delete, so the menu bar's recent items follow.
    @ObservationIgnored var changed: () -> Void = {}
    private(set) var detail: HistoryDetail?
    /// The detail's blocks, made once when it loads instead of on every redraw.
    private(set) var blocks: [DisplayBlock] = []
    /// The words searched for inside the open recording, and where each is: a stretch of one
    /// block's text, as TextKit counts it. Searching walks each block's string once; nothing
    /// is laid out per match.
    var findText = "" {
        didSet { if findText != oldValue { rebuildMatches(restart: true) } }
    }
    struct FindMatch: Equatable {
        let block: Int
        let range: Range<Int>
    }
    private(set) var matches: [FindMatch] = []
    private(set) var currentMatch = 0
    private(set) var matchesByBlock: [Int: [Range<Int>]] = [:]
    @ObservationIgnored private var blockOfLine: [Int: Int] = [:]
    @ObservationIgnored private var loads = 0
    /// Makes each set of blocks differ from the last, so a row redraws only when its text did.
    @ObservationIgnored private var generations = 0
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

    var activeMatch: FindMatch? { matches.indices.contains(currentMatch) ? matches[currentMatch] : nil }

    /// Which of a block's matches is the one stepped to, if it is in that block.
    func activeIndex(inBlock id: Int) -> Int? {
        guard let active = activeMatch, active.block == id else { return nil }
        return matchesByBlock[id]?.firstIndex(of: active.range)
    }

    /// Moves to the next match, or the previous with a negative step, wrapping round.
    func stepMatch(_ step: Int) {
        guard !matches.isEmpty else { return }
        currentMatch = (currentMatch + step + matches.count) % matches.count
    }

    private func rebuildMatches(restart: Bool) {
        let needle = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        var found: [FindMatch] = []
        if !needle.isEmpty {
            for block in blocks {
                let text = block.string as NSString
                var from = 0
                while from < text.length {
                    let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                           range: NSRange(location: from, length: text.length - from))
                    guard range.location != NSNotFound, range.length > 0 else { break }
                    found.append(FindMatch(block: block.id, range: range.location..<range.location + range.length))
                    from = range.location + range.length
                }
            }
        }
        matches = found
        matchesByBlock = Dictionary(grouping: found, by: \.block).mapValues { $0.map(\.range) }
        if restart || currentMatch >= found.count { currentMatch = 0 }
    }

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
            } else if let before, let now = selected, before != now {
                refreshDetail()
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
            rebuildMatches(restart: true)
            blockOfLine = [:]
            waveform = []
            return
        }
        loads += 1
        generations += 1
        let generation = generations
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
            rebuildMatches(restart: true)
            blockOfLine = Dictionary(blocks.flatMap { block in block.lines.map { ($0.id, block.id) } },
                                     uniquingKeysWith: { first, _ in first })
            waveform = []
            guard let audio else { return }
            // A long recording's bars take a moment; the transcript doesn't wait for them.
            let peaks = await Task.detached(priority: .utility) { try? Waveform.peaks(of: audio, count: 96) }.value
            guard !Task.isCancelled else { return }
            waveform = peaks ?? []
        }
    }

    /// The correction for the words at `range` of a block's text, within the line they start in.
    func correction(in block: DisplayBlock, range: Range<Int>) -> HandCorrection? {
        guard let detail, let line = block.lineRange(at: range.lowerBound) else { return nil }
        let end = min(range.upperBound, line.range.upperBound)
        let text = block.string as NSString
        guard range.lowerBound >= line.range.lowerBound, end > range.lowerBound else { return nil }
        let selected = text.substring(with: NSRange(location: range.lowerBound, length: end - range.lowerBound))
        // The view counts UTF-16 units; the core counts characters.
        let before = text.substring(with: NSRange(location: line.range.lowerBound,
                                                  length: range.lowerBound - line.range.lowerBound))
        return detail.correction(line: line.id, selecting: selected, at: before.count)
    }

    /// False for a dictation whose pasted text differs from the transcript shown.
    var canCorrect: Bool { detail?.canCorrect ?? false }

    /// Stores the correction the way an agent's is stored, then reads the recording again.
    /// Returns what went wrong, if anything.
    func save(_ request: HandCorrection, to text: String, known: [String]) async -> String? {
        guard let store = await openStore() else { return "Couldn't open the history." }
        do {
            try await Task.detached { try store.correct(request, to: text, known: known) }.value
        } catch {
            return "\(error)"
        }
        refreshDetail()
        reload()
        return nil
    }

    /// Starts editing a row's title in place.
    func beginRename(_ entry: HistoryEntry) {
        selection = entry.id
        renaming = entry.id
    }

    /// Gives the recording the title, or takes it away when it is blank.
    func rename(_ entry: HistoryEntry, to text: String) {
        renaming = nil
        guard text.trimmingCharacters(in: .whitespacesAndNewlines) != (entry.customTitle ?? "") else { return }
        Task {
            guard let store = await openStore() else { return }
            _ = try? await Task.detached { try store.rename(entry.kind, entry.ref, to: text) }.value
            reload()
            changed()
        }
    }

    /// Deletes the recording, then moves the selection to the row after it, or the one
    /// before when it was last, as Mail does.
    func delete(_ entry: HistoryEntry) {
        pendingDelete = nil
        let list = visible
        let index = list.firstIndex(of: entry)
        let next = index.flatMap { list.indices.contains($0 + 1) ? list[$0 + 1].id : ($0 > 0 ? list[$0 - 1].id : nil) }
        Task {
            guard let store = await openStore() else { return }
            do {
                try await Task.detached { try store.deleteRecording(entry.kind, entry.ref) }.value
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't delete the recording"
                alert.informativeText = "\(error)"
                alert.runModal()
                return
            }
            entries.removeAll { $0.id == entry.id }
            if selection == entry.id { selection = next }
            reload()
            changed()
        }
    }

    /// Reads the open recording again after its words or title changed. Only the transcript
    /// is swapped: playback, its position and the waveform stay as they are.
    func refreshDetail() {
        guard let entry = selected else { return }
        let opened = loads
        generations += 1
        let generation = generations
        Task {
            let store = await openStore()
            let read = await Task.detached { () -> (HistoryDetail, [DisplayBlock])? in
                guard let detail = try? store?.historyDetail(entry) else { return nil }
                return (detail, DisplayBlock.make(detail, generation: generation))
            }.value
            guard let read, opened == loads, selection == entry.id else { return }
            player.lineAt = { seconds in read.0.line(at: seconds)?.id }
            detail = read.0
            blocks = read.1
            rebuildMatches(restart: false)
            blockOfLine = Dictionary(read.1.flatMap { block in block.lines.map { ($0.id, block.id) } },
                                     uniquingKeysWith: { first, _ in first })
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
        .onAppear {
            history.changed = { model.refreshRecents() }
            history.reload()
        }
        .onKeyPress(keys: [.delete], phases: .down) { press in
            guard press.modifiers == .command, history.renaming == nil, let entry = history.selected else { return .ignored }
            history.pendingDelete = entry
            return .handled
        }
        .confirmationDialog(
            history.pendingDelete.map { "Delete \u{201C}\($0.deletionName)\u{201D}?" } ?? "",
            isPresented: Binding(get: { history.pendingDelete != nil }, set: { if !$0 { history.pendingDelete = nil } }),
            titleVisibility: .visible, presenting: history.pendingDelete) { entry in
            Button("Delete", role: .destructive) { history.delete(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes its audio and transcript from this Mac.")
        }
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
                ScrollViewReader { proxy in
                    List(history.visible, selection: $history.selection) { entry in
                        HistoryRow(entry: entry, renaming: history.renaming == entry.id,
                                   commit: { history.rename(entry, to: $0) }, cancel: { history.renaming = nil })
                            .equatable()
                            .onAppear { history.loadMoreIfNeeded(at: entry) }
                            .contextMenu {
                                Button("Copy") { Task { await history.copy(entry) } }
                                Button("Rename") { history.beginRename(entry) }
                                Divider()
                                Button("Delete\u{2026}", role: .destructive) { history.pendingDelete = entry }
                            }
                            .accessibilityAction(named: "Rename") { history.beginRename(entry) }
                            .accessibilityAction(named: "Delete") { history.pendingDelete = entry }
                    }
                    .listStyle(.inset)
                    // Return renames the selected row, as in Finder.
                    .onKeyPress(.return) {
                        guard history.renaming == nil, let entry = history.selected else { return .ignored }
                        history.beginRename(entry)
                        return .handled
                    }
                    .onChange(of: history.renaming) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View, @MainActor Equatable {
    let entry: HistoryEntry
    let renaming: Bool
    let commit: (String) -> Void
    let cancel: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.entry == b.entry && a.renaming == b.renaming }

    var body: some View {
        let date = HistoryTime.title(start: entry.at, zone: entry.timeZone)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.kind == .call ? "phone" : "mic")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if renaming {
                        RenameField(initial: entry.customTitle ?? "", prompt: date, commit: commit, cancel: cancel)
                    } else {
                        Text(entry.customTitle ?? date).fontWeight(.semibold).lineLimit(1)
                        if entry.customTitle == nil, let zone = entry.originalZoneLabel {
                            Text(zone).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(HistoryTime.elapsed(entry.duration)).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(secondLine(date: date))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    /// A renamed recording keeps its date and time here; one without a name shows what it
    /// was, and the first words.
    private func secondLine(date: String) -> String {
        let preview = entry.firstLine.isEmpty ? entry.title : entry.firstLine
        if entry.customTitle != nil {
            return [date + (entry.originalZoneLabel.map { " \($0)" } ?? ""),
                    entry.kind == .call ? entry.kindLabel : nil].compactMap { $0 }.joined(separator: " \u{00B7} ")
        }
        guard entry.kind == .call else { return preview }
        return [entry.kindLabel, entry.firstLine.isEmpty ? nil : preview].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}

/// The title field in a row: Return or clicking away keeps it, Escape leaves the title as it was.
private struct RenameField: View {
    @State private var text: String
    let prompt: String
    let commit: (String) -> Void
    let cancel: () -> Void
    @State private var finished = false
    @FocusState private var focused: Bool

    init(initial: String, prompt: String, commit: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        _text = State(initialValue: initial)
        self.prompt = prompt
        self.commit = commit
        self.cancel = cancel
    }

    var body: some View {
        TextField("Title", text: $text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .fontWeight(.semibold)
            .focused($focused)
            .onSubmit { finish(keep: true) }
            .onExitCommand { finish(keep: false) }
            .onChange(of: focused) { _, now in
                if !now { finish(keep: true) }
            }
            .onAppear { focused = true }
    }

    private func finish(keep: Bool) {
        guard !finished else { return }
        finished = true
        if keep { commit(text) } else { cancel() }
    }
}

extension HistoryEntry {
    /// What a confirmation calls it: the title it was given, or what it is and when.
    var deletionName: String {
        customTitle ?? "\(kindLabel) from \(HistoryTime.title(start: at, zone: timeZone))"
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
        // The list's copy of the entry is the one a rename changes.
        let entry = history.selected ?? detail.entry
        let date = HistoryTime.title(start: entry.at, zone: entry.timeZone)
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.customTitle ?? date)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text([entry.customTitle == nil ? nil : date, entry.kindLabel, HistoryTime.elapsed(entry.duration)]
                        .compactMap { $0 }.joined(separator: " \u{00B7} "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                FindBar(history: history)
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
                    Divider()
                    Button("Rename") { history.beginRename(entry) }
                    Button("Delete\u{2026}", role: .destructive) { history.pendingDelete = entry }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    if blocks.isEmpty {
                        ContentUnavailableView("No transcript", systemImage: "text.alignleft",
                                               description: Text("Nothing was transcribed for this recording."))
                            .padding(.top, 60)
                    }
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
                                                play: { player.play(from: $0) },
                                                correctable: detail.canCorrect,
                                                find: history.matchesByBlock[block.id] ?? [],
                                                activeFind: history.activeIndex(inBlock: block.id),
                                                draft: { history.correction(in: $0, range: $1) },
                                                save: { await history.save($0, to: $1, known: KeyTerms.parse(preferences.keyTerms)) })
                                .equatable()
                        }
                        if preferences.showCorrections {
                            ForEach(detail.textChanges) { ChangeRow(change: $0).padding(.leading, 20) }
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 8)
                }
                // A new recording starts at the top; the swap is still one step.
                .id(detail.entry.id)
                .onChange(of: history.currentMatch) {
                    if let block = history.activeMatch?.block { proxy.scrollTo(block, anchor: .center) }
                }
                .onChange(of: history.findText) {
                    if let block = history.activeMatch?.block { proxy.scrollTo(block, anchor: .center) }
                }
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

/// The search inside the open recording: a field with the count and steppers. Return and Cmd+G
/// go to the next match, Shift+Return and Shift+Cmd+G to the one before, and Cmd+F comes here.
private struct FindBar: View {
    @Bindable var history: HistoryModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if !history.findText.isEmpty {
                Text(history.matches.isEmpty ? "No matches" : "\(history.currentMatch + 1) of \(history.matches.count)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(history.matches.isEmpty ? "No matches"
                                        : "Match \(history.currentMatch + 1) of \(history.matches.count)")
                Button { history.stepMatch(-1) } label: { Image(systemName: "chevron.up") }
                    .help("Previous match")
                    .accessibilityLabel("Previous match")
                Button { history.stepMatch(1) } label: { Image(systemName: "chevron.down") }
                    .help("Next match")
                    .accessibilityLabel("Next match")
            }
            TextField("Find", text: $history.findText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
                .focused($focused)
                .onSubmit { history.stepMatch(1) }
                .onExitCommand {
                    history.findText = ""
                    focused = false
                }
                .accessibilityLabel("Find in this recording")
            // Shortcuts with no place of their own on screen.
            Group {
                Button("Previous match") { history.stepMatch(-1) }.keyboardShortcut(.return, modifiers: .shift)
                Button("Next match") { history.stepMatch(1) }.keyboardShortcut("g", modifiers: .command)
                Button("Previous match") { history.stepMatch(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Find") { focused = true }.keyboardShortcut("f", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
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
    /// The correction for words at a range of the block's text, and its storing; nil from
    /// save when it worked, else what went wrong.
    /// False when what is drawn isn't the stored text, so a correction would change the wrong words.
    let correctable: Bool
    /// The found words in this block, and which of them is the one stepped to.
    let find: [Range<Int>]
    let activeFind: Int?
    let draft: (DisplayBlock, Range<Int>) -> HandCorrection?
    let save: (HandCorrection, String) async -> String?
    @State private var hovered = false
    /// The words a drag selected, in the block's text; a right click or a key corrects the
    /// words under the pointer or the line when nothing is selected.
    @State private var selection: Range<Int>?
    @State private var editing: Editing?
    @State private var pointer = Pointer()
    @State private var textWidth: CGFloat = 0
    @State private var layout: BlockTextLayout?
    @State private var hoveredMark: DisplayBlock.Mark?
    @State private var markFrame: CGRect = .zero

    static func == (a: Self, b: Self) -> Bool {
        a.block == b.block && a.correctable == b.correctable && a.find == b.find && a.activeFind == b.activeFind && a.isCall == b.isCall && a.playing == b.playing && a.times == b.times
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
                Text(shownText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            pointer.point = point
                            hoverText(at: point)
                        case .ended: hoveredMark = nil
                        }
                    }
                    .modifier(CorrectionPopoverHost(enabled: !block.marks.isEmpty, mark: $hoveredMark, frame: markFrame))
                    // A click in the text plays from the line it lands in; one anywhere else
                    // in the row plays from the block.
                    .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { drag in
                        guard let layout = textLayout(),
                              let from = layout.offset(at: drag.startLocation, nearest: true),
                              let to = layout.offset(at: drag.location, nearest: true) else { return }
                        selection = block.phrase(from: from, to: to)
                    })
                    .contextMenu {
                        Button("Correct\u{2026}") { correctUnderPointer() }
                    }
                    .gesture(SpatialTapGesture().onEnded { tap in
                        selection = nil
                        let offset = textLayout()?.offset(at: tap.location, nearest: true)
                        play(offset.map(block.start(at:)) ?? block.start)
                    })
                if showCorrections {
                    ForEach(block.changes) { ChangeRow(change: $0) }
                }
            }
            .modifier(CorrectionEditorHost(editing: $editing, save: save))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovered ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            selection = nil
            play(block.start)
        }
        .focusable()
        .onKeyPress(.return) {
            play(block.start)
            return .handled
        }
        .onKeyPress(KeyEquivalent("e")) {
            correctLine()
            return .handled
        }
        .onChange(of: block.generation) {
            selection = nil
            editing = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(block.spokenLabel(times))
        .accessibilityAction(named: "Play from here") { play(block.start) }
        .accessibilityAction(named: "Correct\u{2026}") { correctLine() }
        .modifier(CorrectionContent(descriptions: block.correctionDescriptions))
    }
}

extension TranscriptBlockView {
    /// The block's text with the line being heard and the selected words marked.
    private var shownText: AttributedString {
        var text = block.text(heard: playing)
        for (index, found) in find.enumerated() {
            if let range = Range(NSRange(location: found.lowerBound, length: found.count), in: text) {
                text[range].swiftUI.backgroundColor = Color.accentColor.opacity(index == activeFind ? 0.5 : 0.22)
            }
        }
        if let selection, let range = Range(NSRange(location: selection.lowerBound, length: selection.count), in: text) {
            text[range].swiftUI.backgroundColor = Color(nsColor: .selectedTextBackgroundColor)
        }
        return text
    }

    /// Right click: the selection when the pointer is in it, else the word under the pointer.
    private func correctUnderPointer() {
        guard let layout = textLayout(), let offset = layout.offset(at: pointer.point, nearest: false) else { return }
        if let selection, selection.contains(offset) {
            begin(selection, layout: layout)
        } else if let word = block.word(at: offset) {
            selection = word
            begin(word, layout: layout)
        }
    }

    /// Keyboard and VoiceOver: the whole line, which the person then edits as text.
    private func correctLine() {
        guard let layout = textLayout() else { return }
        let offset = playing.flatMap { id in block.spans.first { $0.id == id }?.start } ?? 0
        guard let line = block.lineRange(at: offset) else { return }
        selection = line.range
        begin(line.range, layout: layout)
    }

    private func begin(_ range: Range<Int>, layout: BlockTextLayout) {
        hoveredMark = nil
        guard correctable else {
            editing = Editing(request: nil, rect: layout.rect(of: range))
            return
        }
        guard let request = draft(block, range) else { return }
        editing = Editing(request: request, rect: layout.rect(of: range))
    }

    /// The layout for the row's current width, made when first needed.
    private func textLayout() -> BlockTextLayout? {
        guard textWidth > 0 else { return nil }
        if let layout, layout.width == textWidth, layout.string == block.string { return layout }
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

/// The pointer's last place in the text, kept off the view's state so moving it redraws nothing.
private final class Pointer {
    var point: CGPoint = .zero
}

private struct Editing: Identifiable {
    let id = UUID()
    /// Nil when the recording can't be corrected, and the popover says so.
    let request: HandCorrection?
    let rect: CGRect
}

/// The popover that corrects the selected words.
private struct CorrectionEditorHost: ViewModifier {
    @Binding var editing: Editing?
    let save: (HandCorrection, String) async -> String?

    func body(content: Content) -> some View {
        content.popover(item: $editing, attachmentAnchor: .rect(.rect(editing?.rect ?? .zero)), arrowEdge: .bottom) { item in
            if let request = item.request {
                CorrectionEditor(original: request.selected,
                                 save: { await save(request, $0) },
                                 done: { editing = nil })
            } else {
                Text("Clean-up rewrote this dictation, so its words can't be corrected here.")
                    .padding(12)
                    .frame(width: 260, alignment: .leading)
            }
        }
    }
}

private struct CorrectionEditor: View {
    let original: String
    let save: (String) async -> String?
    let done: () -> Void
    @State private var text: String
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    init(original: String, save: @escaping (String) async -> String?, done: @escaping () -> Void) {
        self.original = original
        self.save = save
        self.done = done
        _text = State(initialValue: original)
    }

    private var changed: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines) != original }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Corrected text", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: max(200, min(CGFloat(original.count) * 8 + 40, 420)))
                    .focused($focused)
                    .onSubmit(commit)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!changed || saving)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func commit() {
        guard changed, !saving else { return }
        saving = true
        Task {
            error = await save(text)
            saving = false
            if error == nil { done() }
        }
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
            row("Made by") { Text(Self.madeBy(correction)) }
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

    private static func madeBy(_ correction: TextCorrection) -> String {
        guard correction.source == .correction else { return correction.source.rawValue.capitalized }
        return correction.client == Edit.personClient ? Edit.personClient : "Agent correction"
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
