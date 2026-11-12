import Foundation

/// The words the call audio list says about an app, for the eye and for VoiceOver. State is
/// always written out, never left to an icon or a colour.
enum CallAudioText {
    static func status(playing: Bool, listening: Bool) -> String? {
        switch (playing, listening) {
        case (true, true): "In a call, playing sound"
        case (false, true): "Using the microphone"
        case (true, false): "Playing sound"
        case (false, false): nil
        }
    }

    /// A level as a short phrase, so a screen reader hears a steady word rather than a number
    /// that changes ten times a second.
    static func level(_ peak: Float) -> String {
        switch peak {
        case ..<0.01: "silent"
        case ..<0.1: "quiet"
        case ..<0.4: "medium"
        default: "loud"
        }
    }

    static func accessibilityValue(status: String?, level: Float?, selected: Bool) -> String {
        var parts: [String] = []
        if let status { parts.append(status) }
        if let level { parts.append("level \(Self.level(level))") }
        if selected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }
}
