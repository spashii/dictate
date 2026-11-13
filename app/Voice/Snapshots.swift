#if DEBUG
import AppKit
import CryptoKit
import SwiftUI
import VoiceCore

/// `Dictate Dev --app-shots FOLDER` draws the real views with made-up data into PNGs, at 2x in
/// light and dark, and quits. Nothing is shown on screen and no screen is captured: each view
/// is laid out in a window that is never ordered front and drawn into a bitmap. ImageRenderer
/// would not do, since the History list, its split view and the sidebar are AppKit controls it
/// leaves blank. Debug builds only; the data lives in a temporary folder and never touches the
/// person's own history.
@MainActor
enum Snapshots {
    static var folder: URL? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--app-shots"), arguments.indices.contains(flag + 1) else { return nil }
        return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    }

    static func run(into folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let work = FileManager.default.temporaryDirectory.appending(path: "dictate-app-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: folder.appending(path: "site-tile"), withIntermediateDirectories: true)
            let (store, dictationStore) = try Seed.make(in: work)
            let model = AppModel(activation: Self.activated())
            model.snapshotSetupComplete = true
            model.unlockForSnapshots()

            let locked = AppModel(activation: Activation(store: MemoryActivationStore()))

            for dark in [false, true] {
                let suffix = dark ? "dark" : "light"
                let history = HistoryModel(store: store)
                let window = try await historyWindow(model, history, dark: dark)
                await write(folder, "history-\(suffix)", window)
                await write(folder, "history-search-\(suffix)",
                            try await historyWindow(model, HistoryModel(store: store), search: "pilot", dark: dark))
                for (name, width) in [("narrow", 260.0), ("wide", 400.0)] {
                    await write(folder, "history-\(name)-list-\(suffix)",
                                try await historyWindow(model, HistoryModel(store: store), listWidth: width, dark: dark))
                }
                await write(folder, "history-naming-\(suffix)", try await namingWindow(model, store: store, dark: dark))
                await write(folder, "transcript-hover-\(suffix)", try await transcriptHoverWindow(model, store: store, dark: dark))
                await write(folder, "history-plus-menu-\(suffix)", try await plusMenu(model, store: store, dark: dark))
                await write(folder, "history-import-progress-\(suffix)",
                            try await importWindow(model, store: store, selecting: "call:interview", dark: dark))
                await write(folder, "history-import-detail-\(suffix)",
                            try await importWindow(model, store: store, selecting: "call:memo", dark: dark))
                // The site shows the list and the detail without the sidebar and the title bar.
                await write(folder.appending(path: "site-tile"), "history-\(suffix)",
                            crop(window, x: 208, top: 52, width: 852, height: 300))
                await write(folder, "keyterm-added-\(suffix)", try await keyTermAdded(model, history, dark: dark))
                await write(folder, "recent-menu-\(suffix)", await recentMenu(model, store: store, dictations: dictationStore, dark: dark))
                let both = ["qwen3.5:9b", "gemma3:4b"]
                await write(folder, "model-settings-apple-\(suffix)",
                            try await modelSettings(model, apple: .available, ollama: both, choice: .apple, dark: dark))
                await write(folder, "model-settings-apple-off-\(suffix)",
                            try await modelSettings(model, apple: .turnedOff, ollama: both, choice: .apple, dark: dark))
                await write(folder, "model-settings-ollama-stopped-\(suffix)",
                            try await modelSettings(model, apple: .available, ollama: nil, choice: .apple, dark: dark))
                await write(folder, "model-settings-apple-off-ollama-stopped-\(suffix)",
                            try await modelSettings(model, apple: .turnedOff, ollama: nil, choice: .ollama("qwen3.5:9b"), dark: dark))
                await write(folder, "model-picker-\(suffix)",
                            await modelPicker(model, apple: .available, ollama: both, choice: .apple, dark: dark))
                await write(folder, "model-picker-apple-off-ollama-stopped-\(suffix)",
                            await modelPicker(model, apple: .turnedOff, ollama: nil, choice: .apple, dark: dark))
                await write(folder, "agents-tools-\(suffix)", try await agentsSettings(model, dark: dark))
                await write(folder, "welcome-\(suffix)", try await welcomeWindow(locked, dark: dark))
                await write(folder, "about-\(suffix)", try await aboutWindow(model, dark: dark))
                try await measureShots(model, into: folder, suffix: suffix, dark: dark)
                await write(folder, "about-expanded-\(suffix)", try await aboutWindow(model, expanded: true, dark: dark))
                model.updates.setAvailableForSnapshots(Self.fixtureUpdate)
                await write(folder, "about-update-\(suffix)", try await aboutWindow(model, dark: dark))
                await write(folder, "sidebar-update-\(suffix)", try await historyWindow(model, history, dark: dark))
                model.updates.setAvailableForSnapshots(nil)
                await write(folder, "dictation-pill-\(suffix)", await dictationPill(model, dark: dark))
                await write(folder, "call-pill-\(suffix)", await callPill(dark: dark))
                await write(folder, "record-call-nudge-\(suffix)", await nudge(model, dark: dark))
            }
        } catch {
            DevLog.write("app-shots failed: \(error)")
        }
        exit(0)
    }

    // MARK: Views

    private static func welcomeWindow(_ model: AppModel, dark: Bool) async throws -> NSBitmapImageRep? {
        let navigation = MainNavigation()
        navigation.selection = .welcome
        let size = NSSize(width: 1060, height: 680)
        let window = makeWindow(MainView(navigation: navigation, history: HistoryModel()).environment(model)
            .environment(CallsModel()), size: size, dark: dark, titled: true)
        return await withSidebar(await capture(window, size: size, titled: true), model, .welcome, size: size, dark: dark)
    }

    private static let fixtureUpdate = AvailableUpdate(version: "0.15.0", notes: Changelog.bullets(fromDescription: """
        <ul><li>Drop an audio or video file on History to transcribe it.</li>\
        <li>History has a + button for a new dictation or call.</li>\
        <li>Agents can bring in an audio file by path. The tool is off until you turn it on.</li></ul>
        """))

    private static func dictationPill(_ model: AppModel, dark: Bool) async -> NSBitmapImageRep? {
        model.phase = .recording(.fix, Date().addingTimeInterval(-7))
        model.level = 0.55
        model.liveText = "Send Alex the Northwind proposal before Friday, and ask whether the pilot numbers are in."
        let size = NSSize(width: 480, height: 96)
        let view = Backdrop(dark: dark) {
            IndicatorView().environment(model).environment(PillHoverState())
        }
        let window = makeWindow(view, size: size, dark: dark, titled: false)
        let data = await capture(window, size: size, titled: false)
        model.phase = .idle
        return data
    }

    private static func callPill(dark: Bool) async -> NSBitmapImageRep? {
        let lines = [
            LiveCallLines.Line(id: 1, channel: .call, label: "Call", text: "Did the pilot numbers come through?"),
            LiveCallLines.Line(id: 2, channel: .me, label: "Me", text: "They did. Retention is up twelve percent."),
            LiveCallLines.Line(id: 3, channel: .call, label: "Call", text: "That is better than we expected."),
        ]
        let size = NSSize(width: 480, height: 116)
        let view = Backdrop(dark: dark) {
            CallPill(startedAt: Date().addingTimeInterval(-134), stopHint: "\u{2325}\u{21E7}` stops", lines: lines)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 4)
        }
        return await capture(makeWindow(view, size: size, dark: dark, titled: false), size: size, titled: false)
    }

    private static func nudge(_ model: AppModel, dark: Bool) async -> NSBitmapImageRep? {
        let calls = CallsModel()
        calls.promptForSnapshots(DetectedCall(bundleID: "com.example.meeting", name: "Meeting"), model: model)
        let size = NSSize(width: 420, height: 92)
        let view = Backdrop(dark: dark) {
            CallPromptView().environment(calls).frame(width: 340, height: 44)
        }
        return await capture(makeWindow(view, size: size, dark: dark, titled: false), size: size, titled: false)
    }

    static func historyWindow(_ model: AppModel, _ history: HistoryModel, calls: CallsModel = CallsModel(),
                              selecting id: String = "call:rollout", search: String = "", listWidth: CGFloat? = nil, dark: Bool) async throws -> NSBitmapImageRep? {
        let navigation = MainNavigation()
        navigation.selection = .history
        let size = NSSize(width: 1060, height: 680)
        let window = makeWindow(MainView(navigation: navigation, history: history).environment(model)
            .environment(calls), size: size, dark: dark, titled: true)
        history.search = search
        history.reload()
        for _ in 0..<40 where history.visible.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        guard let call = history.visible.first(where: { $0.id == id }) else {
            throw VoiceError.store("The seeded call is missing.")
        }
        history.selection = call.id
        history.select(call.id)
        for _ in 0..<40 where history.detail == nil || history.waveform.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        if let listWidth { widenList(window, to: listWidth) }
        let toolbar = await toolbarFrames(window, height: size.height)
        let sidebar = await withSidebar(await capture(window, size: size, titled: true), model, .history, size: size, dark: dark)
        let plus = withPlusButton(sidebar, size: size, dark: dark, frame: toolbar.plus ?? plusButton)
        return toolbar.search.map { withSearchField(plus, frame: $0, text: search, size: size, dark: dark) } ?? plus
    }

    /// Where History's + sits in the window, in points from its top left: the toolbar button the bitmap draw puts at the
    /// trailing edge.
    static let plusButton = NSRect(x: 1016, y: 8, width: 36, height: 36)

    /// A bitmap draw of the window leaves the toolbar's button without its round background and
    /// greys its symbol, so the button is drawn over it the way the sidebar symbol is.
    static func withPlusButton(_ window: NSBitmapImageRep?, size: NSSize, dark: Bool, frame placed: NSRect = plusButton) -> NSBitmapImageRep? {
        guard let window,
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: window.pixelsWide, pixelsHigh: window.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: out) else { return window }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        window.draw(in: NSRect(origin: .zero, size: size))
        let frame = NSRect(x: placed.minX, y: size.height - placed.maxY, width: placed.width, height: placed.height)
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.35 : 0.12)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            (dark ? NSColor(white: 0.24, alpha: 1) : NSColor(white: 0.985, alpha: 1)).setFill()
            NSBezierPath(ovalIn: frame).fill()
            NSGraphicsContext.restoreGraphicsState()
            (dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.1)).setStroke()
            let ring = NSBezierPath(ovalIn: frame.insetBy(dx: 0.25, dy: 0.25))
            ring.lineWidth = 0.5
            ring.stroke()
            if let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
                let tint = dark ? NSColor(white: 1, alpha: 0.85) : NSColor(white: 0, alpha: 0.75)
                let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                    symbol.draw(in: rect)
                    tint.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(at: NSPoint(x: frame.midX - symbol.size.width / 2, y: frame.midY - symbol.size.height / 2),
                            from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    /// A bitmap draw of the window leaves the sidebar blank, so the real sidebar is drawn on
    /// its own and laid over that part of the window, with the window's three buttons.
    static func withSidebar(_ window: NSBitmapImageRep?, _ model: AppModel, _ pane: MainPane,
                                    size: NSSize, dark: Bool) async -> NSBitmapImageRep? {
        guard let window else { return nil }
        let width: CGFloat = 208, bar: CGFloat = 52
        let navigation = MainNavigation()
        navigation.selection = pane
        let sidebarSize = NSSize(width: width, height: size.height - bar)
        let host = makeWindow(MainSidebar(navigation: navigation).environment(model), size: sidebarSize, dark: dark, titled: false, active: true)
        guard let sidebar = await capture(host, size: sidebarSize, titled: false),
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: window.pixelsWide, pixelsHigh: window.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: out) else { return window }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        window.draw(in: NSRect(origin: .zero, size: size))
        (dark ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: width, height: size.height).fill()
        sidebar.draw(in: NSRect(x: 0, y: 0, width: width, height: size.height - bar))
        for (index, color) in [NSColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1), NSColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                               NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 19 + CGFloat(index) * 20, y: size.height - 32, width: 12, height: 12)).fill()
        }
        if let symbol = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) {
            let tint = dark ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0, alpha: 0.45)
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                tint.setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(at: NSPoint(x: width - 30, y: size.height - 36), from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    /// History with the import that is being transcribed or the finished one selected.
    static func importWindow(_ model: AppModel, store: CallStore, selecting id: String, dark: Bool) async throws -> NSBitmapImageRep? {
        let calls = CallsModel()
        calls.setImportProgressForSnapshots(["interview": 0.42])
        return try await historyWindow(model, HistoryModel(store: store), calls: calls, selecting: id, dark: dark)
    }

    /// Stands in for the desktop behind a pill, which floats over other apps.
    struct Backdrop<Content: View>: View {
        let dark: Bool
        @ViewBuilder let content: Content

        var body: some View {
            ZStack {
                LinearGradient(colors: dark ? [Color(red: 0.12, green: 0.15, blue: 0.27), Color(red: 0.24, green: 0.13, blue: 0.27)]
                                            : [Color(red: 0.70, green: 0.80, blue: 0.96), Color(red: 0.93, green: 0.80, blue: 0.94)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                content
            }
        }
    }

    // MARK: Drawing

    /// A window the screen does not shrink, so a tall page such as About is drawn whole.
    private final class UnclampedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    static func makeWindow<V: View>(_ view: V, size: NSSize, dark: Bool, titled: Bool, active: Bool = false) -> NSWindow {
        // A window that is never key draws its controls grey. The environment value fixes the
        // text of a list, but not AppKit switches, and it makes a History row hover.
        let view = view.environment(\.controlActiveState, active ? .key : .inactive)
        let window = UnclampedWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if titled {
            window.title = AppName.name
            let controller = NSHostingController(rootView: view)
            controller.sceneBridgingOptions = [.title, .toolbars]
            window.contentViewController = controller
        } else {
            window.contentView = NSHostingView(rootView: view)
        }
        window.setContentSize(size)
        // Far from the pointer, so no row draws hovered.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        // Ordered in but fully transparent: AppKit lists and sidebars only fill in once their
        // window is on screen, and nothing is visible to anyone.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        return window
    }

    /// Lets SwiftUI settle, then draws the window's frame view at twice the point size.
    static func capture(_ window: NSWindow, size: NSSize, titled: Bool) async -> NSBitmapImageRep? {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(400))
        }
        guard let view = titled ? window.contentView?.superview : window.contentView else { return nil }
        let bounds = view.bounds
        let scale = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width) * scale,
                                         pixelsHigh: Int(bounds.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        defer { window.orderOut(nil) }
        view.displayIfNeeded()
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// A region of a drawn window, in points from its top left, as its own 2x bitmap.
    static func crop(_ rep: NSBitmapImageRep?, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) -> NSBitmapImageRep? {
        guard let rep,
              let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: out) else { return nil }
        out.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        rep.draw(in: NSRect(x: -x, y: -(rep.size.height - top - height), width: rep.size.width, height: rep.size.height))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    static func write(_ folder: URL, _ name: String, _ rep: NSBitmapImageRep?) async {
        guard let data = rep?.representation(using: .png, properties: [:]) else { DevLog.write("app-shots: nothing drawn for \(name)"); return }
        try? data.write(to: folder.appending(path: "\(name).png"))
    }

    /// An activation this process signed itself, so the window draws as an activated install.
    private static func activated() -> Activation {
        let key = Curve25519.Signing.PrivateKey()
        func encode(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let payload = encode(Data(#"{"kid":"shots","sid":"s0","n":"n0","iat":1794000000}"#.utf8))
        let signature = (try? key.signature(for: Data("dct1.\(payload)".utf8))).map(encode) ?? ""
        let record = ActivationRecord(token: "dct1.\(payload).\(signature)")
        return Activation(store: MemoryActivationStore(record), keys: ["shots": key.publicKey])
    }
}

/// The recordings the History shots show. Alex and Northwind are made up.
enum Seed {
    static func make(in folder: URL) throws -> (calls: CallStore, dictations: Store) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = folder.appending(path: "history.sqlite")
        let dictations = try Store(url: database)
        let calls = try CallStore(url: database)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func at(daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: .minute, value: hour * 60 + minute, to: calendar.date(byAdding: .day, value: -daysAgo, to: today)!)!
        }

        let rolloutAudio = folder.appending(path: "rollout.wav")
        let rolloutSeconds = 155
        let rolloutStart = at(daysAgo: 1, 16, 30)
        let rolloutLines: [(CallSegment.Channel, String)] = [
            (.me, "Thanks for joining, Alex. I wanted to walk through the North wind rollout plan before Friday."),
            (.call, "Sounds good. Before we start, did the pilot numbers come through from the team?"),
            (.me, "They did. Retention is up twelve percent, and support tickets are down by a third."),
            (.call, "That is better than we expected. What is still open on the rollout?"),
            (.me, "Two things. We need sign off on the new pricing page."),
            (.me, "And the onboarding emails still need a final read before they go out."),
            (.call, "I can review the emails tonight. Send them over and I will reply by tomorrow morning."),
            (.me, "Perfect. I will also share the pilot summary so everyone has the same numbers."),
        ]
        try tone(rolloutAudio, seconds: rolloutSeconds, speech: rolloutLines.indices.map { (Double($0) * 19 + 1, 16) })
        let rollout = try calls.createCall(NewCall(id: "rollout", startedAt: rolloutStart, appBundleID: "com.example.meeting", appName: "Meeting",
                                                split: true, audioPath: rolloutAudio.path))
        let segments = try calls.appendSegments("rollout", rolloutLines.enumerated().map { index, line in
            NewCallSegment(channel: line.0, startMs: index * 19_000 + 1_000, endMs: index * 19_000 + 17_000, text: line.1,
                           avgLogprob: -0.2, noSpeechProb: 0.01, compressionRatio: 1.2)
        })
        try calls.correctSegment("rollout", segments[0].id,
                                 text: "Thanks for joining, Alex. I wanted to walk through the Northwind rollout plan before Friday.",
                                 client: Edit.personClient)
        try calls.finishCall("rollout", endedAt: rolloutStart.addingTimeInterval(Double(rolloutSeconds)))
        _ = rollout
        _ = try calls.setAutoTitle("rollout", "Northwind rollout with Alex")

        func finished(_ id: String, _ app: String, _ bundle: String, _ start: Date, minutes: Int, _ title: String?,
                      _ lines: [(CallSegment.Channel, String)]) throws {
            _ = try calls.createCall(NewCall(id: id, startedAt: start, appBundleID: bundle, appName: app, split: true))
            _ = try calls.appendSegments(id, lines.enumerated().map { index, line in
                NewCallSegment(channel: line.0, startMs: index * 20_000, endMs: index * 20_000 + 15_000, text: line.1,
                               avgLogprob: -0.2, noSpeechProb: 0.01, compressionRatio: 1.2)
            })
            try calls.finishCall(id, endedAt: start.addingTimeInterval(Double(minutes * 60)))
            if let title { try calls.rename(.call, id, to: title) }
        }
        try finished("weekly", "Meeting", "com.example.meeting", at(daysAgo: 1, 9, 30), minutes: 32, "Northwind weekly sync", [
            (.call, "Let's start with the numbers from last week."),
            (.me, "Signups are steady, and the new onboarding flow is working."),
        ])
        try finished("long", "Meeting", "com.example.meeting", at(daysAgo: 1, 13, 0), minutes: 47, nil, [
            (.call, "Let's go through the quarterly plan for Lakeside, starting with the budget."),
            (.me, "Ryan and the finance team have the numbers, so I will share my screen now."),
            (.call, "Great, and then we can talk about hiring for the next two quarters."),
        ])
        _ = try calls.setAutoTitle("long", "Lakeside budget review")
        try finished("short", "Meeting", "com.example.meeting", at(daysAgo: 1, 8, 10), minutes: 4, nil, [
            (.me, "Can you hear me now? I switched to the other headset."),
            (.call, "Yes, loud and clear."),
        ])

        // Two imports from today. The finished one is the day's first, the other was dropped a
        // moment ago and is still being read, so it tops History.
        func imported(_ id: String, _ name: String, _ start: Date, seconds: Int, status: Call.Status,
                      _ lines: [String]) throws {
            let audio = folder.appending(path: "\(id).wav")
            try tone(audio, seconds: seconds, speech: (0..<(seconds / 20)).map { (Double($0) * 20 + 2, 7 + Double(($0 * 7) % 9)) })
            _ = try calls.createCall(NewCall(id: id, startedAt: start, split: false, audioPath: audio.path, fileName: name,
                                             endedAt: start.addingTimeInterval(Double(seconds)), status: status))
            _ = try calls.appendSegments(id, lines.enumerated().map { index, text in
                NewCallSegment(channel: .mix, startMs: index * 20_000 + 2_000, endMs: index * 20_000 + 16_000, text: text,
                               avgLogprob: -0.2, noSpeechProb: 0.01, compressionRatio: 1.2)
            })
        }
        let now = Date()
        let dayStart = calendar.startOfDay(for: now)
        try imported("memo", "New Recording 14.m4a", max(dayStart.addingTimeInterval(60), now.addingTimeInterval(-40 * 60)),
                     seconds: 252, status: .done, [
            "Notes from the Lakeside site visit, Tuesday morning.",
            "The east wing is ready for the electricians, but the loading dock still needs a new door.",
            "Alex wants a quote from two suppliers before we commit, so I will ask Northwind for the second one.",
            "Parking is tight on weekdays. We should schedule deliveries before eight.",
            "Next visit is in two weeks, once the flooring samples have arrived.",
        ])
        _ = try calls.setAutoTitle("memo", "Lakeside site visit notes")
        try imported("interview", "Interview with Alex.mp3", max(dayStart.addingTimeInterval(120), now.addingTimeInterval(-90)),
                     seconds: 24 * 60, status: .transcribing, [
            "Thanks for making the time, Alex. Could you start by telling me how the pilot began?",
            "Sure. It started small, with two teams at Northwind testing the new onboarding flow.",
            "What changed after the first month?",
            "Support tickets dropped, and people stopped asking where to find things.",
        ])

        func dictation(_ id: String, _ when: Date, seconds: Double, _ text: String) throws {
            let json: [String: Any] = [
                "id": id, "createdAt": when.timeIntervalSinceReferenceDate, "audioPath": folder.appending(path: "\(id).wav").path,
                "duration": seconds, "mode": "plain", "whisperModel": "large-v3-turbo", "rawText": text, "finalText": text,
                "timings": [String: Int](),
                "segments": [["t0": 0.0, "t1": seconds, "text": text, "avgLogprob": -0.2, "noSpeechProb": 0.01,
                              "compressionRatio": 1.2, "speechSeconds": seconds, "wordsPerSecond": 2.5]],
            ]
            let data = try JSONSerialization.data(withJSONObject: json)
            try dictations.insert(try JSONDecoder().decode(Dictation.self, from: data))
        }
        try dictation("d1", at(daysAgo: 1, 11, 42), seconds: 9, "Send Alex the Northwind proposal before Friday.")
        try dictation("d2", at(daysAgo: 2, 17, 5), seconds: 7, "Remind me to book the venue for the team offsite.")
        try dictation("d3", at(daysAgo: 3, 10, 18), seconds: 12, "Draft a short reply to the Northwind invoice question and keep it friendly.")
        return (calls, dictations)
    }

    /// A mono 16-bit file with bursts of tone where someone speaks, so the waveform has a shape.
    private static func tone(_ url: URL, seconds: Int, speech: [(Double, Double)]) throws {
        let rate = 8_000
        var samples = [Int16](repeating: 0, count: seconds * rate)
        var seed: UInt32 = 7
        for (start, length) in speech {
            let first = Int(start * Double(rate)), count = Int(length * Double(rate))
            for index in 0..<count where first + index < samples.count {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let envelope = 0.45 + 0.55 * abs(sin(Double(index) / Double(rate) * 3.1))
                let noise = Double(Int32(bitPattern: seed) >> 16) / 32_768
                samples[first + index] = Int16(noise * envelope * 12_000)
            }
        }
        var data = Data()
        func le32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); le32(16); le16(1); le16(1); le32(UInt32(rate)); le32(UInt32(rate * 2)); le16(2); le16(16)
        data.append(contentsOf: Array("data".utf8)); le32(UInt32(samples.count * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }
}
#endif
