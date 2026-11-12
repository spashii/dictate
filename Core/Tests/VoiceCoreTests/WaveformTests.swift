import AVFoundation
import Foundation
import Testing
@testable import VoiceCore

@Suite struct WaveformTests {
    /// A mono wav of `seconds`, quiet except between `loud`.
    private func wav(seconds: Int, loud: ClosedRange<Double>, channels: AVAudioChannelCount = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "wave-\(UUID().uuidString).wav")
        let rate = 16_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(Double(seconds) * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                let t = Double(frame) / rate
                buffer.floatChannelData![channel][frame] = loud.contains(t) ? 0.8 : 0.05
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test func theLoudStretchStandsOutAndTheLoudestPointIsOne() throws {
        let url = try wav(seconds: 10, loud: 4...6)
        defer { try? FileManager.default.removeItem(at: url) }
        let peaks = try Waveform.peaks(of: url, count: 10)
        #expect(peaks.count == 10)
        #expect(peaks.max() == 1)
        #expect(peaks[4] == 1 && peaks[5] == 1)
        #expect(peaks[0] < 0.1 && peaks[9] < 0.1)
    }

    @Test func everyChannelCounts() throws {
        let url = try wav(seconds: 4, loud: 2...3, channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let peaks = try Waveform.peaks(of: url, count: 4)
        #expect(peaks[2] == 1)
    }

    @Test func aMissingFileThrows() {
        #expect(throws: (any Error).self) { try Waveform.peaks(of: URL(fileURLWithPath: "/nonexistent.wav"), count: 4) }
    }
}
