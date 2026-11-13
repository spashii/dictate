import VoiceCore

/// The one rule for starting a dictation or a call recording: Dictate has to be activated. Everything that starts a recording asks it, so a new way to start one
/// can't skip it. Stopping, History, Settings and updates never ask.
enum RecordingGate {
    static let message = "Dictate is not activated yet"

    struct NotActivated: Error, CustomStringConvertible {
        var description: String { RecordingGate.message }
    }

    @MainActor
    static func check(_ activation: Activation) throws {
        guard activation.isActivated else { throw NotActivated() }
    }
}
