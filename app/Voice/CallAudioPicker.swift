import AppKit
import BlendKit
import Observation
import SwiftUI
import VoiceCore

/// Measures the chosen app's sound while the picker is open, so a person can see the app is
/// heard before a call. Only with the permission already given: looking at a list never
/// shows a permission question.
@MainActor @Observable
final class CallLevelModel {
    private(set) var level: Float = 0
    @ObservationIgnored private var target: CallTapTarget?
    @ObservationIgnored private var probes: LevelProbes?
    @ObservationIgnored private var reading: Task<Void, Never>?

    func watch(_ target: CallTapTarget?, permission: AudioCapturePermission) {
        guard permission == .authorized, let target else {
            stop()
            return
        }
        guard target != self.target else { return }
        stop()
        self.target = target
        let probes = LevelProbes(label: "Dictate")
        self.probes = probes
        reading = Task { [weak self] in
            // Off the main thread: making the tap asks coreaudiod.
            await Task.detached(priority: .utility) { probes.set([TapTarget(bundleID: target.bundleID)]) }.value
            while !Task.isCancelled {
                let peak = probes.levels().first ?? 0
                guard let self else { return }
                level = max(peak, level * 0.85)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        reading?.cancel()
        reading = nil
        let probes = probes
        self.probes = nil
        target = nil
        level = 0
        // An empty list ends the taps; the probes themselves go with their last reference.
        if let probes { Task.detached(priority: .utility) { probes.set([]) } }
    }
}

/// What a call records as the other side: the app Dictate finds, one app, or a Blend Mic mix.
/// A list of rows with the app's icon, its name, what it is doing with sound, and a level on
/// the chosen one, as in Blend. It is a List so arrow keys, focus and VoiceOver's selected
/// state come from macOS.
struct CallAudioPicker: View {
    @Environment(CallsModel.self) private var calls
    @State private var levels = CallLevelModel()
    @State private var icons: [String: NSImage] = [:]

    private static let automatic = "automatic"

    var body: some View {
        let apps = RunningCallApp.grouped(calls.running)
        let rows = 1 + apps.reduce(0) { $0 + $1.apps.count } + calls.mixes.count
        let sections = apps.count + (calls.mixes.isEmpty ? 0 : 1)
        List(selection: selection) {
            row(title: "Automatic", detail: automaticDetail, symbol: "wand.and.stars", id: Self.automatic)
            ForEach(apps, id: \.group) { group in
                Section(group.group.title) {
                    ForEach(group.apps) { app in
                        row(title: app.name, detail: CallAudioText.status(playing: app.playing, listening: app.listening),
                            icon: icon(for: app), id: CallAudioChoice.app(bundleID: app.bundleID).stored)
                    }
                }
            }
            if !calls.mixes.isEmpty {
                Section("Blend Mic mixes") {
                    ForEach(calls.mixes) { mix in
                        row(title: mix.label, detail: nil, symbol: "waveform",
                            id: CallAudioChoice.blendMix(deviceUID: mix.deviceUID ?? "").stored)
                    }
                }
            }
        }
        .listStyle(.inset)
        .frame(height: min(CGFloat(rows) * 34 + CGFloat(sections) * 28 + 8, 320))
        .accessibilityLabel("Call audio")
        .task { await keepCurrent() }
        .onChange(of: meterTarget) { _, target in levels.watch(target, permission: calls.capturePermission) }
        .onChange(of: calls.capturePermission) { _, permission in levels.watch(meterTarget, permission: permission) }
        .onDisappear { levels.stop() }
    }

    private var selection: Binding<String?> {
        Binding(get: { Self.selectedID(calls) },
                set: { calls.audioChoice = CallAudioChoice(stored: $0 == Self.automatic ? "" : $0 ?? "") })
    }

    private static func selectedID(_ calls: CallsModel) -> String {
        let stored = calls.audioChoice.stored
        return stored.isEmpty ? automatic : stored
    }

    /// The app whose level is shown: the chosen one, or for Automatic the call in progress.
    private var meterTarget: CallTapTarget? {
        switch calls.audioChoice {
        case .app(let id): calls.running.first { $0.bundleID == id }?.target
        case .automatic: calls.detected.first.map { CallTapTarget(bundleID: $0.bundleID, name: $0.name) }
        case .blendMix: nil
        }
    }

    private var automaticDetail: String {
        if let call = calls.detected.first { return "\(call.name) is in a call" }
        return "The app you are in a call with"
    }

    private func row(title: String, detail: String?, icon: NSImage? = nil, symbol: String? = nil, id: String) -> some View {
        let selected = Self.selectedID(calls) == id
        let shows = selected && meterTarget != nil && calls.capturePermission == .authorized
        return HStack(spacing: 10) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: symbol ?? "app").font(.system(size: 15)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if shows {
                CallLevelBar(level: levels.level).frame(width: 64, height: 6).accessibilityHidden(true)
            }
            if selected {
                Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .tag(id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(CallAudioText.accessibilityValue(status: detail, level: shows ? levels.level : nil,
                                                             selected: selected))
    }

    private func icon(for app: RunningCallApp) -> NSImage? {
        if let icon = icons[app.bundleID] { return icon }
        if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
            DispatchQueue.main.async { icons[app.bundleID] = icon }
            return icon
        }
        return nil
    }

    /// Looks at what the apps are doing once a second while the picker is open.
    private func keepCurrent() async {
        await calls.refreshSources()
        while !Task.isCancelled {
            await calls.refreshRunning()
            levels.watch(meterTarget, permission: calls.capturePermission)
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// A level as a bar. The same level is spoken as a word by the row, so the bar is only
/// for the eye.
struct CallLevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            let db = level > 0 ? 20 * log10(Double(level)) : -60
            let fraction = max(0, min(1, (db + 50) / 50))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.secondary).frame(width: proxy.size.width * fraction)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
