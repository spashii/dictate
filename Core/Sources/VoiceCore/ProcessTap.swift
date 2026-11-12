import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Reads the sound of one app's processes through a Core Audio process tap (macOS 14.2 and
/// later), without a driver and without changing what the app plays. A browser or call app
/// plays through helper processes, so every process that belongs to the app is tapped; new
/// ones, such as a tab that opens mid-call, are added while it runs.
///
/// Creating and tearing down a tap asks coreaudiod, so callers run this off the main thread.
public final class ProcessTap: @unchecked Sendable {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Mono samples at `rate`, from a real-time audio queue.
    public typealias Handler = @Sendable (_ samples: UnsafeBufferPointer<Float>, _ rate: Double) -> Void

    private let target: CallTapTarget
    private let queue = DispatchQueue(label: "voice.process-tap", qos: .userInteractive)
    private let lock = OSAllocatedUnfairLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var processes: [AudioObjectID] = []
    private var refresh: DispatchSourceTimer?
    private var outputListener: AudioObjectPropertyListenerBlock?
    /// Guarded apart from `lock`: stopping the device waits for the audio queue, which must
    /// never wait on `lock` meanwhile.
    private let handlerLock = OSAllocatedUnfairLock()
    private var handler: Handler?
    private var channels = 2
    private var rate = 48_000.0

    public init(_ target: CallTapTarget) {
        self.target = target
    }

    deinit { stop() }

    /// Starts delivering the app's sound. Throws when the app has no audio process, when
    /// macOS refuses the tap, or when the aggregate device that clocks it can't start.
    public func start(_ handler: @escaping Handler) throws {
        handlerLock.withLockUnchecked { self.handler = handler }
        do {
            try lock.withLockUnchecked { try open() }
        } catch {
            handlerLock.withLockUnchecked { self.handler = nil }
            throw error
        }
        // A new default output device means a new clock for the tap: the old one may be gone.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.async { self.reopen() }
        }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        outputListener = listener
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.refreshProcesses() }
        timer.resume()
        refresh = timer
    }

    public func stop() {
        refresh?.cancel()
        refresh = nil
        if let listener = outputListener {
            var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            outputListener = nil
        }
        handlerLock.withLockUnchecked { handler = nil }
        lock.withLockUnchecked { close() }
    }

    private var hasHandler: Bool { handlerLock.withLockUnchecked { handler != nil } }

    // MARK: Core Audio

    private func open() throws {
        let objects = TapProcesses.objects(forBundleID: target.bundleID)
        guard !objects.isEmpty else { throw Failure(description: "\(target.name) isn't playing or recording sound.") }
        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.name = "Dictate: \(target.name)"
        description.isPrivate = true
        // Muting is off by default: the call keeps playing for the person, the tap only listens.
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw Failure(description: "macOS refused the tap (\(status)).") }

        // The tap needs a device to clock it: wherever the app's sound goes.
        var output = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var outputAddress = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outputAddress, 0, nil, &size, &output)
        guard output != kAudioObjectUnknown, let outputUID = Self.string(output, kAudioDevicePropertyDeviceUID) else {
            AudioHardwareDestroyProcessTap(tap)
            throw Failure(description: "There is no output device to clock the tap.")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: description.name,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Auto-start would make other apps' microphone starts wait on this tap.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw Failure(description: "Couldn't make the device that reads the tap (\(status)).")
        }
        tapID = tap
        aggregateID = device
        tapDescription = description
        processes = objects

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = Self.address(kAudioTapPropertyFormat)
        if AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &format) == noErr,
           format.mSampleRate > 0 {
            rate = format.mSampleRate
            channels = max(1, Int(format.mChannelsPerFrame))
        } else {
            var nominal = Float64(0)
            var nominalSize = UInt32(MemoryLayout<Float64>.size)
            var nominalAddress = Self.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectGetPropertyData(device, &nominalAddress, 0, nil, &nominalSize, &nominal)
            rate = nominal > 0 ? nominal : 48_000
            channels = 2
        }

        let channels = channels
        let rate = rate
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { [weak self] _, input, _, _, _ in
            self?.deliver(input, tapChannels: channels, rate: rate)
        }
        guard status == noErr, procID != nil else {
            close()
            throw Failure(description: "Couldn't read the tap (\(status)).")
        }
        status = AudioDeviceStart(device, procID)
        guard status == noErr else {
            close()
            throw Failure(description: "Couldn't start reading the tap (\(status)).")
        }
    }

    private func close() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapDescription = nil
        processes = []
    }

    /// Rebuilds the tap on the new output device. A failure leaves the tap closed: the call
    /// goes on with the microphone alone rather than stopping.
    private func reopen() {
        lock.withLockUnchecked {
            guard hasHandler else { return }
            close()
            try? open()
        }
    }

    /// Adds the app's processes that started since, and drops the ones that ended.
    private func refreshProcesses() {
        lock.withLockUnchecked {
            guard hasHandler, tapID != kAudioObjectUnknown, let description = tapDescription else { return }
            let now = TapProcesses.objects(forBundleID: target.bundleID)
            guard !now.isEmpty, now != processes else { return }
            description.processes = now
            var address = Self.address(kAudioTapPropertyDescription)
            var value: Unmanaged<CATapDescription> = Unmanaged.passUnretained(description)
            let status = AudioObjectSetPropertyData(tapID, &address, 0, nil,
                                                    UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size), &value)
            if status == noErr { processes = now }
        }
    }

    private func deliver(_ input: UnsafePointer<AudioBufferList>, tapChannels: Int, rate: Double) {
        guard let handler = handlerLock.withLockUnchecked({ self.handler }) else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let mono = TapChannels.mono(of: list, tapChannels: tapChannels) else { return }
        mono.withUnsafeBufferPointer { handler($0, rate) }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// Picks the tap's channels out of what its aggregate device delivers.
enum TapChannels {
    /// The tap's stream comes after any streams of the device that clocks it, so a headset
    /// whose microphone is part of that device would otherwise be taken for the app. The
    /// last `tapChannels` channels are the tap's, averaged to one.
    static func mono(of list: UnsafeMutableAudioBufferListPointer, tapChannels: Int) -> [Float]? {
        var columns: [(data: UnsafePointer<Float>, stride: Int)] = []
        var frames = Int.max
        for buffer in list {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = max(1, Int(buffer.mNumberChannels))
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * count))
            for c in 0..<count { columns.append((UnsafePointer(data + c), count)) }
        }
        guard !columns.isEmpty, frames > 0, frames != Int.max else { return nil }
        let own = columns.suffix(max(1, min(tapChannels, columns.count)))
        var out = [Float](repeating: 0, count: frames)
        for column in own {
            for f in 0..<frames { out[f] += column.data[f * column.stride] }
        }
        let scale = 1 / Float(own.count)
        for f in 0..<frames { out[f] *= scale }
        return out
    }
}

/// The audio processes that belong to an app.
public enum TapProcesses {
    /// Every Core Audio process object of the app and its helpers, whether or not it is
    /// making sound this second, so a tap made between two words of a call still has them.
    /// Dictate's own processes are never included.
    public static func objects(forBundleID bundleID: String) -> [AudioObjectID] {
        let own = getpid()
        return CallApps.objects().filter { object in
            var pid: pid_t = -1
            var size = UInt32(MemoryLayout<pid_t>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid)
            guard pid != own else { return false }
            let id = CallApps.string(object, kAudioProcessPropertyBundleID) ?? ""
            if belongs(id, to: bundleID) { return true }
            guard pid > 0, let owner = NSRunningApplication(processIdentifier: CallApps.responsible(pid))?.bundleIdentifier
            else { return false }
            return belongs(owner, to: bundleID)
        }
        .sorted()
    }

    /// The app itself or one of its helpers ("com.google.Chrome.helper").
    static func belongs(_ id: String, to bundleID: String) -> Bool {
        id == bundleID || id.hasPrefix(bundleID + ".")
    }
}

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

/// One app's loudness, for a picker that shows it is heard. It taps the app only while
/// asked, and only when the permission is already given, so looking at a list never shows
/// a permission question.
public final class AppLevelMeter: @unchecked Sendable {
    private let tap: ProcessTap
    private let lock = OSAllocatedUnfairLock()
    private var peak: Float = 0

    public init(_ target: CallTapTarget) {
        tap = ProcessTap(target)
    }

    /// False when the app can't be tapped.
    public func start() -> Bool {
        do {
            try tap.start { [weak self] samples, _ in
                var loudest: Float = 0
                for s in samples { loudest = max(loudest, abs(s)) }
                guard let self else { return }
                self.lock.withLockUnchecked { self.peak = max(self.peak, loudest) }
            }
            return true
        } catch {
            return false
        }
    }

    /// The loudest sample since the last read, 0 to 1.
    public func read() -> Float {
        lock.withLockUnchecked {
            defer { peak = 0 }
            return peak
        }
    }

    public func stop() { tap.stop() }
}
