import AudioToolbox
import AVFoundation
import BlendKit
import CoreAudio
import Foundation
import os

extension Paths {
    /// Call audio lives apart from dictation recordings, so dictation recovery never takes a
    /// call's WAV for a lost dictation.
    public static var calls: URL { support.appending(path: "calls", directoryHint: .isDirectory) }
}

/// Records a call from a Blend mix, a microphone, or a microphone with a call app's sound
/// (BlendKit), and transcribes it while it runs.
///
/// While the call runs the WAV is the source of truth: it is written as the audio arrives, at
/// the device's own rate, with me on the left and the call on the right whatever order the
/// device uses, so `rebuild` can redo a call's transcript from the file alone. Once the
/// transcript is complete the WAV is replaced by an AAC .m4a of the same audio (see
/// CallAudio), which `rebuild` reads just as well. Each side is cut at pauses,
/// brought to 16 kHz and transcribed on its own; whisper takes one decode at a time, so
/// call chunks and dictations share the transcriber and queue behind each other.
///
/// Device calls run on the recorder's own queue, as in Recorder: a coreaudiod that stops
/// answering stalls this queue, not the main thread.
public final class CallRecorder: @unchecked Sendable {
    public let store: CallStore
    private let queue = DispatchQueue(label: "voice.call-recorder", qos: .userInitiated)
    private let lock = OSAllocatedUnfairLock()
    private var engine: AVAudioEngine?
    private var watch: InputWatch?
    /// The BlendKit capture and the route of its frames into the session, while a call records
    /// the microphone and an app's sound.
    private var capture: (any CallCapturing)?
    private var frames: CallFrames?
    private var session: CallSession?
    /// Calls whose audio is being compressed, so one call is never converted twice at once.
    private var compressing: Set<String> = []
    private var conversions: [Task<Void, Never>] = []
    private var deletesAudioWhenDone = false
    private let directory: URL
    private let onInputLost: @Sendable (Call?) -> Void
    private let onNotice: @Sendable (String) -> Void
    private let makeCapture: CallCaptureFactory
    private let permission: @Sendable () -> AudioCapturePermission

    /// What a call cut short by its input going away is failed with.
    public static let inputLost = "The input went away"

    /// `onInputLost` gets the call once it is finished as failed because the input went
    /// away mid-call. `onNotice` gets what the person should know while a call records (the
    /// call app's sound is lost, the microphone is missing); none of it ends the call.
    /// `capture` and `permission` are replaced by tests.
    public init(store: CallStore, directory: URL = Paths.calls,
                onInputLost: @escaping @Sendable (Call?) -> Void = { _ in },
                onNotice: @escaping @Sendable (String) -> Void = { _ in },
                capture: @escaping CallCaptureFactory = CallRecorder.blendKitCapture,
                permission: @escaping @Sendable () -> AudioCapturePermission = { AudioCapture.permission() }) {
        self.store = store
        self.directory = directory
        self.onInputLost = onInputLost
        self.onNotice = onNotice
        self.makeCapture = capture
        self.permission = permission
    }

    /// The call being recorded, if any.
    public var callID: String? { lock.withLockUnchecked { session?.callID } }

    /// Starts recording the source's device, or the default microphone when it has none.
    public func start(_ source: CallSource, transcriber: Transcriber, whisper: WhisperOptions = WhisperOptions(),
                      appBundleID: String? = nil, appName: String? = nil, title: String? = nil) async throws -> Call {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Call, Error>) in
            queue.async {
                do {
                    done.resume(returning: try self.startDevice(source, transcriber, whisper, appBundleID, appName,
                                                                title))
                } catch {
                    self.stopEngine()
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// What a started call tells the person: why it isn't recording what they chose.
    public struct Started: Sendable {
        public var call: Call
        public var notices: [String]
    }

    /// Starts the call a plan describes: a Blend mix as one device, or BlendKit's capture of
    /// the microphone for me and the app for the call. When the app can't be tapped the microphone is
    /// recorded alone, and the notice says so, so a call is never lost to the tap.
    public func start(_ plan: CallPlan, transcriber: Transcriber, whisper: WhisperOptions = WhisperOptions(),
                      appBundleID: String? = nil, appName: String? = nil, title: String? = nil) async throws -> Started {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Started, Error>) in
            queue.async {
                var notices = plan.notices
                do {
                    if let mix = plan.mix {
                        let call = try self.startOnDevice(mix, transcriber, whisper, appBundleID, appName, title)
                        done.resume(returning: Started(call: call, notices: notices))
                        return
                    }
                    if let app = plan.app {
                        do {
                            let call = try self.startTapped(plan.microphone, app, echo: plan.echoCancellation, transcriber, whisper,
                                                            appBundleID, appName, title)
                            done.resume(returning: Started(call: call, notices: notices))
                            return
                        } catch let failure as TapUnavailable {
                            Self.log.error("No tap on \(app.bundleID, privacy: .public): \(failure.reason, privacy: .public)")
                            notices.append(CallPlanner.tapFailedNotice(app.name))
                        }
                    }
                    let call = try self.startOnDevice(plan.microphone, transcriber, whisper, appBundleID, appName, title)
                    done.resume(returning: Started(call: call, notices: notices))
                } catch {
                    self.stopEngine()
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// Stops recording and returns once the last words are transcribed. Nil when nothing was
    /// recording.
    @discardableResult
    public func stop() async -> Call? {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.stopEngine()
                done.resume()
            }
        }
        guard let session = lock.withLockUnchecked({ () -> CallSession? in
            defer { self.session = nil }
            return self.session
        }) else { return nil }
        return await finish(session)
    }

    /// Stops recording and closes the WAV without transcribing what is left, so quitting
    /// stays quick. The call stays marked recording, and the next launch rebuilds it.
    public func abandon() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.stopEngine()
                done.resume()
            }
        }
        lock.withLockUnchecked {
            session?.close()
            session = nil
        }
    }

    /// Feeds a WAV through the same path as a live call, in real time unless told not to:
    /// what `dictate-cli call --file` tests. Left is me and right is the call when it has
    /// two channels.
    public func play(_ file: URL, transcriber: Transcriber, whisper: WhisperOptions = WhisperOptions(),
                     realTime: Bool = true, appBundleID: String? = nil, appName: String? = nil,
                     title: String? = nil, onStart: @Sendable (Call) -> Void = { _ in }) async throws -> Call {
        let audio = try AVAudioFile(forReading: file)
        let format = audio.processingFormat
        let labels: [CallSegment.Channel] = format.channelCount >= 2 ? [.me, .call] : [.mix]
        let session = try begin(format: format, labels: labels, order: Array(0..<min(Int(format.channelCount), 2)),
                                deviceUID: nil, transcriber, whisper, appBundleID: appBundleID, appName: appName,
                                title: title)
        if let call = try store.call(session.callID) { onStart(call) }
        let step = AVAudioFrameCount(format.sampleRate / 10)
        let clock = ContinuousClock()
        let began = clock.now
        var read = 0.0
        while audio.framePosition < audio.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: step) else { break }
            try audio.read(into: buffer, frameCount: step)
            session.ingest(buffer)
            read += Double(buffer.frameLength) / format.sampleRate
            if realTime { try? await clock.sleep(until: began + .seconds(read)) }
        }
        lock.withLockUnchecked { self.session = nil }
        guard let call = await finish(session) else { throw VoiceError.store("Call \(session.callID) is gone.") }
        return call
    }

    /// Transcribes a call again from its audio, replacing its segments: for a call whose
    /// recording was cut off by a crash, or whose transcription failed. The old segments go
    /// only once the first chunk has decoded, so audio or a model that can't be read leaves
    /// the call with the transcript it had. `onProgress` gets 0 to 1. Cancelling leaves the
    /// call as it was, still transcribing, for the next launch to finish.
    public func rebuild(_ callID: String, transcriber: any ChunkTranscribing,
                        whisper: WhisperOptions = WhisperOptions(),
                        onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Call {
        guard let call = try store.call(callID), let path = call.audioPath else {
            throw VoiceError.store("Call \(callID) has no audio to rebuild from.")
        }
        let url = URL(fileURLWithPath: path)
        // Only a WAV's header can be left unfinished by a crash.
        if CallAudio.isWAV(path) { Recovery.repairHeader(url) }
        let audio: AVAudioFile
        do {
            audio = try AVAudioFile(forReading: url)
        } catch {
            // A call left live by a crash would otherwise stay "recording" for good.
            if call.status.isLive { try? store.failCall(callID, error: "Can't read its audio: \(error)") }
            throw error
        }
        let format = audio.processingFormat
        // A split call's file always has two channels; one that doesn't has lost a side, and
        // transcribing it as one would finish the call as if it hadn't.
        if call.split && format.channelCount != 2 {
            let reason = CallChannels.sidesMissing(Int(format.channelCount))
            try? store.failCall(callID, error: reason)
            throw VoiceError.audio(reason)
        }
        let labels: [CallSegment.Channel] = call.split ? [.me, .call] : [.mix]
        try store.markTranscribing(callID, endedAt: call.endedAt ?? Date())
        let seconds = Double(audio.length) / format.sampleRate
        let session = try CallSession(callID: callID, format: format, labels: labels,
                                      order: Self.channelOrder(format, split: call.split), wav: nil,
                                      replacingSegments: true, store: store, transcriber: transcriber,
                                      whisper: whisper, progress: { onProgress(min(1, $0 / max(seconds, 0.001))) })
        do {
            if try await Self.feed(audio, into: session) == .cancelled {
                session.close()
                throw CancellationError()
            }
        } catch {
            session.close()
            throw error
        }
        let ended = await finish(session) ?? call
        lock.withLockUnchecked { importPeak = max(importPeak, session.highWater) }
        return ended
    }

    /// A split call keeps its two sides; anything else is one mix of every channel in the file.
    private static func channelOrder(_ format: AVAudioFormat, split: Bool) -> [Int] {
        Array(0..<(split ? min(Int(format.channelCount), 2) : Int(format.channelCount)))
    }

    private enum Fed { case done, cancelled }

    /// Reads the file a second at a time into the session, holding back while more than
    /// `CallSession.maxQueued` chunks wait for whisper, so memory stays flat for a file of hours.
    private static func feed(_ audio: AVAudioFile, into session: CallSession) async throws -> Fed {
        let format = audio.processingFormat
        let step = AVAudioFrameCount(format.sampleRate)
        while audio.framePosition < audio.length {
            while session.queued > CallSession.maxQueued, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if Task.isCancelled { return .cancelled }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: step) else { break }
            try audio.read(into: buffer, frameCount: step)
            guard buffer.frameLength > 0 else { break }
            session.ingest(buffer)
        }
        return .done
    }

    /// What `beginImport` made or found.
    public struct ImportStart: Sendable {
        public var call: Call
        /// The file was imported before, and `call` is that import: nothing new was made.
        public var duplicate: Bool
    }

    /// Starts an import: copies the file beside the calls, hashes the copy, and unless a call
    /// already holds the same bytes, makes the row at once so the history shows it while it
    /// waits. Once this returns the original can be moved or deleted. The row's time is when it
    /// was imported, and its end is set once the file's length is known.
    ///
    /// The copy is a `.partial` until its row exists, and the row names the final path before
    /// the rename. A quit in between leaves a row whose file is missing, which the next launch
    /// fails with a message, and a `.partial` that is swept; a quit before the row leaves only
    /// the `.partial`.
    public func beginImport(_ source: URL, at: Date = Date()) async throws -> ImportStart {
        let id = UUID().uuidString
        let ext = source.pathExtension.lowercased()
        let stored = directory.appending(path: "\(Int(at.timeIntervalSince1970 * 1000))-\(id.prefix(8)).\(ext)")
        let partial = stored.appendingPathExtension("partial")
        let hash = try await Task.detached(priority: .utility) { () -> String in
            let descriptor = try AudioImport.openRegularFile(source)
            defer { close(descriptor) }
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            try AudioImport.copy(descriptor: descriptor, to: partial)
            do {
                return try AudioImport.sha256(of: partial)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw error
            }
        }.value
        let made: (call: Call, duplicate: Bool)
        do {
            made = try store.createImport(NewCall(id: id, startedAt: at, split: false, audioPath: stored.path,
                                                  fileName: source.lastPathComponent, fileHash: hash,
                                                  endedAt: at, status: .transcribing))
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        if made.duplicate {
            try? FileManager.default.removeItem(at: partial)
        } else {
            do {
                try FileManager.default.moveItem(at: partial, to: stored)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                try? store.deleteCall(id)
                throw error
            }
        }
        return ImportStart(call: made.call, duplicate: made.duplicate)
    }

    /// Removes the half-written copies a quit mid-import left in the calls folder. The app runs
    /// it at launch, before anything else reads the folder.
    public func sweepPartials() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".partial") {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    /// The most chunks that waited for whisper at once during any import or rebuild, for a test
    /// of the back-pressure.
    var importHighWater: Int { lock.withLockUnchecked { importPeak } }
    private var importPeak = 0

    /// Transcribes the stored copy of an import as one track, the way a rebuild does, with
    /// reading held back while whisper has a few chunks to catch up on. A copy AVAudioFile can't
    /// open, or that carries video, is first reduced to its audio as an .m4a. Whatever goes wrong
    /// ends the call as failed with a reason a person can read. `onProgress` gets 0 to 1, the part
    /// of the file the transcript reaches. Returns the call as it ends up.
    public func transcribeImport(_ callID: String, transcriber: any ChunkTranscribing,
                                 whisper: WhisperOptions = WhisperOptions(),
                                 onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async -> Call? {
        guard let call = try? store.call(callID) else { return nil }
        func fail(_ reason: String, removing file: URL? = nil) -> Call? {
            if let file {
                try? FileManager.default.removeItem(at: file)
                try? store.clearAudioPath(callID)
            }
            try? store.failCall(callID, error: reason)
            return try? store.call(callID)
        }
        guard let path = call.audioPath, FileManager.default.fileExists(atPath: path) else {
            return fail("This file's copy is missing. Import it again.")
        }
        let copy = URL(fileURLWithPath: path)
        let stored: AudioImport.Prepared
        do {
            stored = try await AudioImport.prepare(copy: copy)
        } catch is CancellationError {
            // Quitting cancels too: the row keeps its copy, and the next launch reads it again.
            return try? store.call(callID)
        } catch {
            return fail((error as? AudioImportError)?.description ?? AudioImport.unreadable, removing: copy)
        }
        let audio: AVAudioFile
        do {
            audio = try AVAudioFile(forReading: stored.url)
            try store.setImportedAudio(callID, path: stored.url.path,
                                       endedAt: call.startedAt.addingTimeInterval(stored.duration))
        } catch {
            if let raw = stored.superseded { try? FileManager.default.removeItem(at: raw) }
            return fail(AudioImport.unreadable, removing: stored.url)
        }
        if let raw = stored.superseded { try? FileManager.default.removeItem(at: raw) }
        // A crash after the row moved to the .m4a can leave the video it came from beside it.
        if stored.url.pathExtension.lowercased() == "m4a" {
            let stem = stored.url.deletingPathExtension()
            for ext in AudioImport.videoExtensions where FileManager.default.fileExists(atPath: stem.appendingPathExtension(ext).path) {
                try? FileManager.default.removeItem(at: stem.appendingPathExtension(ext))
            }
        }
        let format = audio.processingFormat
        let duration = stored.duration
        let session: CallSession
        do {
            session = try CallSession(callID: callID, format: format, labels: [.mix],
                                      order: Self.channelOrder(format, split: false), wav: nil,
                                      replacingSegments: true, store: store,
                                      transcriber: transcriber, whisper: whisper,
                                      progress: { onProgress(min(1, $0 / duration)) })
        } catch {
            return fail(AudioImport.unreadable)
        }
        do {
            if try await Self.feed(audio, into: session) == .cancelled {
                // The row stays transcribing with its copy: quitting cancels too, and the next
                // launch reads the file again. A person who cancels fails the row themselves.
                await session.closeAndWait()
                return try? store.call(callID)
            }
        } catch {
            await session.closeAndWait()
            return fail(AudioImport.unreadable)
        }
        let ended = await finish(session)
        lock.withLockUnchecked { importPeak = max(importPeak, session.highWater) }
        return ended
    }

    /// Replaces a finished call's WAV with an AAC .m4a, off the calling thread. The call's
    /// path moves to the .m4a and the WAV goes only once the .m4a has opened with the WAV's
    /// duration and channels; on any failure the WAV and the path stay as they were, so
    /// the next launch tries again. Returns whether the call's audio is now the .m4a.
    @discardableResult
    public func compressAudio(_ callID: String) async -> Bool {
        guard let call = try? store.call(callID), call.status == .done, let path = call.audioPath,
              CallAudio.isWAV(path), claim(callID) else { return false }
        defer { release(callID) }
        let wav = URL(fileURLWithPath: path)
        do {
            let m4a = try await Task.detached(priority: .utility) { try CallAudio.encode(wav, stereoAtMost: call.fileName != nil) }.value
            do {
                try store.setAudioPath(callID, m4a.path)
            } catch {
                try? FileManager.default.removeItem(at: m4a)
                throw error
            }
            try? FileManager.default.removeItem(at: wav)
            return true
        } catch {
            Self.log.error("Kept the WAV of call \(callID, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Compresses every finished call still holding a WAV: those that finished before this
    /// existed, whose conversion failed, or that were cut off by quitting mid-conversion.
    /// The app runs it at launch, after the interrupted calls are rebuilt.
    public func compressFinishedCalls() async {
        for call in (try? store.callsAwaitingCompression()) ?? [] {
            await compressAudio(call.id)
        }
    }

    /// Returns once every conversion started by a finished call is over, for a process that
    /// would otherwise exit with one half written. The app doesn't wait: quitting leaves the
    /// WAV, and the next launch converts it.
    public func waitForCompression() async {
        let tasks = lock.withLockUnchecked { () -> [Task<Void, Never>] in
            defer { conversions = [] }
            return conversions
        }
        for task in tasks { await task.value }
    }

    /// Deletes a call's audio under the same claim a compression takes, so the file never
    /// goes while it is being converted. Returns false when the call was claimed.
    public func deleteAudio(_ callID: String) -> Bool {
        guard claim(callID) else { return false }
        defer { release(callID) }
        return (try? store.clearAudio(callID)) ?? false
    }

    /// While on, a call that finishes well has its audio deleted instead of compressed: the
    /// "Until transcribed" choice. A failed call keeps its audio so it can be tried again.
    public func setDeletesAudioWhenDone(_ on: Bool) {
        lock.withLockUnchecked { deletesAudioWhenDone = on }
    }

    private static let log = Logger(subsystem: "io.github.spashii.voice", category: "call-audio")

    private func claim(_ callID: String) -> Bool {
        lock.withLockUnchecked { compressing.insert(callID).inserted }
    }

    private func release(_ callID: String) {
        lock.withLockUnchecked { _ = compressing.remove(callID) }
    }

    /// The engine stopped itself: the input went away or changed under it mid-call. The WAV
    /// keeps what came before, and the call is finished as failed with its transcript as
    /// far as the audio went. An engine still running had a change that didn't touch its
    /// input, and records on.
    func inputWentAway() {
        queue.async {
            if self.engine?.isRunning == true { return }
            self.stopEngine()
            guard let session = self.lock.withLockUnchecked({ () -> CallSession? in
                defer { self.session = nil }
                return self.session
            }) else { return }
            Task {
                let call = await self.finish(session, failure: Self.inputLost)
                self.onInputLost(call)
            }
        }
    }

    // MARK: Internals

    /// Replaces opening a device for the planned paths, so a test of the fallback never opens
    /// the Mac's microphone.
    var deviceStart: (@Sendable (CallSource) throws -> Call)?

    private func startOnDevice(_ source: CallSource, _ transcriber: Transcriber, _ whisper: WhisperOptions,
                               _ appBundleID: String?, _ appName: String?, _ title: String?) throws -> Call {
        if let deviceStart { return try deviceStart(source) }
        return try startDevice(source, transcriber, whisper, appBundleID, appName, title)
    }

    private func startDevice(_ source: CallSource, _ transcriber: Transcriber, _ whisper: WhisperOptions,
                             _ appBundleID: String?, _ appName: String?, _ title: String?) throws -> Call {
        guard callID == nil else { throw VoiceError.audio("A call is already being recorded.") }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = source.deviceUID {
            guard var device = InputDevices.id(forUID: uid), let unit = input.audioUnit,
                  AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                throw VoiceError.audio("\(source.name) isn't available. Is Blend Mic running?")
            }
        }
        guard let format = input.deviceFormat else {
            throw VoiceError.audio("No microphone is available.")
        }
        let session = try open(source, format: format, transcriber, whisper, appBundleID: appBundleID,
                               appName: appName, title: title)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in session.ingest(buffer) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            lock.withLockUnchecked { self.session = nil }
            try? store.failCall(session.callID, error: "The input wouldn't start: \(error)")
            throw error
        }
        self.engine = engine
        watch = InputWatch(engine) { [weak self] in self?.inputWentAway() }
        return try store.call(session.callID)!
    }

    /// Why the call app couldn't be captured, before any call exists, so the call falls back
    /// to the microphone without a failed entry in the history.
    private struct TapUnavailable: Error {
        let reason: String
    }

    /// Me is the microphone and the call is the app, both from one BlendKit capture at 48 kHz
    /// and the same instants. The capture starts before the call exists; if the app can't be
    /// captured, the call isn't started here at all. Once it runs nothing BlendKit reports
    /// ends it: events become notices, and only `start()` failing is a failure.
    private func startTapped(_ microphone: CallSource, _ app: CallTapTarget, echo: EchoCancellation,
                             _ transcriber: Transcriber, _ whisper: WhisperOptions, _ appBundleID: String?,
                             _ appName: String?, _ title: String?) throws -> Call {
        guard callID == nil else { throw VoiceError.audio("A call is already being recorded.") }
        let frames = CallFrames()
        let notify = onNotice
        let permission = permission
        let capture = makeCapture(
            CallCaptureOptions(label: "Dictate", microphoneUID: microphone.deviceUID, echoCancellation: echo,
                               call: TapTarget(bundleID: app.bundleID), outputRate: Int(CallFrames.rate)),
            { me, call, _ in frames.push(me: me, call: call) },
            { event in
                Self.log.info("Call capture: \(String(describing: event), privacy: .public)")
                // Asked only when needed: the answer can take a moment, and nothing waits on it.
                var current = AudioCapturePermission.unknown
                if case .callSilent = event { current = permission() }
                if let text = CallPlanner.notice(for: event, app: app.name, permission: current) { notify(text) }
            })
        do {
            try capture.start()
        } catch CallCaptureError.callUnavailable {
            throw TapUnavailable(reason: "\(app.bundleID) couldn't be captured")
        } catch CallCaptureError.microphoneUnavailable {
            throw VoiceError.audio(microphone.deviceUID == nil ? "No microphone is available."
                                                                : "\(microphone.name) isn't available.")
        }
        let session: CallSession
        do {
            session = try begin(format: AVAudioFormat(standardFormatWithSampleRate: CallFrames.rate, channels: 2)!,
                                labels: [.me, .call], order: [0, 1], deviceUID: microphone.deviceUID, transcriber,
                                whisper, appBundleID: appBundleID, appName: appName, title: title)
        } catch {
            capture.stop()
            frames.detach()
            throw error
        }
        frames.attach(session)
        self.capture = capture
        self.frames = frames
        return try store.call(session.callID)!
    }

    /// Starts the session for a source's audio in this format. A split source whose audio
    /// doesn't come as two channels is failed before it records anything, since it would
    /// end as a finished call with a side missing. The failed call keeps its file and stays
    /// in the history with the reason, and the same reason is thrown.
    func open(_ source: CallSource, format: AVAudioFormat, _ transcriber: Transcriber, _ whisper: WhisperOptions,
              appBundleID: String?, appName: String?, title: String?) throws -> CallSession {
        let channels: CallChannels
        do {
            channels = try CallChannels(source, inputChannels: Int(format.channelCount))
        } catch {
            let session = try begin(format: format, labels: [.mix], order: [0], deviceUID: source.deviceUID,
                                    transcriber, whisper, appBundleID: appBundleID, appName: appName, title: title)
            lock.withLockUnchecked { self.session = nil }
            session.close()
            try? store.failCall(session.callID, error: "\(error)")
            throw error
        }
        return try begin(format: format, labels: channels.labels, order: channels.order, deviceUID: source.deviceUID,
                         transcriber, whisper, appBundleID: appBundleID, appName: appName, title: title,
                         speakers: channels.speakers)
    }

    func begin(format: AVAudioFormat, labels: [CallSegment.Channel], order: [Int], deviceUID: String?,
               _ transcriber: Transcriber, _ whisper: WhisperOptions, appBundleID: String?,
               appName: String?, title: String?, speakers: [String]? = nil) throws -> CallSession {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let started = Date()
        let wav = directory.appending(path: "\(Int(started.timeIntervalSince1970 * 1000))-\(id.prefix(8)).wav")
        try store.createCall(NewCall(id: id, startedAt: started, appBundleID: appBundleID, appName: appName,
                                     deviceUID: deviceUID, split: labels.count == 2, audioPath: wav.path,
                                     title: title, speakers: speakers))
        do {
            let session = try CallSession(callID: id, format: format, labels: labels, order: order, wav: wav,
                                          store: store, transcriber: transcriber, whisper: whisper)
            lock.withLockUnchecked { self.session = session }
            return session
        } catch {
            try? store.failCall(id, error: "\(error)")
            throw error
        }
    }

    /// `failure` is why the call ended early, which outranks a chunk that failed to transcribe.
    private func finish(_ session: CallSession, failure: String? = nil) async -> Call? {
        try? store.markTranscribing(session.callID)
        let transcription = await session.finish()
        if let failure = failure ?? transcription {
            try? store.failCall(session.callID, error: failure)
        } else {
            try? store.finishCall(session.callID)
            let id = session.callID
            if lock.withLockUnchecked({ deletesAudioWhenDone }) {
                // The session's worker, retries included, has returned: nothing reads the file now.
                _ = deleteAudio(id)
            } else {
                // Left to run on its own: stopping a call returns once its words are in.
                let conversion = Task(priority: .utility) { _ = await self.compressAudio(id) }
                lock.withLockUnchecked { conversions.append(conversion) }
            }
        }
        return try? store.call(session.callID)
    }

    private func stopEngine() {
        watch?.cancel()
        watch = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        // Returns once the last frames of both sides have reached the session, which is
        // finished only after this.
        capture?.stop()
        capture = nil
        frames?.detach()
        frames = nil
    }
}

/// One call's audio on its way to the WAV and to whisper. `ingest` runs on the audio tap's
/// thread; the lock keeps a late buffer away from a closed file.
final class CallSession: @unchecked Sendable {
    let callID: String
    private let lock = OSAllocatedUnfairLock()
    private var file: (any AudioWriting)?
    /// The first write that failed. The call goes on being transcribed, and is failed with
    /// this when it finishes, since its WAV stops here and can't rebuild the rest.
    private var writeError: String?
    private let fileFormat: AVAudioFormat
    private let order: [Int]
    private var lanes: [Lane]
    private var closed = false
    private let chunks: AsyncStream<SpeechChunk>.Continuation
    private let worker: Task<String?, Never>
    private let backlog = Backlog()

    /// Chunks cut and not yet transcribed, with the most there have been at once.
    private final class Backlog: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock()
        private var count = 0
        private var peak = 0

        func add() { lock.withLockUnchecked { count += 1; peak = max(peak, count) } }
        func done() { lock.withLockUnchecked { count -= 1 } }
        var queued: Int { lock.withLockUnchecked { count } }
        var highWater: Int { lock.withLockUnchecked { peak } }
    }

    /// How many chunks an import lets wait for whisper before it stops reading the file, so a
    /// file of hours is held a few seconds at a time. A buffer can add one more past this.
    static let maxQueued = 2

    /// Chunks cut and not yet transcribed.
    var queued: Int { backlog.queued }
    var highWater: Int { backlog.highWater }

    /// One side of the call: a channel of the file (or all of them, for a mix) at 16 kHz.
    private struct Lane {
        let channel: CallSegment.Channel
        let source: Int?
        let mono: AVAudioFormat
        let converter: AVAudioConverter
        var chunker = SpeechChunker()
    }

    /// `order` picks the input channels written to the file, in file order; the lanes read
    /// the file's channels, so labels[0] is the file's left.
    init(callID: String, format: AVAudioFormat, labels: [CallSegment.Channel], order: [Int], wav: URL?,
         writer: (any AudioWriting)? = nil, replacingSegments: Bool = false, store: CallStore,
         transcriber: any ChunkTranscribing, whisper: WhisperOptions,
         progress: (@Sendable (_ seconds: Double) -> Void)? = nil) throws {
        self.callID = callID
        self.order = order
        // Standard formats of more than two channels need a layout.
        fileFormat = order.count <= 2
            ? AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(order.count))!
            : AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, interleaved: false,
                            channelLayout: AVAudioChannelLayout(
                                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(order.count))!)
        if let wav {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: order.count,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            file = try AVAudioFile(forWriting: wav, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        }
        if let writer { file = writer }
        let mono = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
        lanes = try labels.enumerated().map { index, channel in
            guard let converter = AVAudioConverter(from: mono, to: Audio.format) else {
                throw VoiceError.audio("Can't convert \(Int(format.sampleRate)) Hz audio to 16 kHz.")
            }
            return Lane(channel: channel, source: labels.count == 1 ? nil : index, mono: mono, converter: converter)
        }
        let (stream, continuation) = AsyncStream<SpeechChunk>.makeStream()
        chunks = continuation
        let backlog = backlog
        worker = Task.detached(priority: .userInitiated) {
            await Self.transcribe(stream, callID: callID, replacing: replacingSegments, store: store,
                                  transcriber: transcriber, whisper: whisper, backlog: backlog, progress: progress)
        }
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let input = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        lock.withLockUnchecked {
            guard !closed, let picked = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: buffer.frameLength),
                  let out = picked.floatChannelData else { return }
            picked.frameLength = buffer.frameLength
            for (to, from) in order.enumerated() {
                out[to].update(from: input[min(from, Int(buffer.format.channelCount) - 1)], count: frames)
            }
            do {
                try file?.write(from: picked)
            } catch {
                writeError = "Couldn't write the call's audio: \(error)"
                file = nil
            }
            for i in lanes.indices {
                for chunk in lanes[i].chunker.append(resample(picked, lane: lanes[i])) {
                    backlog.add()
                    chunks.yield(SpeechChunk(channel: lanes[i].channel, start: chunk.start, samples: chunk.samples))
                }
            }
        }
    }

    func close() {
        lock.withLockUnchecked {
            closed = true
            file = nil
            chunks.finish()
        }
    }

    /// Closes without cutting the tail, and returns once the worker has stopped using whisper.
    func closeAndWait() async {
        close()
        _ = await worker.value
    }

    /// Cuts the tail, closes the file and waits for the transcription to catch up. Returns
    /// the write error if writing the WAV failed, or else the last transcription error.
    func finish() async -> String? {
        lock.withLockUnchecked {
            closed = true
            file = nil
            for i in lanes.indices {
                if let chunk = lanes[i].chunker.flush() {
                    backlog.add()
                    chunks.yield(SpeechChunk(channel: lanes[i].channel, start: chunk.start, samples: chunk.samples))
                }
            }
            chunks.finish()
        }
        let transcription = await worker.value
        return lock.withLockUnchecked { writeError } ?? transcription
    }

    private func resample(_ buffer: AVAudioPCMBuffer, lane: Lane) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard let mono = AVAudioPCMBuffer(pcmFormat: lane.mono, frameCapacity: buffer.frameLength),
              let channels = buffer.floatChannelData else { return [] }
        mono.frameLength = buffer.frameLength
        let target = mono.floatChannelData![0]
        if let source = lane.source {
            target.update(from: channels[source], count: frames)
        } else {
            let count = Int(buffer.format.channelCount)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<count { sum += channels[c][f] }
                target[f] = sum / Float(count)
            }
        }
        let capacity = AVAudioFrameCount(Double(frames) * Audio.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Audio.format, frameCapacity: capacity) else { return [] }
        let feed = OneShot(mono, ends: false)
        var error: NSError?
        lane.converter.convert(to: output, error: &error) { _, status in feed.next(status) }
        guard error == nil, output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// Transcribes chunks in the order they were cut, each with the same side's last words
    /// as whisper's context, and stores the segments as soon as each is done. `replacing`
    /// clears the call's old segments just before the first new ones are stored. `progress`
    /// gets how far into the audio the transcript now reaches, in seconds, after each chunk.
    private static func transcribe(_ stream: AsyncStream<SpeechChunk>, callID: String, replacing: Bool,
                                   store: CallStore, transcriber: any ChunkTranscribing,
                                   whisper: WhisperOptions, backlog: Backlog,
                                   progress: (@Sendable (Double) -> Void)?) async -> String? {
        var previous: [CallSegment.Channel: String] = [:]
        var failure: String?
        var replace = replacing
        var reached = 0.0
        for await chunk in stream {
            defer {
                backlog.done()
                reached = max(reached, Double(chunk.start + chunk.samples.count) / Audio.sampleRate)
                progress?(reached)
            }
            var options = whisper
            options.initialPrompt = previous[chunk.channel] ?? ""
            let offset = Double(chunk.start) / Audio.sampleRate
            let length = Double(chunk.samples.count) / Audio.sampleRate
            do {
                let transcript = try await transcriber.transcribe(chunk.samples, options: options)
                let segments = transcript.segments.filter { !$0.text.isEmpty }.map { segment in
                    var segment = segment
                    // Whisper pads a short chunk to a second; its times stay inside the audio.
                    segment.t1 = min(segment.t1, length)
                    return NewCallSegment(channel: chunk.channel, segment: segment, offset: offset)
                }
                if replace {
                    try store.deleteSegments(callID)
                    replace = false
                }
                try store.appendSegments(callID, segments)
                if !transcript.text.isEmpty { previous[chunk.channel] = transcript.text }
            } catch {
                failure = "\(error)"
            }
        }
        return failure
    }
}

/// Which input channels a call records, in file order, and what each side is called.
struct CallChannels: Equatable {
    /// labels[0] is the file's left.
    let labels: [CallSegment.Channel]
    /// The input channel written to each of the file's channels.
    let order: [Int]
    let speakers: [String]?

    /// A split source takes exactly two input channels, one per side, and throws on any
    /// other count: one channel holds a single side, and more can't be matched to Blend's
    /// left and right. A split mix with the call on the left is written swapped, so every
    /// WAV has me on the left and rebuild needs nothing but the file.
    init(_ source: CallSource, inputChannels: Int) throws {
        guard source.split else {
            labels = [.mix]
            order = Array(0..<min(inputChannels, 2))
            speakers = nil
            return
        }
        guard inputChannels == 2 else { throw VoiceError.audio(Self.sidesMissing(inputChannels)) }
        labels = [.me, .call]
        order = source.channels[0] == .me ? [0, 1] : [1, 0]
        speakers = source.speakers
    }

    static func sidesMissing(_ channels: Int) -> String {
        if channels > 2 {
            return "Got \(channels) channels from the call mix rather than 2, so its sides can't be told apart."
        }
        return "Got \(channels) channel\(channels == 1 ? "" : "s") from the call mix, so the call side is missing."
    }
}

struct SpeechChunk: Sendable {
    let channel: CallSegment.Channel
    /// Where it starts, in 16 kHz samples from the start of the call.
    let start: Int
    let samples: [Float]
}

/// Cuts one side's 16 kHz audio into stretches of speech at pauses, so each can be
/// transcribed as soon as its speaker stops. Loudness against a tracked noise floor decides
/// speech, which holds up for both a microphone with room noise and system audio that is
/// silent between words; whisper's own VAD then trims what is left inside each chunk.
struct SpeechChunker {
    static let frame = 480                          // 30 ms
    static let pauseFrames = 17                     // 0.5 s of quiet ends a chunk
    static let shortPauseFrames = 8                 // 0.25 s does once it runs past
    static let patience = 5 * 16_000                // 5 s, so someone talking at length is
                                                    // transcribed between breaths
    static let prerollFrames = 10                   // 0.3 s kept before speech starts
    static let tailFrames = 7                       // 0.2 s kept after it ends
    static let minSpeechFrames = 8                  // under 0.25 s of speech is a click
    static let maxSamples = 15 * 16_000             // within whisper's 30 s window, and soon enough

    /// Samples not yet cut, starting at `base`.
    private var buffer: [Float] = []
    private var base = 0
    /// Index in `buffer` of the next frame to judge.
    private var judged = 0
    private var chunkStart: Int?
    private var speechFrames = 0
    private var quietFrames = 0
    private var floor: Float = -60

    init() {}

    mutating func append(_ samples: [Float]) -> [(start: Int, samples: [Float])] {
        buffer += samples
        var cut: [(start: Int, samples: [Float])] = []
        while judged + Self.frame <= buffer.count {
            let frame = buffer[judged..<judged + Self.frame]
            let rms = (frame.reduce(0) { $0 + $1 * $1 } / Float(Self.frame)).squareRoot()
            let db = 20 * log10(max(rms, 1e-7))
            // Falls at once to anything quieter and creeps up 0.3 dB a second, so a long
            // stretch of speech doesn't become the floor.
            floor = min(floor + 0.01, db)
            let speech = db > max(floor + 12, -50)
            judged += Self.frame
            if let start = chunkStart {
                if speech {
                    speechFrames += 1
                    quietFrames = 0
                } else {
                    quietFrames += 1
                }
                let pause = judged - start >= Self.patience ? Self.shortPauseFrames : Self.pauseFrames
                if quietFrames >= pause {
                    let end = judged - max(0, quietFrames - Self.tailFrames) * Self.frame
                    if speechFrames >= Self.minSpeechFrames { cut.append(take(start, end)) }
                    chunkStart = nil
                } else if judged - start >= Self.maxSamples {
                    cut.append(take(start, judged))
                    trim(keeping: 0)
                    chunkStart = 0
                    speechFrames = 0
                }
            } else if speech {
                chunkStart = max(0, judged - (Self.prerollFrames + 1) * Self.frame)
                speechFrames = 1
                quietFrames = 0
            }
            if chunkStart == nil { trim(keeping: Self.prerollFrames * Self.frame) }
        }
        return cut
    }

    /// The speech still open when the call stops.
    mutating func flush() -> (start: Int, samples: [Float])? {
        defer { chunkStart = nil }
        guard let start = chunkStart, speechFrames >= Self.minSpeechFrames else { return nil }
        return take(start, buffer.count)
    }

    /// Positions are indexes into `buffer`; what is returned starts at an absolute sample.
    private mutating func take(_ from: Int, _ to: Int) -> (start: Int, samples: [Float]) {
        (base + from, Array(buffer[from..<max(from, min(to, buffer.count))]))
    }

    /// Drops what lies before the last `count` judged samples.
    private mutating func trim(keeping count: Int) {
        let drop = max(0, judged - count)
        guard drop > 0 else { return }
        buffer.removeFirst(drop)
        base += drop
        judged -= drop
    }
}
