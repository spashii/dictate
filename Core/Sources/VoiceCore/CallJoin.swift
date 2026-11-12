import AVFoundation
import Foundation
import os

/// Pairs the microphone's samples with the tapped app's, which arrive from two clocks in
/// pieces of different sizes, into the two-channel stream a call is written and
/// transcribed from: me on the left, the call on the right.
///
/// Both sides are at one rate. A side that has delivered nothing for `maxSkew` while the
/// other has is taken to be silent (the app isn't playing, or its tap is being rebuilt) and
/// is padded with zeros, so one stalled side never holds the other's audio back.
struct StereoJoiner {
    private(set) var me: [Float] = []
    private(set) var call: [Float] = []
    let maxSkew: Int

    init(rate: Double, maxSkew: TimeInterval = 0.5) {
        self.maxSkew = Int(rate * maxSkew)
    }

    mutating func appendMe(_ samples: [Float]) -> (me: [Float], call: [Float])? {
        me += samples
        return take()
    }

    mutating func appendCall(_ samples: [Float]) -> (me: [Float], call: [Float])? {
        call += samples
        return take()
    }

    /// What is left at the end of a call, the shorter side padded.
    mutating func flush() -> (me: [Float], call: [Float])? {
        let frames = max(me.count, call.count)
        guard frames > 0 else { return nil }
        pad(to: frames)
        return take()
    }

    private mutating func take() -> (me: [Float], call: [Float])? {
        if me.count - call.count > maxSkew { pad(to: me.count) }
        if call.count - me.count > maxSkew { pad(to: call.count) }
        let frames = min(me.count, call.count)
        guard frames > 0 else { return nil }
        defer {
            me.removeFirst(frames)
            call.removeFirst(frames)
        }
        return (Array(me.prefix(frames)), Array(call.prefix(frames)))
    }

    private mutating func pad(to frames: Int) {
        if me.count < frames { me += [Float](repeating: 0, count: frames - me.count) }
        if call.count < frames { call += [Float](repeating: 0, count: frames - call.count) }
    }
}

/// Feeds a `StereoJoiner`'s pairs to a call's session as two-channel buffers. Either side
/// may push from its own thread.
final class CallJoin: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var joiner: StereoJoiner
    private let format: AVAudioFormat
    private var sink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var pending: [(me: [Float], call: [Float])] = []
    private var callConverter: AVAudioConverter?
    private var callRate = 0.0
    private let mono: AVAudioFormat

    /// `rate` is the microphone's, which is the rate the call is written at.
    init(rate: Double) {
        joiner = StereoJoiner(rate: rate)
        format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    }

    /// Nothing is written until a sink is set; what arrives before waits for it.
    func setSink(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        lock.withLockUnchecked {
            self.sink = sink
            let waiting = pending
            pending = []
            for pair in waiting { emit(pair) }
        }
    }

    func pushMe(_ samples: [Float]) {
        lock.withLockUnchecked {
            if let pair = joiner.appendMe(samples) { emit(pair) }
        }
    }

    func pushCall(_ samples: UnsafeBufferPointer<Float>, rate: Double) {
        let converted = resample(Array(samples), from: rate)
        lock.withLockUnchecked {
            if let pair = joiner.appendCall(converted) { emit(pair) }
        }
    }

    func flush() {
        lock.withLockUnchecked {
            if let pair = joiner.flush() { emit(pair) }
        }
    }

    /// Held until a sink exists, so the first words of a call aren't dropped.
    private func emit(_ pair: (me: [Float], call: [Float])) {
        guard let sink else {
            pending.append(pair)
            return
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pair.me.count)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(pair.me.count)
        pair.me.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: pair.me.count) }
        pair.call.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: pair.call.count) }
        sink(buffer)
    }

    private func resample(_ samples: [Float], from rate: Double) -> [Float] {
        guard !samples.isEmpty else { return samples }
        if abs(rate - format.sampleRate) < 1 { return samples }
        if callConverter == nil || callRate != rate {
            guard let input = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return [] }
            callConverter = AVAudioConverter(from: input, to: mono)
            callRate = rate
        }
        guard let converter = callConverter,
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity:
                                                AVAudioFrameCount(Double(samples.count) * format.sampleRate / rate) + 64)
        else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let feed = OneShot(input, ends: false)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in feed.next(status) }
        guard error == nil, output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
