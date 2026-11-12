import Foundation

/// Whether macOS lets Dictate record other apps' sound. There is no public call to ask,
/// so this uses the one System Settings and open-source capture apps use; when it isn't
/// there the answer is unknown and recording asks.
public enum AudioCapture {
    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    public static var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
    }

    private static var handle: UnsafeMutableRawPointer? { dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW) }

    public static func permission() -> AudioCapturePermission {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows macOS's question if it hasn't been answered, then says what the answer was. A
    /// refused permission can only be changed in System Settings, so a second request
    /// returns the first answer without asking again.
    public static func request() async -> AudioCapturePermission {
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return .unknown }
        let call = unsafeBitCast(symbol, to: Request.self)
        let granted = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            call(service, nil) { done.resume(returning: $0) }
        }
        return granted ? .authorized : .denied
    }
}

