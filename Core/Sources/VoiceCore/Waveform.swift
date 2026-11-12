import AVFoundation
import Foundation

/// The loudness of a recording at `count` evenly spaced points, for the scrubber under History.
public enum Waveform {
    /// Each point is the loudest sample in its stretch, over every channel, scaled so the loudest
    /// point of the recording is 1. Silence gives all zeros. Reads the file once, in chunks, and
    /// looks at every eighth frame, which is plenty to draw a bar from.
    public static func peaks(of url: URL, count: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frames = Int(file.length)
        guard count > 0, frames > 0 else { return [Float](repeating: 0, count: max(0, count)) }
        let perPoint = Double(frames) / Double(count)
        let chunk = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk)) else {
            throw VoiceError.audio("Can't read \(url.lastPathComponent).")
        }
        var peaks = [Float](repeating: 0, count: count)
        var position = 0
        while position < frames {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(chunk, frames - position)))
            let read = Int(buffer.frameLength)
            guard read > 0, let channels = buffer.floatChannelData else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = channels[channel]
                var frame = 0
                while frame < read {
                    let point = min(count - 1, Int(Double(position + frame) / perPoint))
                    let value = abs(samples[frame])
                    if value > peaks[point] { peaks[point] = value }
                    frame += 8
                }
            }
            position += read
        }
        let loudest = peaks.max() ?? 0
        return loudest > 0 ? peaks.map { $0 / loudest } : peaks
    }
}
