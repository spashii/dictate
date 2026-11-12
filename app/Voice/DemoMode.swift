import Foundation

/// A Debug build started with VOICE_DEMO_OUT draws its windows from made-up data and saves
/// pictures of them, so they can be looked at without anyone's recordings. It runs only
/// under a throwaway home folder (DemoRender checks), and the views that would read the
/// Mac, such as inputs, permissions and Ollama, hold still while it is on.
enum DemoMode {
    static var active: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["VOICE_DEMO_OUT"] != nil
        #else
        false
        #endif
    }
}
