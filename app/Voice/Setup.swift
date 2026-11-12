import SwiftUI
import VoiceCore

struct ActivationStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        StepRow(title: "Activated", done: model.activation.isActivated, detail: graceText) {
            Button("Activate\u{2026}") { model.beginActivation() }
        }
    }

    private var graceText: String? {
        guard case .grace(let until) = model.activation.state else { return nil }
        return "Using Dictate until \(until.formatted(date: .abbreviated, time: .omitted))."
    }
}

struct MicrophoneStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        StepRow(title: "Microphone", done: model.microphoneAllowed) {
            Button("Allow…") { model.askForMicrophone() }
        }
    }
}

struct AccessibilityStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        StepRow(title: "Accessibility", done: model.accessibilityAllowed,
                detail: "Lets Dictate paste into other apps.") {
            Button("Allow…") { Paster.askForAccess() }
        }
    }
}

/// Lets Dictate record the sound of the app a call is in. Not required for dictation, so
/// setup isn't unfinished without it.
struct CallAudioStep: View {
    @Environment(CallsModel.self) private var calls

    var body: some View {
        StepRow(title: "Call audio", done: calls.capturePermission == .authorized,
                detail: "Lets Dictate record the sound of the app you are on a call in, so the other side is transcribed. Skip it to record only your microphone.") {
            Button(calls.capturePermission == .denied ? "Open System Settings\u{2026}" : "Allow\u{2026}") {
                calls.askForCaptureAccess()
            }
        }
    }
}

struct SpeechModelStep: View {
    @Environment(AppModel.self) private var model
    let whisperModel: WhisperModel

    var body: some View {
        switch model.downloads.state(whisperModel) {
        case .ready:
            StepRow(title: "Speech model", done: true)
        case .downloading(let fraction):
            StepRow(title: "Speech model", done: false, detail: "Downloading \(Self.size(whisperModel))") {
                ProgressView(value: fraction).frame(width: 120)
            }
        case .missing:
            StepRow(title: "Speech model", done: false) {
                Button("Download \(Self.size(whisperModel))") { model.downloads.download(whisperModel) }
            }
        case .failed(let error):
            StepRow(title: "Speech model", done: false, detail: error) {
                Button("Try Again") { model.downloads.download(whisperModel) }
            }
        }
    }

    static func size(_ model: WhisperModel) -> String {
        String(format: "%.1f GB", Double(model.bytes) / 1e9)
    }
}

/// One setup step: whether it is done, what it is for while it isn't, and the button that
/// does it. A finished step is just its name and a check mark.
struct StepRow<Action: View>: View {
    let title: String
    let done: Bool
    let detail: String?
    let action: Action

    init(title: String, done: Bool, detail: String? = nil, @ViewBuilder action: () -> Action) {
        self.title = title
        self.done = done
        self.detail = detail
        self.action = action()
    }

    var body: some View {
        HStack(alignment: detail == nil || done ? .center : .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? .green : .secondary)
                .font(.title3)
                .accessibilityLabel(done ? "Done" : "To do")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail, !done {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if !done { action }
        }
        .padding(.vertical, 2)
    }
}

extension StepRow where Action == EmptyView {
    init(title: String, done: Bool, detail: String? = nil) {
        self.init(title: title, done: done, detail: detail) { EmptyView() }
    }
}
