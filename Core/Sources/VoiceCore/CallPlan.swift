import Foundation

/// An app whose sound is recorded as the call's other side.
public struct CallTapTarget: Sendable, Hashable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Where the other side of a call comes from, as Settings stores it.
public enum CallAudioChoice: Sendable, Equatable {
    /// The call app Dictate finds, so nothing has to be set up.
    case automatic
    /// One app, such as a browser or a call app Dictate doesn't know.
    case app(bundleID: String)
    /// A Blend Mic mix, for someone who already uses one.
    case blendMix(deviceUID: String)

    public init(stored: String) {
        if stored.hasPrefix("app:"), stored.count > 4 {
            self = .app(bundleID: String(stored.dropFirst(4)))
        } else if stored.hasPrefix("blend:"), stored.count > 6 {
            self = .blendMix(deviceUID: String(stored.dropFirst(6)))
        } else {
            self = .automatic
        }
    }

    /// What UserDefaults holds: empty for automatic.
    public var stored: String {
        switch self {
        case .automatic: ""
        case .app(let id): "app:\(id)"
        case .blendMix(let uid): "blend:\(uid)"
        }
    }

    /// Settings before call audio could be tapped had one "Record from" input, a Blend mix or
    /// a microphone. A mix stays the call audio and a microphone becomes the call microphone,
    /// so nobody's setup changes meaning.
    ///
    /// nil means "not yet": the stored input isn't a connected device right now (a Blend mix
    /// whose driver hasn't listed it, an unplugged headset). Guessing then would turn a mix
    /// into a microphone for good, so the caller keeps the old setting and asks again at the
    /// next device refresh.
    public static func migrate(legacyInput: String?, mixUIDs: Set<String>,
                               connectedUIDs: Set<String>) -> (choice: CallAudioChoice, microphoneUID: String)? {
        guard let legacyInput, !legacyInput.isEmpty else { return (.automatic, "") }
        if mixUIDs.contains(legacyInput) { return (.blendMix(deviceUID: legacyInput), "") }
        guard connectedUIDs.contains(legacyInput) else { return nil }
        return (.automatic, legacyInput)
    }
}

/// Whether Dictate may record other apps' sound: macOS's "System Audio Recording" permission.
public enum AudioCapturePermission: Sendable, Equatable {
    case authorized
    case denied
    /// Not asked yet, or macOS won't say. Recording asks, and a refusal falls back to the
    /// microphone alone.
    case unknown
}

/// What a call records, worked out before it starts: pure, so every fallback can be tested
/// without audio hardware.
public struct CallPlan: Sendable, Equatable {
    /// A Blend mix read as one two-channel device. When set, the rest is unused.
    public var mix: CallSource?
    /// The microphone for the Me side, or the only side when nothing else is recorded.
    public var microphone: CallSource
    /// The app tapped for the Call side.
    public var app: CallTapTarget?
    /// Why this isn't what was chosen, for the person to read.
    public var notices: [String]

    /// Both sides come apart, whichever way they are read.
    public var split: Bool { mix?.split == true || app != nil }
}

public enum CallPlanner {
    public struct Inputs: Sendable {
        public var choice: CallAudioChoice
        /// The call microphone's UID; empty is the system default.
        public var microphoneUID: String
        /// The app the recording was started for, when a call was detected.
        public var detected: [DetectedCall]
        /// Apps running now, as the picker lists them.
        public var running: [CallTapTarget]
        /// Blend mixes whose devices are connected.
        public var mixes: [CallSource]
        /// Every input the Mac has, mixes included.
        public var devices: [InputDevice]
        public var permission: AudioCapturePermission
        /// The app asking, left out of the choice: Dictate never records itself.
        public var ownBundleID: String?

        public init(choice: CallAudioChoice, microphoneUID: String, detected: [DetectedCall],
                    running: [CallTapTarget], mixes: [CallSource], devices: [InputDevice],
                    permission: AudioCapturePermission, ownBundleID: String? = nil) {
            self.choice = choice
            self.microphoneUID = microphoneUID
            self.detected = detected
            self.running = running
            self.mixes = mixes
            self.devices = devices
            self.permission = permission
            self.ownBundleID = ownBundleID
        }
    }

    public static let permissionNotice =
        "Dictate isn't allowed to record call audio, so only your microphone is recorded. "
        + "Allow it under System Audio Recording in System Settings."

    public static func tapFailedNotice(_ app: String) -> String {
        "Couldn't record \(app)'s sound, so only your microphone is recorded."
    }

    public static func plan(_ input: Inputs, appStarted: DetectedCall? = nil) -> CallPlan {
        var notices: [String] = []
        let mixUIDs = Set(input.mixes.map(\.deviceUID).compactMap { $0 })
        let microphone = microphone(input, mixUIDs: mixUIDs, notices: &notices)

        var mix: CallSource?
        var app: CallTapTarget?
        switch input.choice {
        case .blendMix(let uid):
            if let found = input.mixes.first(where: { $0.deviceUID == uid }) {
                mix = found
            } else {
                notices.append("The Blend Mic mix chosen for calls isn't connected. Is Blend running?")
            }
        case .app(let id):
            if let found = input.running.first(where: { $0.bundleID == id }) {
                app = found
            } else {
                notices.append("The app chosen for call audio isn't running, so Dictate picks the call app itself.")
            }
        case .automatic:
            break
        }
        if mix == nil, app == nil {
            // The app the recording was started for, then any other app in a call.
            let call = appStarted ?? input.detected.first
            if let call, call.bundleID != input.ownBundleID {
                app = CallTapTarget(bundleID: call.bundleID, name: call.name)
            } else if let split = input.mixes.first(where: \.split) {
                // A manual recording with no call found: a split Blend mix is the one source
                // that tells the sides apart, as before call audio could be tapped.
                mix = split
            }
        }
        if mix == nil, app != nil, input.permission == .denied {
            app = nil
            notices.append(permissionNotice)
        }
        return CallPlan(mix: mix, microphone: microphone, app: app, notices: notices)
    }

    private static func microphone(_ input: Inputs, mixUIDs: Set<String>, notices: inout [String]) -> CallSource {
        guard !input.microphoneUID.isEmpty else { return .systemDefault }
        if let device = input.devices.first(where: { $0.uid == input.microphoneUID }),
           !mixUIDs.contains(device.uid) {
            return CallSource(deviceUID: device.uid, name: device.name, channels: [.mix], fromBlend: false)
        }
        notices.append("The microphone chosen for calls isn't connected, so the system default records.")
        return .systemDefault
    }
}
