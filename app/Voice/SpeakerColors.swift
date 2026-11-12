import AppKit
import SwiftUI

/// Who is speaking in a call transcript. Blue for Me and purple for Call, the hues of the live
/// call pill (CallPill.swift, 75% on its dark capsule). On a window text needs more contrast
/// than 75% of a system colour gives on white, so light mode uses a darker shade of each hue
/// (about 7:1 on white) and dark mode the system colours at full strength (about 4.6:1).
enum SpeakerColors {
    static let me = color(light: (0.00, 0.33, 0.70), dark: (0.04, 0.52, 1.00))
    static let call = color(light: (0.48, 0.22, 0.61), dark: (0.75, 0.35, 0.95))

    /// The colour for a speaker label as the transcript carries it ("Me" or "Call").
    static func color(for speaker: String?) -> Color {
        speaker == "Me" ? me : speaker == nil ? .secondary : call
    }

    private static func color(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}
