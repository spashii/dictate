import KeyboardShortcuts
import SwiftUI
import VoiceCore

/// General: what gets the first dictation working until it is done, then the things that
/// are about the app and the Mac rather than the speech: the shortcut, the microphone,
/// login, history, agent access, and About.
struct GeneralPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            if !model.setupComplete {
                Section {
                    MicrophoneStep()
                    AccessibilityStep()
                    SpeechModelStep(whisperModel: preferences.whisperModel)
                } header: {
                    Text("Setup")
                } footer: {
                    Text("Press \(KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "the shortcut") in any text field, speak, press it again.")
                }
            }

            Section("Dictate") {
                KeyboardShortcuts.Recorder("Shortcut:", name: .dictate)
                Help("Press once to start, again to stop. Nothing else stops a recording.")
                Picker("Microphone", selection: $preferences.microphoneUID) {
                    Text("System default").tag("")
                    ForEach(model.devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if !preferences.microphoneUID.isEmpty,
                       !model.devices.contains(where: { $0.uid == preferences.microphoneUID }) {
                        Text("Not connected").tag(preferences.microphoneUID)
                    }
                }
            }

            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                Picker("Keep history", selection: $preferences.history) {
                    Text(Preferences.History.thirtyDays.title).tag(Preferences.History.thirtyDays)
                    Text(Preferences.History.forever.title).tag(Preferences.History.forever)
                }
                Help("Each dictation's and call's audio and text. Click one in the menu to copy it.")
                AgentAccessRow()
            }

            AboutSection()
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshDevices()
            model.refreshPermissions()
        }
        // macOS says nothing when Accessibility is granted, so the steps look every second
        // while they show.
        .task(id: model.setupComplete) {
            while !Task.isCancelled && !model.setupComplete {
                try? await Task.sleep(for: .seconds(1))
                model.refreshPermissions()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
        .onChange(of: preferences.history) {
            model.pruneHistory()
        }
    }
}

/// The speech: which model hears you, in which language, with which names, how unsure words
/// are retried, and the step that fixes the text afterwards.
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
                Picker("Language", selection: $preferences.language) {
                    Text("Detect").tag("auto")
                    Divider()
                    ForEach(WhisperLanguages.all, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                TextField("Key terms", text: $preferences.keyTerms, axis: .vertical)
                Help("Names and words whisper gets wrong, as they should be spelled.")
                SuggestedTermsView()
            }

            Section("Retries") {
                Toggle("Retry unsure segments", isOn: $preferences.retrySegments)
                Help("Words whisper was unsure of are transcribed again, more carefully. This can add a moment before the paste.")
                RetryStatsView()
            }

            Section("Fix the text") {
                Toggle("Fix the text before pasting", isOn: $preferences.runPrompt)
                Help("A model on this Mac reads the text with your key terms and can change a few misheard words. This adds a moment before the paste.")
                OllamaModelRow()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            Task { await model.refreshOllama() }
        }
        .onChange(of: preferences.whisperModel) { _, whisperModel in
            model.downloads.download(whisperModel)
        }
    }
}

/// Recording calls: the shortcut, what to record from, and whether to ask.
struct CallsPane: View {
    var body: some View {
        Form {
            CallsSettingsSection()
        }
        .formStyle(.grouped)
    }
}

/// The version, updates and licenses.
private struct AboutSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var updates = model.updates
        Section("About") {
            LabeledContent("Version") {
                HStack {
                    Text(Self.version)
                    Button("Check for Updates…") { model.updates.check() }
                        .disabled(!model.updates.canCheck)
                }
            }
            Toggle("Check for updates automatically", isOn: $updates.automatic)
            Help("\(AppName.name) works on this Mac, and your audio stays on it. It goes online only to download the speech model and to check for updates. The fix step uses Ollama on this Mac, and the MCP server leaves it only if you put it on your tailnet.")
            LabeledContent("License") {
                Text("MIT, and the libraries it includes")
            }
            LicensesView()
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
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

struct Help: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
