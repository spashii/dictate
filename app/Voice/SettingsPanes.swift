import KeyboardShortcuts
import SwiftUI
import VoiceCore

/// What gets the first dictation working, until it is done, then how long to keep things.
struct SetupPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                ActivationStep()
                MicrophoneStep()
                AccessibilityStep()
                CallAudioStep()
                SpeechModelStep(whisperModel: preferences.whisperModel)
            } footer: {
                Text("Press \(KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "the shortcut") in any text field, speak, press it again.")
            }
            Section {
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                Picker(selection: $preferences.history) {
                    Text(Preferences.History.thirtyDays.title).tag(Preferences.History.thirtyDays)
                    Text(Preferences.History.forever.title).tag(Preferences.History.forever)
                } label: {
                    Text("Keep history")
                    Text("Each dictation\u{2019}s and call\u{2019}s audio and text.")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: preferences.history) { model.pruneHistory() }
    }
}

struct ShortcutsPane: View {
    @Environment(CallsModel.self) private var calls

    var body: some View {
        @Bindable var calls = calls
        Form {
            Section("Dictate") {
                KeyboardShortcuts.Recorder("Shortcut", name: .dictate)
                Text("Press once to start, again to stop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Record call") {
                KeyboardShortcuts.Recorder("Shortcut", name: .recordCall)
                Toggle("Ask automatically to record calls", isOn: $calls.askToRecord)
            }
        }
        .formStyle(.grouped)
    }
}

struct MicrophonesPane: View {
    @Environment(AppModel.self) private var model
    @Environment(CallsModel.self) private var calls

    var body: some View {
        @Bindable var preferences = model.preferences
        @Bindable var calls = calls
        // A Blend mix is picked under Call audio, not as a microphone.
        let microphones = model.devices.filter { device in !calls.mixes.contains { $0.deviceUID == device.uid } }
        Form {
            Section {
                Picker("Microphone for dictation", selection: $preferences.microphoneUID) {
                    Text("System default").tag("")
                    ForEach(microphones) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if !preferences.microphoneUID.isEmpty,
                       !microphones.contains(where: { $0.uid == preferences.microphoneUID }) {
                        Text("Not connected").tag(preferences.microphoneUID)
                    }
                }
                Picker("Microphone for calls", selection: $calls.microphoneUID) {
                    Text("System default").tag("")
                    ForEach(microphones) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if !calls.microphoneUID.isEmpty, !microphones.contains(where: { $0.uid == calls.microphoneUID }) {
                        Text("Not connected").tag(calls.microphoneUID)
                    }
                }
                Toggle("Cancel echo from the call", isOn: $calls.cancelEcho)
            } footer: {
                Text("On speakers, Dictate takes the call out of what your microphone hears.")
            }
            Section {
                BlendMicNote()
                    .font(.callout)
                    .foregroundStyle(.secondary)
                CallAudioPermissionRow()
                CallAudioPicker()
                if let warning = calls.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }
            } header: {
                Text("Call audio")
            }
        }
        .formStyle(.grouped)
        .task { await calls.refreshSources() }
        .onAppear { model.refreshDevices() }
    }
}

/// Why a call's audio has a choice at all: Dictate records it itself, and a Blend Mic mix is
/// the alternative for people who already use Blend Mic.
struct BlendMicNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("Dictate records a call\u{2019}s audio itself. If you use Blend Mic, you can record its mix instead.")
        LabeledContent("Blend Mic") {
            if BlendMic.isInstalled(inputNames: model.devices.map(\.name)) {
                Text("Installed")
            } else {
                Link("Get Blend Mic", destination: BlendMic.website)
            }
        }
    }
}

/// Shown only while Dictate can't yet record other apps' sound.
struct CallAudioPermissionRow: View {
    @Environment(CallsModel.self) private var calls

    var body: some View {
        if calls.capturePermission != .authorized {
            LabeledContent {
                Button(calls.capturePermission == .denied ? "Open System Settings\u{2026}" : "Allow\u{2026}") {
                    calls.askForCaptureAccess()
                }
            } label: {
                Label("Dictate can\u{2019}t record call audio yet", systemImage: "exclamationmark.circle")
                Text(calls.capturePermission == .denied
                     ? "Turn on Dictate under System Audio Recording."
                     : "macOS asks once.")
            }
        }
    }
}

/// The speech: which model hears you, with which names, how unsure words are retried, and the
/// step that fixes the text afterwards. The language is always detected.
struct ModelPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                Picker("Speech model", selection: Binding(get: { preferences.whisperModel },
                                                   set: { model.chooseWhisperModel($0) })) {
                    ForEach(WhisperModel.allCases) { whisperModel in
                        Text(whisperModel == .largeV3Turbo ? "\(whisperModel.title) (recommended)" : whisperModel.title)
                            .tag(whisperModel)
                    }
                }
                SpeechModelStatus(whisperModel: preferences.whisperModel)
                TextField(text: $preferences.keyTerms, axis: .vertical) {
                    Text("Key terms")
                    Text("Names, product names and jargon Whisper gets wrong, as they should be spelled.")
                }
                SuggestedTermsView()
            }
            Section {
                Toggle(isOn: $preferences.retrySegments) {
                    Text("Retry unsure segments")
                    Text("Words Whisper was unsure of are transcribed again, more carefully. This can add a moment before the paste.")
                }
                RetryStatsView()
            }
            Section {
                Toggle(isOn: $preferences.runPrompt) {
                    Text("Fix the text before pasting")
                    Text("A model on this Mac reads the text with your key terms and can change a few misheard words. This adds a moment before the paste.")
                }
                Toggle(isOn: $preferences.titleCalls) {
                    Text("Title calls")
                    Text("A model on this Mac names each call from its transcript when it ends.")
                }
                LocalModelRow()
            }
        }
        .formStyle(.grouped)
        .onAppear { Task { await model.refreshOllama() } }
        .onChange(of: preferences.whisperModel) { _, whisperModel in
            model.downloads.download(whisperModel)
        }
    }
}

/// The model for the fix and for titles: Apple's when this Mac has it, then the models Ollama
/// has, or why there are none to pick.
struct LocalModelRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let preferences = model.preferences
        let current = model.effectiveModel
        let apple = model.appleModelAvailable
        let appleListed = apple || current == .apple
        if model.ollamaModels == nil && !appleListed {
            LabeledContent("Model") {
                Text("Ollama is not running").foregroundStyle(.secondary)
            }
        } else {
            let selection = Binding<String>(
                get: { LocalModelChoice.tag(model.effectiveModel) },
                set: { tag in
                    guard let choice = LocalModelChoice.model(tag: tag) else { return }
                    if case .ollama(let name) = choice { preferences.ollamaModel = name }
                    preferences.localModel = choice
                })
            Picker("Model", selection: selection) {
                if appleListed {
                    Text(apple ? "Apple Intelligence" : "Apple Intelligence (unavailable)").tag(LocalModelChoice.tag(.apple))
                }
                if let models = model.ollamaModels {
                    if appleListed { Divider() }
                    ForEach(models, id: \.self) { name in
                        Text(name).tag(LocalModelChoice.tag(.ollama(name)))
                    }
                    if !AppModel.contains(models, preferences.ollamaModel) {
                        Text("\(preferences.ollamaModel) (not installed)")
                            .tag(LocalModelChoice.tag(.ollama(preferences.ollamaModel)))
                    }
                } else if case .ollama(let name) = current {
                    Divider()
                    Text("\(name) (Ollama is not running)").tag(LocalModelChoice.tag(current))
                }
            }
        }
    }
}

struct SpeechModelStatus: View {
    @Environment(AppModel.self) private var model
    let whisperModel: WhisperModel

    var body: some View {
        let size = SpeechModelStep.size(whisperModel)
        switch model.downloads.state(whisperModel) {
        case .ready:
            EmptyView()
        case .downloading(let fraction):
            LabeledContent("Downloading \(size)") {
                ProgressView(value: fraction).frame(width: 160)
            }
        case .missing:
            LabeledContent("Not downloaded") {
                Button("Download \(size)") { model.downloads.download(whisperModel) }
            }
        case .failed(let error):
            LabeledContent(error) {
                Button("Try Again") { model.downloads.download(whisperModel) }
            }
        }
    }
}

// MARK: Agents

struct AgentsPane: View {
    @Environment(AppModel.self) private var model
    @State private var hostText = ""
    @State private var portText = ""
    @State private var addressError: String?
    @State private var confirmRegenerate = false
    @State private var showingSetup = false
    @FocusState private var focus: Field?

    private enum Field { case host, port }

    var body: some View {
        @Bindable var agents = model.agents
        Form {
            Section {
                Toggle(isOn: $agents.enabled) {
                    Text("Agents can read transcripts")
                    Text("Claude Code and other agents read your dictations and call transcripts over MCP, with the token.")
                }
            }
            if agents.enabled {
                server(agents)
                connect()
                tools(agents)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hostText = agents.host
            portText = String(agents.port)
        }
        .sheet(isPresented: $showingSetup) { ConnectSheet(agents: agents) }
        .confirmationDialog("Make a new token?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { agents.regenerateToken() }
        } message: {
            Text("Agents using the old token stop working until you give them the new one.")
        }
    }

    private func server(_ agents: AgentAccess) -> some View {
        Section {
            TextField("Host", text: $hostText)
                .multilineTextAlignment(.trailing)
                .focused($focus, equals: .host)
                .onSubmit(commitAddress)
            TextField("Port", text: $portText)
                .multilineTextAlignment(.trailing)
                .focused($focus, equals: .port)
                .onSubmit(commitAddress)
            LabeledContent("Token") {
                HStack {
                    Text(agents.maskedToken).monospaced().foregroundStyle(.secondary)
                    Button("Copy") { agents.copyToken() }
                    Button("Regenerate") { confirmRegenerate = true }
                }
            }
        } header: {
            Text("Server")
        } footer: {
            if let addressError {
                Text(addressError).foregroundStyle(.red)
            } else if case .failed(let message) = agents.status {
                Text(message).foregroundStyle(.red)
            } else if let warning = MCPEndpoint.exposureWarning(host: hostText) {
                Text(warning).foregroundStyle(.orange)
            }
        }
        .onChange(of: focus) { old, new in
            // Leaving a field applies what was typed, as Return does.
            if old != nil, new != old { commitAddress() }
        }
    }

    private func connect() -> some View {
        Section {
            LabeledContent {
                Button("Show") { showingSetup = true }
            } label: {
                Text("Connect an agent app")
                Text("The config for an agent app, with your token.")
            }
        }
    }

    private func tools(_ agents: AgentAccess) -> some View {
        Section {
            Text("Tools that record or change anything start off.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(MCPServer.toolCatalog) { tool in
                Toggle(isOn: Binding(get: { !agents.disabledTools.contains(tool.name) },
                                     set: { agents.setTool(tool.name, on: $0) })) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(tool.name).font(.system(size: 12, design: .monospaced)).frame(width: 190, alignment: .leading)
                        Text(tool.summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        } header: {
            HStack {
                Text("Tools")
                Spacer()
                Button("Turn all on") { agents.setAllTools(on: true) }
                Button("Turn all off") { agents.setAllTools(on: false) }
            }
        }
    }

    /// Moves the server when both fields are valid; otherwise says which isn't.
    private func commitAddress() {
        guard let host = MCPEndpoint.address(host: hostText) else {
            addressError = "The host is an IPv4 address such as 127.0.0.1, or localhost."
            return
        }
        guard let port = MCPEndpoint.port(portText) else {
            addressError = "The port is a number from 1024 to 65535."
            return
        }
        addressError = nil
        hostText = host
        portText = String(port)
        model.agents.setAddress(host: host, port: port)
    }
}

/// The config an agent app needs, with the real token. The token is read when the sheet opens
/// and dropped when it closes, and it is shown nowhere else.
private struct ConnectSheet: View {
    let agents: AgentAccess
    @Environment(\.dismiss) private var dismiss
    @State private var setup: MCPSetup?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect an agent app").font(.title3.weight(.semibold))
            if let setup {
                snippet("JSON config", setup.json)
                snippet("Claude Code", setup.command)
            } else {
                Text("The token could not be read.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { setup = agents.setupWithToken() }
        .onDisappear { setup = nil }
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { agents.copy(text) }
            }
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: About

struct AboutPane: View {
    @Environment(AppModel.self) private var model
    @State private var showingNotices = false

    var body: some View {
        @Bindable var updates = model.updates
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppName.name).font(.title2.weight(.semibold))
                        Text("Version \(Self.version)").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                LabeledContent("Updates") {
                    Button("Check for Updates\u{2026}") { model.updates.check() }
                        .disabled(!model.updates.canCheck)
                }
                Toggle("Check for updates automatically", isOn: $updates.automatic)
            }
            Section {
                Link(destination: URL(string: "https://spashii.github.io/dictate/")!) {
                    Label("spashii.github.io/dictate", systemImage: "arrow.up.right.square")
                }
            } footer: {
                HStack(spacing: 4) {
                    Text("Source available under the Functional Source License (FSL-1.1-MIT), \u{00A9} 2026 The Dictate authors. Each version becomes MIT two years after its release.")
                    Button("Third-party notices") { showingNotices = true }
                        .buttonStyle(.link)
                }
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingNotices) { NoticesSheet() }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}

/// THIRD_PARTY_NOTICES.md, bundled with the app, as the licenses of what it includes require.
private struct NoticesSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let blocks: [NoticesDocument.Block] = {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [.paragraph("The notices file is missing from this copy of Dictate.")]
        }
        return NoticesDocument.parse(text)
    }()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .heading(let level, let text):
                            Text(text).font(level <= 1 ? .title2.bold() : .headline).padding(.top, 6)
                        case .paragraph(let text):
                            Text(text)
                        case .code(let text):
                            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 520)
    }
}
