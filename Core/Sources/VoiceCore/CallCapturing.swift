import AVFoundation
import BlendKit
import Foundation
import os

/// What a call needs of its capture: start it, stop it. BlendKit's `CallCapture` is the real
/// one; the narrow shape lets a test drive a call with frames and events it makes up, with no
/// audio hardware.
public protocol CallCapturing: AnyObject, Sendable {
    /// Throws `CallCaptureError`: `callUnavailable` leaves the microphone free to record alone.
    func start() throws
    /// Returns once every frame produced so far has reached the frames closure.
    func stop()
}

extension CallCapture: CallCapturing {}

public typealias CallCaptureFactory = @Sendable (
    CallCaptureOptions, @escaping CallCapture.Frames, @escaping CallCapture.Events
) -> any CallCapturing

extension CallRecorder {
    /// The capture every call but a test's uses.
    public static let blendKitCapture: CallCaptureFactory = { options, frames, events in
        CallCapture(options: options, frames: frames, events: events)
    }
}

/// Carries BlendKit's frames to a call's session. The capture starts before the call exists
/// (a tap that can't be made must leave no failed call in the history), so frames that
/// arrive first wait here and go in order once the session is attached.
final class CallFrames: @unchecked Sendable {
    static let rate = 48_000.0
    private static let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    /// A few seconds: starting a session takes milliseconds, so this only bounds a stuck one.
    private static let pendingLimit = 500

    private let lock = OSAllocatedUnfairLock()
    private var session: CallSession?
    private var pending: [AVAudioPCMBuffer] = []
    private var detached = false

    /// Me left and Call right, as the WAV and the session have them. Runs on BlendKit's
    /// delivery queue, never on the audio thread.
    func push(me: UnsafeBufferPointer<Float>, call: UnsafeBufferPointer<Float>) {
        let count = min(me.count, call.count)
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        channels[0].update(from: me.baseAddress!, count: count)
        channels[1].update(from: call.baseAddress!, count: count)
        lock.withLockUnchecked {
            if detached { return }
            if let session {
                session.ingest(buffer)
            } else if pending.count < Self.pendingLimit {
                pending.append(buffer)
            }
        }
    }

    func attach(_ session: CallSession) {
        lock.withLockUnchecked {
            guard !detached else { return }
            for buffer in pending { session.ingest(buffer) }
            pending = []
            self.session = session
        }
    }

    func detach() {
        lock.withLockUnchecked {
            detached = true
            session = nil
            pending = []
        }
    }
}
