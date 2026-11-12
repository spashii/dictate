import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import VoiceCore

@Suite struct CallJoinTests {
    @Test func pairsTheSidesInOrderWhateverTheChunkSizes() {
        var joiner = StereoJoiner(rate: 1000)
        #expect(joiner.appendMe([1, 2, 3]) == nil)
        let first = joiner.appendCall([10, 20])
        #expect(first?.me == [1, 2] && first?.call == [10, 20])
        let second = joiner.appendCall([30, 40])
        #expect(second?.me == [3] && second?.call == [30])
        #expect(joiner.call == [40])
    }

    @Test func aSideThatStallsIsPaddedWithSilenceAfterTheSkewLimit() {
        var joiner = StereoJoiner(rate: 100, maxSkew: 0.5)
        _ = joiner.appendMe(Array(repeating: 1, count: 50))
        #expect(joiner.call.isEmpty && joiner.me.count == 50)
        let pair = joiner.appendMe([1])
        #expect(pair?.me.count == 51)
        #expect(pair?.call == Array(repeating: 0, count: 51))
    }

    @Test func aCallSideAheadOfMeIsPaddedToo() {
        var joiner = StereoJoiner(rate: 100, maxSkew: 0.5)
        let pair = joiner.appendCall(Array(repeating: 1, count: 60))
        #expect(pair?.me == Array(repeating: 0, count: 60))
    }

    @Test func flushPadsTheShorterSide() {
        var joiner = StereoJoiner(rate: 1000)
        _ = joiner.appendMe([1, 2, 3])
        let tail = joiner.flush()
        #expect(tail?.me == [1, 2, 3] && tail?.call == [0, 0, 0])
        #expect(joiner.flush() == nil)
    }

    @Test func theJoinWritesMeLeftAndTheCallRightAtTheMicrophonesRate() {
        let join = CallJoin(rate: 48_000)
        let got = LockedBuffers()
        join.setSink { got.add($0) }
        join.pushMe(Array(repeating: 0.25, count: 480))
        var call = [Float](repeating: 0.5, count: 480)
        call.withUnsafeMutableBufferPointer { join.pushCall(UnsafeBufferPointer($0), rate: 48_000) }
        let buffers = got.all
        #expect(buffers.count == 1)
        #expect(buffers[0].format.channelCount == 2 && buffers[0].frameLength == 480)
        #expect(buffers[0].floatChannelData![0][0] == 0.25 && buffers[0].floatChannelData![1][0] == 0.5)
    }

    @Test func aCallAtAnotherRateIsConvertedToTheMicrophonesRate() {
        let join = CallJoin(rate: 48_000)
        let got = LockedBuffers()
        join.setSink { got.add($0) }
        join.pushMe(Array(repeating: 0, count: 4800))
        var call = [Float](repeating: 0.5, count: 1600)
        call.withUnsafeMutableBufferPointer { join.pushCall(UnsafeBufferPointer($0), rate: 16_000) }
        join.flush()
        let frames = got.all.reduce(0) { $0 + Int($1.frameLength) }
        #expect(frames == 4800)
        #expect(got.all.first.map { $0.floatChannelData![1][0] } != nil)
    }

    @Test func whatArrivesBeforeTheSinkWaitsForIt() {
        let join = CallJoin(rate: 48_000)
        join.pushMe(Array(repeating: 0.1, count: 100))
        var call = [Float](repeating: 0.2, count: 100)
        call.withUnsafeMutableBufferPointer { join.pushCall(UnsafeBufferPointer($0), rate: 48_000) }
        let got = LockedBuffers()
        join.setSink { got.add($0) }
        #expect(got.all.reduce(0) { $0 + Int($1.frameLength) } == 100)
    }
}

@Suite struct TapChannelsTests {
    private func mono(channels: [[Float]], interleavedInOne: Bool, tapChannels: Int) -> [Float]? {
        let frames = channels[0].count
        let list = AudioBufferList.allocate(maximumBuffers: interleavedInOne ? 1 : channels.count)
        defer { list.unsafeMutablePointer.deallocate() }
        var storage: [UnsafeMutablePointer<Float>] = []
        defer { storage.forEach { $0.deallocate() } }
        if interleavedInOne {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels.count)
            for f in 0..<frames { for c in 0..<channels.count { data[f * channels.count + c] = channels[c][f] } }
            storage.append(data)
            list[0] = AudioBuffer(mNumberChannels: UInt32(channels.count),
                                  mDataByteSize: UInt32(frames * channels.count * 4), mData: data)
        } else {
            for (i, channel) in channels.enumerated() {
                let data = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                data.update(from: channel, count: frames)
                storage.append(data)
                list[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: data)
            }
        }
        return TapChannels.mono(of: list, tapChannels: tapChannels)
    }

    @Test func averagesTheTapsTwoChannels() {
        #expect(mono(channels: [[1, 1], [3, 5]], interleavedInOne: true, tapChannels: 2) == [2, 3])
        #expect(mono(channels: [[1, 1], [3, 5]], interleavedInOne: false, tapChannels: 2) == [2, 3])
    }

    @Test func takesTheLastChannelsSoAHeadsetMicrophoneIsNeverTheApp() {
        // A clocking device with a one-channel microphone first, then the tap's stereo.
        #expect(mono(channels: [[9, 9], [1, 1], [3, 5]], interleavedInOne: false, tapChannels: 2) == [2, 3])
        #expect(mono(channels: [[9, 9], [1, 1], [3, 5]], interleavedInOne: true, tapChannels: 2) == [2, 3])
    }

    @Test func aMonoTapIsUsedAsIs() {
        #expect(mono(channels: [[0.5, 0.25]], interleavedInOne: false, tapChannels: 1) == [0.5, 0.25])
    }

    @Test func belongsMatchesTheAppAndItsHelpersOnly() {
        #expect(TapProcesses.belongs("com.google.Chrome", to: "com.google.Chrome"))
        #expect(TapProcesses.belongs("com.google.Chrome.helper.Renderer", to: "com.google.Chrome"))
        #expect(!TapProcesses.belongs("com.google.ChromeRemote", to: "com.google.Chrome"))
        #expect(!TapProcesses.belongs("com.google.Chrome.beta", to: "com.google.Chrome.dev"))
    }
}

private final class LockedBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    func add(_ buffer: AVAudioPCMBuffer) { lock.withLock { buffers.append(buffer) } }
    var all: [AVAudioPCMBuffer] { lock.withLock { buffers } }
}
