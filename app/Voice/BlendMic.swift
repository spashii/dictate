import Foundation

/// Whether Blend Mic is on this Mac: its virtual microphone is listed among the inputs, or
/// Blend.app is installed to make one.
enum BlendMic {
    static let bundleID = "app.blend.Blend"
    static let website = URL(string: "https://spashii.github.io/blend/")!

    static func isInstalled(inputNames: [String], appURL: URL?) -> Bool {
        appURL != nil || inputNames.contains { $0.lowercased().contains("blend") }
    }
}
