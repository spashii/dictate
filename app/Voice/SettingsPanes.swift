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
                Text("Press once to start, again to stop. Nothing else stops a recording.")
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
                Picker("Default microphone for dictation", selection: $preferences.microphoneUID) {
                    Text("System default").tag("")
                    ForEach(microphones) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if !preferences.microphoneUID.isEmpty,
                       !microphones.contains(where: { $0.uid == preferences.microphoneUID }) {
                        Text("Not connected").tag(preferences.microphoneUID)
                    }
                }
                Picker("Default microphone for calls", selection: $calls.microphoneUID) {
                    Text("System default").tag("")
                    ForEach(microphones) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if !calls.microphoneUID.isEmpty, !microphones.contains(where: { $0.uid == calls.microphoneUID }) {
                        Text("Not connected").tag(calls.microphoneUID)
                    }
                }
            }
            Section {
                CallAudioPermissionRow()
                CallAudioPicker()
                if let warning = calls.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }
            } header: {
                Text("Call audio")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Headphones recommended for calls on speakers, where your microphone also hears the call.")
                    BlendMicNote(installed: blendInstalled, mixes: !calls.mixes.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .task { await calls.refreshSources() }
        .onAppear { model.refreshDevices() }
    }

    private var blendInstalled: Bool {
        !calls.mixes.isEmpty
            || BlendMic.isInstalled(inputNames: model.devices.map(\.name),
                                    appURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: BlendMic.bundleID))
    }
}

/// Blend Mic is optional: its mixes are one more place to hear a call from.
struct BlendMicNote: View {
    let installed: Bool
    let mixes: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(mixes ? "Already using Blend Mic? Pick its mix above."
                 : installed ? "Already using Blend Mic? Its mixes appear above while Blend is running."
                 : "Already using Blend Mic? Its mixes appear above.")
            Link("About Blend Mic", destination: BlendMic.website)
        }
    }
}

/// Shown only while Dictate can't yet record other apps' sound.
struct CallAudioPermissionRow: View {
    @Environment(CallsModel.self) private var calls

    var body: some View {
        if calls.capturePermission != .authorized {
            LabeledContent {
                Button(calls.capturePermission == .denied ? "Open System Settings" : "Allow\u{2026}") {
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
            Section("Speech model") {
                Picker("Model", selection: Binding(get: { preferences.whisperModel },
                                                   set: { model.chooseWhisperModel($0) })) {
                    ForEach(WhisperModel.allCases) { whisperModel in
                        Text(whisperModel == .largeV3Turbo ? "\(whisperModel.title) (recommended)" : whisperModel.title)
                            .tag(whisperModel)
                    }
                }
                SpeechModelStatus(whisperModel: preferences.whisperModel)
                TextField(text: $preferences.keyTerms, axis: .vertical) {
                    Text("Key terms")
                    Text("Names, product names and jargon whisper gets wrong, as they should be spelled.")
                }
                SuggestedTermsView()
            }
            Section("Retries") {
                Toggle(isOn: $preferences.retrySegments) {
                    Text("Retry unsure segments")
                    Text("Words whisper was unsure of are transcribed again, more carefully. This can add a moment before the paste.")
                }
                RetryStatsView()
            }
            Section("Fix the text") {
                Toggle(isOn: $preferences.runPrompt) {
                    Text("Fix the text before pasting")
                    Text("A model on this Mac reads the text with your key terms and can change a few misheard words. This adds a moment before the paste.")
                }
                OllamaModelRow()
            }
        }
        .formStyle(.grouped)
        .onAppear { Task { await model.refreshOllama() } }
        .onChange(of: preferences.whisperModel) { _, whisperModel in
            model.downloads.download(whisperModel)
        }
    }
}

/// The models Ollama has, or why there are none to pick.
struct OllamaModelRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        if let models = model.ollamaModels {
            Picker("Model", selection: $preferences.ollamaModel) {
                ForEach(models, id: \.self) { name in
                    Text(name).tag(name)
                }
                if !AppModel.contains(models, preferences.ollamaModel) {
                    Text("\(preferences.ollamaModel) (not installed)").tag(preferences.ollamaModel)
                }
            }
        } else {
            LabeledContent("Model") {
                Text("Ollama is not running").foregroundStyle(.secondary)
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
            LabeledContent("Status") { Text("Ready") }
        case .downloading(let fraction):
            LabeledContent("Downloading \(size)") {
                ProgressView(value: fraction).frame(width: 160)
            }
        case .missing:
            LabeledContent("Status") {
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
                connect(agents)
                tools(agents)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hostText = agents.host
            portText = String(agents.port)
        }
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

    private func connect(_ agents: AgentAccess) -> some View {
        let setup = agents.displayedSetup
        return Section("Connect") {
            LabeledContent {
                Button {
                    agents.copySetup()
                } label: {
                    Label("Copy MCP setup", systemImage: "doc.on.doc")
                }
            } label: {
                Text("Connect an agent app")
                Text("Copies this config, with your token, ready to paste into an agent app.")
            }
            HStack(alignment: .top, spacing: 12) {
                snippet("JSON", setup.json)
                snippet("Or, in Claude Code", setup.command)
            }
            .padding(.vertical, 4)
        }
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func tools(_ agents: AgentAccess) -> some View {
        Section {
            Text("Tools that record or change anything start off, because what the other side of a call says is read by your agent.")
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

// MARK: About

struct AboutPane: View {
    @Environment(AppModel.self) private var model
    @State private var showingNotices = false

    var body: some View {
        @Bindable var updates = model.updates
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 4) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text(AppName.name).font(.title.weight(.semibold)).padding(.top, 8)
                Text("Version \(Self.version)").foregroundStyle(.secondary)
                Button("Check for Updates\u{2026}") { model.updates.check() }
                    .disabled(!model.updates.canCheck)
                    .padding(.top, 10)
                Toggle("Check for updates automatically", isOn: $updates.automatic)
                    .toggleStyle(.checkbox)
                    .padding(.top, 4)
                VStack(spacing: 6) {
                    Link(destination: URL(string: "https://github.com/spashii")!) {
                        Label("github.com/spashii", systemImage: "arrow.up.right.square")
                    }
                    Link(destination: SupportItem.repository) {
                        Label("github.com/spashii/dictate", systemImage: "arrow.up.right.square")
                    }
                }
                .padding(.top, 20)
            }
            Spacer()
            HStack(spacing: 4) {
                Text("Source available under the Functional Source License (FSL-1.1-MIT), \u{00A9} 2026 The Dictate authors. Each version becomes MIT two years after its release.")
                    .foregroundStyle(.secondary)
                Button("Third-party notices") { showingNotices = true }
                    .buttonStyle(.link)
            }
            .font(.caption)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
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
