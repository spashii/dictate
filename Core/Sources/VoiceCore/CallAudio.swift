import AVFoundation
import Foundation

/// How a call's audio is kept. While the call records it is a WAV, which stays readable
/// however the app ends. Once the transcript is complete nothing needs that any more, and
/// an hour of 48 kHz stereo is about 690 MB, so the WAV is replaced by AAC at about a
/// sixteenth of the size: speech stays clear, and a recording habit can't fill a disk.
public enum CallAudio {
    /// 96 kbps for stereo, 48 for a mixed-down call.
    public static let bitRatePerChannel = 48_000
    /// How far the AAC's length may differ from the WAV's before it is not trusted as the
    /// same recording.
    public static let durationTolerance: TimeInterval = 0.5

    public static func isWAV(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "wav"
    }

    /// Writes the WAV as an .m4a beside it, at its own sample rate and channel count, and
    /// opens the result to check it. Returns the .m4a. On any failure nothing is left
    /// behind but the WAV, which this never changes.
    ///
    /// Reads and writes the whole file, so call it off the main thread.
    ///
    /// `stereoAtMost` is for an imported file, which can have any number of channels: one with
    /// more is kept as two (the even channels averaged to the left, the odd to the right), since
    /// the encoder takes no such layout, and one above 48 kHz is brought down to it, since a file the
    /// encoder refuses would be tried again at every launch.
    public static func encode(_ wav: URL, stereoAtMost: Bool = false) throws -> URL {
        let output = wav.deletingPathExtension().appendingPathExtension("m4a")
        // Whatever is here is what an earlier attempt left when the app quit mid-write; the
        // call's path still names the WAV, so nothing refers to it.
        try? FileManager.default.removeItem(at: output)
        do {
            let source = try write(wav, to: output, stereoAtMost: stereoAtMost)
            try verify(output, against: source)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    /// What the WAV has, which the AAC has to match.
    struct Source {
        let seconds: Double
        let channels: AVAudioChannelCount
        let sampleRate: Double
    }

    /// The encoder refuses 96 kbps and up at 96 kHz, so an import above this is brought down.
    static let importSampleRate = 48_000.0

    private static func write(_ wav: URL, to output: URL, stereoAtMost: Bool) throws -> Source {
        let input = try AVAudioFile(forReading: wav)
        let format = input.processingFormat
        guard input.length > 0 else { throw VoiceError.audio("The WAV holds no audio.") }
        let channels = stereoAtMost ? min(Int(format.channelCount), 2) : Int(format.channelCount)
        let rate = stereoAtMost ? min(format.sampleRate, importSampleRate) : format.sampleRate
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRatePerChannel * channels,
        ]
        let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let reduced = Int(format.channelCount) > channels || rate != format.sampleRate
        let mixFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: AVAudioChannelCount(channels))!
        let converter = rate == format.sampleRate ? nil : AVAudioConverter(from: mixFormat, to: file.processingFormat)
        let step = AVAudioFrameCount(format.sampleRate)
        while input.framePosition < input.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: step) else {
                throw VoiceError.audio("Out of memory while converting the call's audio.")
            }
            try input.read(into: buffer, frameCount: step)
            guard buffer.frameLength > 0 else { break }
            guard reduced else {
                try file.write(from: buffer)
                continue
            }
            guard let mixed = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: buffer.frameLength),
                  let from = buffer.floatChannelData, let to = mixed.floatChannelData else {
                throw VoiceError.audio("Out of memory while converting the call's audio.")
            }
            mixed.frameLength = buffer.frameLength
            let count = Int(format.channelCount)
            for side in 0..<channels {
                let members = Array(stride(from: side, to: count, by: channels))
                for frame in 0..<Int(buffer.frameLength) {
                    to[side][frame] = members.reduce(Float(0)) { $0 + from[$1][frame] } / Float(members.count)
                }
            }
            guard let converter else {
                try file.write(from: mixed)
                continue
            }
            let capacity = AVAudioFrameCount(Double(mixed.frameLength) * rate / format.sampleRate) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                throw VoiceError.audio("Out of memory while converting the call's audio.")
            }
            let feed = OneShot(mixed, ends: false)
            var failure: NSError?
            converter.convert(to: converted, error: &failure) { _, status in feed.next(status) }
            if let failure { throw failure }
            if converted.frameLength > 0 { try file.write(from: converted) }
        }
        // The encoder writes its last packets and the file's index when it closes.
        file.close()
        return Source(seconds: Double(input.length) / format.sampleRate, channels: AVAudioChannelCount(channels),
                      sampleRate: rate)
    }

    static func verify(_ output: URL, against source: Source) throws {
        let encoded = try AVAudioFile(forReading: output)
        let format = encoded.processingFormat
        guard format.channelCount == source.channels, format.sampleRate == source.sampleRate else {
            throw VoiceError.audio("The AAC has \(format.channelCount) channels at \(Int(format.sampleRate)) Hz, "
                                   + "not \(source.channels) at \(Int(source.sampleRate)).")
        }
        let seconds = Double(encoded.length) / format.sampleRate
        guard abs(seconds - source.seconds) <= durationTolerance else {
            throw VoiceError.audio("The AAC runs \(seconds) s and the WAV \(source.seconds) s.")
        }
        // A file can open and report a length without its audio decoding.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return }
        try encoded.read(into: buffer, frameCount: 4096)
        guard buffer.frameLength > 0 else { throw VoiceError.audio("The AAC doesn't decode.") }
    }
}
