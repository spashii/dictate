#if DEBUG
import AppKit
import SwiftUI
import VoiceCore

extension Snapshots {
    /// The window's smallest size, the size it opens at, and a large one.
    static let filterSizes: [(name: String, size: NSSize)] = [
        ("small", NSSize(width: 760, height: 460)),
        ("default", NSSize(width: 1060, height: 680)),
        ("large", NSSize(width: 1440, height: 900)),
    ]

    /// History under each filter with no recordings, the usual few, and more than fit, at each
    /// window size. The list column has to fill the window's height whatever it holds.
    /// The full run draws only the size the window opens at; `--history-filters` draws all three.
    static func historyFilterShots(_ model: AppModel, into folder: URL, work: URL, short: CallStore,
                                   allSizes: Bool, suffix: String, dark: Bool) async throws {
        let empty = try Seed.empty(in: work.appending(path: "empty"))
        let long = try Seed.long(in: work.appending(path: "long"))
        for (list, store) in [("empty", empty), ("short", short), ("long", long)] {
            for filter in HistoryFilter.allCases {
                for (sizeName, size) in filterSizes where allSizes || sizeName == "default" {
                    let name = "history-filter-\(filter.rawValue.lowercased())-\(list)-\(sizeName)-\(suffix)"
                    await write(folder, name, try await filterWindow(model, store: store, filter: filter, size: size, dark: dark))
                }
            }
        }
    }

    static func filterWindow(_ model: AppModel, store: CallStore, filter: HistoryFilter, size: NSSize,
                             dark: Bool) async throws -> NSBitmapImageRep? {
        let navigation = MainNavigation()
        navigation.selection = .history
        let history = HistoryModel(store: store)
        history.filter = filter
        let window = makeWindow(MainView(navigation: navigation, history: history).environment(model)
            .environment(CallsModel()), size: size, dark: dark, titled: true)
        history.reload()
        // The first read selects the list's first row; an empty list selects nothing.
        try await Task.sleep(for: .milliseconds(500))
        for _ in 0..<30 where !history.visible.isEmpty && history.detail == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        // The window grows to fit its panes' minimum widths, so it is drawn at the size it took.
        window.layoutIfNeeded()
        let taken = window.frame.size
        let toolbar = await toolbarFrames(window, height: taken.height)
        let drawn = await withSidebar(await capture(window, size: taken, titled: true), model, .history, size: taken, dark: dark)
        let plus = withPlusButton(drawn, size: taken, dark: dark, frame: toolbar.plus ?? NSRect(x: taken.width - 44, y: 8, width: 36, height: 36))
        return toolbar.search.map { withSearchField(plus, frame: $0, text: "", size: taken, dark: dark) } ?? plus
    }
}

extension Seed {
    /// A history with nothing in it.
    static func empty(in folder: URL) throws -> CallStore {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = folder.appending(path: "history.sqlite")
        _ = try Store(url: database)
        return try CallStore(url: database)
    }

    /// The usual recordings, plus enough of each kind that every filter's list scrolls.
    static func long(in folder: URL) throws -> CallStore {
        let (calls, dictations) = try make(in: folder)
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-4 * 86_400)
        for index in 0..<30 {
            let when = start.addingTimeInterval(-Double(index) * 5_400)
            let text = "Ask Alex about the Northwind schedule, item \(index + 1)."
            let json: [String: Any] = [
                "id": "long-d\(index)", "createdAt": when.timeIntervalSinceReferenceDate,
                "audioPath": folder.appending(path: "long-d\(index).wav").path,
                "duration": 6.0, "mode": "plain", "whisperModel": "large-v3-turbo", "rawText": text, "finalText": text,
                "timings": [String: Int](),
                "segments": [["t0": 0.0, "t1": 6.0, "text": text, "avgLogprob": -0.2, "noSpeechProb": 0.01,
                              "compressionRatio": 1.2, "speechSeconds": 6.0, "wordsPerSecond": 2.5]],
            ]
            try dictations.insert(try JSONDecoder().decode(Dictation.self, from: try JSONSerialization.data(withJSONObject: json)))

            let callStart = when.addingTimeInterval(-1_800)
            let callID = "long-c\(index)"
            _ = try calls.createCall(NewCall(id: callID, startedAt: callStart, appBundleID: "com.example.meeting",
                                             appName: "Meeting", split: true))
            _ = try calls.appendSegments(callID, [NewCallSegment(channel: .call, startMs: 0, endMs: 9_000,
                                                                 text: "Let's go over the Lakeside plan.", avgLogprob: -0.2,
                                                                 noSpeechProb: 0.01, compressionRatio: 1.2)])
            try calls.finishCall(callID, endedAt: callStart.addingTimeInterval(900))
            _ = try calls.setAutoTitle(callID, "Lakeside check-in \(index + 1)")

            let importStart = when.addingTimeInterval(-3_600)
            let importID = "long-i\(index)"
            _ = try calls.createCall(NewCall(id: importID, startedAt: importStart, split: false,
                                             fileName: "Voice memo \(index + 1).m4a",
                                             endedAt: importStart.addingTimeInterval(120), status: .done))
            _ = try calls.appendSegments(importID, [NewCallSegment(channel: .mix, startMs: 0, endMs: 9_000,
                                                                   text: "Notes from the Northwind visit.", avgLogprob: -0.2,
                                                                   noSpeechProb: 0.01, compressionRatio: 1.2)])
            _ = try calls.setAutoTitle(importID, "Northwind visit notes \(index + 1)")
        }
        return calls
    }
}
#endif
