#if DEBUG
import AppKit
import SwiftUI
import VoiceCore

/// Draws each pane of the main window, in light and dark, and the live pills with the
/// pointer over them and away, from made-up data, into the folder named by VOICE_DEMO_OUT.
/// It needs a build with the bundle identifier io.github.spashii.voice.demo and
/// VOICE_DEMO_SUPPORT pointing at an empty voice-demo-home folder, and refuses to run otherwise.
@MainActor
enum DemoRender {
    private static var out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOICE_DEMO_OUT"] ?? "/dev/null")

    static func start(model: AppModel, calls: CallsModel) {
        // Preferences live in the bundle's defaults domain, so only a build with its own
        // identifier may write them; the installed app's would be changed otherwise.
        guard Paths.support.path.contains("voice-demo-home"), Bundle.main.bundleIdentifier?.hasSuffix(".demo") == true else {
            FileHandle.standardError.write(Data("Refusing to render outside a demo build and a voice-demo-home folder.\n".utf8))
            exit(2)
        }
        Task {
            do {
                try seed()
            } catch {
                FileHandle.standardError.write(Data("Couldn't seed the demo data: \(error)\n".utf8))
                exit(1)
            }
            await render(model: model, calls: calls)
            exit(0)
        }
    }

    private static func render(model: AppModel, calls: CallsModel) async {
        let preferences = model.preferences
        preferences.keyTerms = "Northwind, Acme, Sparkle"
        preferences.runPrompt = true
        preferences.ollamaModel = "llama3.2:3b"
        model.ollamaModels = ["llama3.2:3b", "qwen3:8b"]
        let window = MainWindow()
        let models = [Paths.whisperModel, Paths.vadModel]

        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            // Setup unfinished: nothing allowed, no model on disk.
            for url in models { try? FileManager.default.removeItem(at: url) }
            model.microphoneAllowed = false
            model.accessibilityAllowed = false
            await shoot(window, .general, "general-setup-\(name)", model: model, calls: calls)

            for url in models { FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)) }
            model.microphoneAllowed = true
            model.accessibilityAllowed = true
            model.downloads.download(preferences.whisperModel)
            await shoot(window, .general, "general-\(name)", model: model, calls: calls)
            await shoot(window, .general, "general-about-\(name)", model: model, calls: calls, scrollToEnd: true)
            await shoot(window, .history, "history-\(name)", model: model, calls: calls)
            await shoot(window, .model, "model-\(name)", model: model, calls: calls)
            await shoot(window, .calls, "calls-\(name)", model: model, calls: calls)
            await pills(model: model, name: name)
        }
    }

    private static func shoot(_ main: MainWindow, _ pane: MainPane, _ name: String, model: AppModel,
                              calls: CallsModel, scrollToEnd: Bool = false) async {
        main.show(pane, model: model, calls: calls)
        guard let window = main.nsWindow else { return }
        window.animationBehavior = .none
        window.setContentSize(NSSize(width: 880, height: 760))
        window.center()
        window.appearance = NSApp.appearance
        try? await Task.sleep(for: .seconds(1.5))
        if scrollToEnd, let scroll = window.contentView.flatMap(Self.scrollViews)?.max(by: { $0.frame.height < $1.frame.height }) {
            let view = scroll.documentView
            view?.scroll(NSPoint(x: 0, y: (view?.bounds.height ?? 0) - scroll.contentView.bounds.height))
            try? await Task.sleep(for: .seconds(0.6))
        }
        capture(window, as: name)
    }

    private static func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] + view.subviews.flatMap(scrollViews) } ?? view.subviews.flatMap(scrollViews)
    }

    private static func pills(model: AppModel, name: String) async {
        for hovered in [false, true] {
            let state = PillHoverState()
            model.phase = .recording(.fix, Date().addingTimeInterval(-14))
            model.liveText = "so the plan for the pilot is to start with the Northwind workshop"
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 210), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.appearance = NSApp.appearance
            window.contentView = NSHostingView(rootView: DemoPills(state: state).environment(model))
            window.center()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(0.8))
            if hovered {
                state.force([.dictation, .call])
                try? await Task.sleep(for: .seconds(0.6))
            }
            capture(window, as: "pills-\(hovered ? "hover" : "idle")-\(name)")
            window.close()
        }
        model.phase = .idle
        model.liveText = ""
    }

    private static func capture(_ window: NSWindow, as name: String) {
        let file = out.appending(path: name + ".png")
        // The compositor's picture of the window, which only an app's own windows can be
        // read without screen recording permission. The symbol is looked up by name since
        // the SDK no longer declares it.
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            FileHandle.standardError.write(Data("CGWindowListCreateImage is gone.\n".utf8))
            return
        }
        let create = unsafeBitCast(symbol, to: Create.self)
        // Only this window, without its shadow, at the display's full resolution.
        guard let image = create(.null, 8, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else {
            FileHandle.standardError.write(Data("No image for \(name).\n".utf8))
            return
        }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)
    }

    /// Made-up history in the throwaway database: three dictations and a call.
    private static func seed() throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        let store = try Store(url: Paths.database)
        let now = Date()
        func dictation(_ id: String, _ ago: Double, _ text: String, final: String? = nil, edits: String = "") throws {
            let json = """
            {"id":"\(id)","createdAt":\(now.addingTimeInterval(-ago).timeIntervalSinceReferenceDate),
             "audioPath":"/nonexistent/\(id).wav","duration":6,"mode":"fix","whisperModel":"large-v3-turbo",
             "rawText":"\(text)","finalText":"\(final ?? text)","timings":{},
             "segments":[{"t0":0,"t1":6,"text":"\(text)","avgLogprob":-0.2,"noSpeechProb":0,"compressionRatio":1,
             "speechSeconds":6,"wordsPerSecond":2.5}]\(edits)}
            """
            try store.insert(try JSONDecoder().decode(Dictation.self, from: Data(json.utf8)))
        }
        try dictation("d1", 300, "Send the agenda for the Northwynd workshop to Alex before Friday.",
                      final: "Send the agenda for the Northwind workshop to Alex before Friday.",
                      edits: ",\"fixEdits\":[{\"segment\":0,\"span\":\"Northwynd\",\"replacement\":\"Northwind\",\"keyTerm\":\"Northwind\",\"offset\":24}]")
        try dictation("d2", 3600 * 3, "Remind me to book the venue and confirm the catering numbers.")
        try dictation("d3", 3600 * 26, "The quarterly report needs the retention chart on the second page.")
        let calls = try CallStore(url: Paths.database)
        try calls.createCall(NewCall(id: "c1", startedAt: now.addingTimeInterval(-3600 * 5), appName: "Zoom", split: true,
                                     title: "Pilot kickoff"))
        _ = try calls.appendSegments("c1", [
            NewCallSegment(channel: .me, startMs: 0, endMs: 3000, text: "Thanks for joining, let's start with the timeline."),
            NewCallSegment(channel: .call, startMs: 3200, endMs: 6500, text: "Sure. We can have a first version by the end of the month."),
            NewCallSegment(channel: .me, startMs: 6800, endMs: 9000, text: "That works for us."),
        ])
        try calls.finishCall("c1", endedAt: now.addingTimeInterval(-3600 * 5 + 600))
    }
}

/// Two live pills over a made-up document, as they sit over the text under them.
private struct DemoPills: View {
    let state: PillHoverState
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<9, id: \.self) { _ in
                    Text("Notes from the planning call: the pilot starts in March and the first review is two weeks later.")
                        .lineLimit(1)
                        .fontWeight(.regular)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))
            VStack(spacing: 6) {
                IndicatorView()
                    .frame(height: 70)
                CallPill(startedAt: Date().addingTimeInterval(-95), stopHint: "⌥⇧` stops",
                         lines: [.init(id: 1, channel: .call, label: "Call", text: "we can have a first version by the end of the month"),
                                 .init(id: 2, channel: .me, label: "Me", text: "that works for us")])
                    .fadesUnderPointer(.call, in: state)
            }
            .padding(.top, 8)
        }
        .environment(state)
        .coordinateSpace(name: IndicatorView.space)
        .font(.system(size: 12, weight: .medium))
        .frame(width: 520, height: 210)
    }
}
#endif
