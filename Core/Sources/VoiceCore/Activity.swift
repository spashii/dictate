import Foundation

/// What Voice is doing at a moment, for deciding when a staged update may quit and relaunch
/// it: a relaunch then would cut off a recording, a transcript or a fix.
public struct Activity: Sendable, Equatable {
    public var dictationRecording = false
    public var dictationTranscribing = false
    public var fixing = false
    public var callRecording = false
    public var callTranscribing = false
    /// A call app is in a call by CallDetector, recorded or not: the prompt to record it
    /// may be up, or about to be answered.
    public var callAppInCall = false
    /// An Ollama model is naming a call: it holds GPU memory, so nothing should restart Dictate.
    public var titling = false

    public init(dictationRecording: Bool = false, dictationTranscribing: Bool = false, fixing: Bool = false,
                callRecording: Bool = false, callTranscribing: Bool = false, callAppInCall: Bool = false,
                titling: Bool = false) {
        self.dictationRecording = dictationRecording
        self.dictationTranscribing = dictationTranscribing
        self.fixing = fixing
        self.callRecording = callRecording
        self.callTranscribing = callTranscribing
        self.callAppInCall = callAppInCall
        self.titling = titling
    }

    /// Nothing a relaunch would cut off.
    public var isQuiet: Bool {
        !(dictationRecording || dictationTranscribing || fixing || callRecording || callTranscribing || callAppInCall || titling)
    }
}
