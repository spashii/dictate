import AVFoundation
import Foundation
import Testing
@testable import VoiceCore

private let words = "Northwind budget review with Alex"

/// One segment with fixed words per chunk, so a test reads the import path without a model.
private struct FakeTranscriber: ChunkTranscribing {
    var text = words
    var delay: Duration = .zero

    func transcribe(_ samples: [Float], options: WhisperOptions) async throws -> Transcript {
        if delay > .zero { try await Task.sleep(for: delay) }
        let segment = Segment(t0: 0, t1: 1, text: text, avgLogprob: -0.2, noSpeechProb: 0.01, compressionRatio: 1.1,
                              speechSeconds: 1, wordsPerSecond: 3)
        return Transcript(text: text, segments: [segment], seconds: 0.01)
    }
}

private struct FakeTitle: TitleModel {
    let name = "fake"
    func title(instructions: String, prompt: String) async throws -> String { "Northwind rollout plan" }
}

private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Double] = []
    func add(_ value: Double) { lock.lock(); seen.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return seen }
}

/// A folder for one test: sources in `source`, and the recorder's own `calls` folder.
private struct Workspace {
    let root: URL
    let source: URL
    let calls: URL
    let store: CallStore
    let recorder: CallRecorder

    init() throws {
        root = realPath(FileManager.default.temporaryDirectory)
            .appending(path: "ImportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        source = root.appending(path: "source", directoryHint: .isDirectory)
        calls = root.appending(path: "calls", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        store = try CallStore(url: root.appending(path: "voice.sqlite"))
        recorder = CallRecorder(store: store, directory: calls)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    var stored: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: calls.path)) ?? []).sorted()
    }

    /// Imports a file the way the app does, and returns the finished call.
    func importFile(_ file: URL, transcriber: any ChunkTranscribing = FakeTranscriber(),
                    onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Call {
        let start = try await recorder.beginImport(file, at: Date(timeIntervalSince1970: 1_800_000_000))
        let call = await recorder.transcribeImport(start.call.id, transcriber: transcriber, onProgress: onProgress)
        await recorder.waitForCompression()
        return try #require(try store.call(call?.id ?? start.call.id))
    }
}

/// Two seconds of tone and one of silence at 16 kHz, or `bursts` of one second and one of silence.
private func writeTone(to url: URL, bursts: Int? = nil) throws {
    let ext = url.pathExtension
    if ext == "m4a" {
        let wav = url.deletingPathExtension().appendingPathExtension("wav")
        try writeTone(to: wav)
        // Encodes beside the WAV under the same name, which is the file asked for.
        _ = try CallAudio.encode(wav)
        try FileManager.default.removeItem(at: wav)
        return
    }
    let rate = 16_000.0
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: ext == "aiff" || ext == "aifc",
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = bursts.map { $0 * 2 * 16_000 } ?? 3 * 16_000
    let toneFrames = bursts == nil ? 2 * 16_000 : 16_000
    let period = bursts == nil ? 3 * 16_000 : 2 * 16_000
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames {
        buffer.floatChannelData![0][i] = i % period < toneFrames ? Float(sin(2 * .pi * 440 * Double(i) / rate) * 0.5) : 0
    }
    try file.write(from: buffer)
}

private func fixture(_ name: String, in dir: URL) throws -> URL {
    let from = try #require(Bundle.module.url(forResource: "tone", withExtension: name, subdirectory: "Fixtures"))
    let to = dir.appending(path: "Standup recording.\(name)")
    try FileManager.default.copyItem(at: from, to: to)
    return to
}

private func source(_ type: String, in dir: URL) throws -> URL {
    if ["mp3", "mp4", "mov", "m4v", "flac", "aac", "m4b"].contains(type) { return try fixture(type, in: dir) }
    let url = dir.appending(path: "Standup recording.\(type)")
    try writeTone(to: url)
    return url
}

@Suite struct AudioImportTests {
    /// The extension of the copy the call keeps: a WAV is compressed once it is transcribed,
    /// and video keeps its audio only.
    private func expectedExtension(_ type: String) -> String {
        ["wav", "mp4", "mov", "m4v"].contains(type) ? "m4a" : type
    }

    @Test(arguments: ["wav", "aiff", "aifc", "caf", "m4a", "mp3", "aac", "flac", "m4b", "mp4", "mov", "m4v"])
    func importsEachSupportedTypeAsOneTrack(type: String) async throws {
        let work = try Workspace()
        defer { work.remove() }
        let file = try source(type, in: work.source)

        let call = try await work.importFile(file)

        #expect(call.status == .done)
        #expect(call.error == nil)
        #expect(call.fileName == "Standup recording.\(type)")
        #expect(call.split == false)
        let segments = try work.store.segments(call.id)
        #expect(!segments.isEmpty)
        #expect(segments.allSatisfy { $0.channel == .mix && $0.text == words })
        let path = try #require(call.audioPath)
        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().path == work.calls.path)
        #expect(URL(fileURLWithPath: path).pathExtension == expectedExtension(type))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(work.stored.count == 1)
        let length = try #require(call.endedAt).timeIntervalSince(call.startedAt)
        #expect(abs(length - 3) < 0.3)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aCorruptFileFailsWithItsReasonAndLeavesNothingBehind() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let file = work.source.appending(path: "broken.m4a")
        try Data("not audio at all".utf8).write(to: file)

        let start = try await work.recorder.beginImport(file)
        let waiting = try #require(try work.store.historyEntries().first)
        #expect(waiting.isLive && waiting.fileName == "broken.m4a" && waiting.kindLabel == "broken.m4a")

        let call = await work.recorder.transcribeImport(start.call.id, transcriber: FakeTranscriber())

        #expect(call?.status == .failed)
        #expect(call?.error == "This file has no audio Dictate can read.")
        #expect(call?.audioPath == nil)
        #expect(work.stored.isEmpty)
        let entry = try #require(try work.store.historyEntries().first)
        #expect(!entry.isLive && entry.error == "This file has no audio Dictate can read.")
    }

    @Test func theOriginalCanGoOnceTheRowExists() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let file = try source("wav", in: work.source)
        let start = try await work.recorder.beginImport(file)
        try FileManager.default.removeItem(at: file)

        #expect(start.call.audioPath.map { FileManager.default.fileExists(atPath: $0) } == true)
        let call = await work.recorder.transcribeImport(start.call.id, transcriber: FakeTranscriber())

        #expect(call?.status == .done)
        #expect(work.stored.count == 1)
        #expect(work.stored.allSatisfy { !$0.hasSuffix(".partial") })
    }

    @Test func aDuplicateKeepsNoCopy() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let file = try source("wav", in: work.source)
        _ = try await work.importFile(file)
        let before = work.stored

        let again = try await work.recorder.beginImport(file)

        #expect(again.duplicate)
        #expect(work.stored == before)
    }

    @Test func twoImportsOfOneFileAtOnceMakeOneRow() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let file = try source("wav", in: work.source)

        async let one = work.recorder.beginImport(file)
        async let two = work.recorder.beginImport(file)
        let starts = try await [one, two]

        #expect(starts.filter(\.duplicate).count == 1)
        #expect(try work.store.calls(limit: 10).count == 1)
        #expect(work.stored.count == 1)
    }

    @Test func sweepingRemovesHalfWrittenCopiesOnly() async throws {
        let work = try Workspace()
        defer { work.remove() }
        _ = try await work.importFile(try source("wav", in: work.source))
        let partial = work.calls.appending(path: "1-abcd1234.m4a.partial")
        try Data([1]).write(to: partial)

        work.recorder.sweepPartials()

        #expect(work.stored.count == 1 && work.stored.allSatisfy { !$0.hasSuffix(".partial") })
    }

    @Test func aSixChannelFileAt96kHzIsTranscribedAsOneMixAndKept() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let file = work.source.appending(path: "Surround.wav")
        try writeAudio(to: file, sampleRate: 96_000, channels: 6, frames: 96_000 * 3,
                       sample: { _, i in i < 192_000 ? sine(440, rate: 96_000)(0, i) : 0 })

        let call = try await work.importFile(file)

        #expect(call.status == .done)
        #expect(try work.store.segments(call.id).allSatisfy { $0.channel == .mix })
        #expect(try !work.store.segments(call.id).isEmpty)
        let path = try #require(call.audioPath)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(URL(fileURLWithPath: path).pathExtension == "m4a")
        // A launch has nothing left to retry.
        #expect(try work.store.callsAwaitingCompression().isEmpty)
    }

    @Test func cancellingLeavesTheRowTranscribingWithItsCopyAndNoPartials() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let file = work.source.appending(path: "long.wav")
        try writeTone(to: file, bursts: 12)
        let start = try await work.recorder.beginImport(file)
        let task = Task { await work.recorder.transcribeImport(start.call.id, transcriber: FakeTranscriber(delay: .milliseconds(200))) }
        try await Task.sleep(for: .milliseconds(600))
        task.cancel()
        let call = await task.value

        #expect(call?.status == .transcribing)
        #expect(work.stored.count == 1 && work.stored.allSatisfy { !$0.hasSuffix(".partial") })
        #expect(call?.audioPath.map { FileManager.default.fileExists(atPath: $0) } == true)
    }

    @Test(arguments: ["mov", "m4v"])
    func cancellingWhileVideoAudioIsExportedKeepsTheCopyAndALaterRunFinishes(type: String) async throws {
        let work = try Workspace()
        defer { work.remove() }
        let start = try await work.recorder.beginImport(try fixture(type, in: work.source))
        let copy = try #require(start.call.audioPath)
        let task = Task { await work.recorder.transcribeImport(start.call.id, transcriber: FakeTranscriber()) }
        task.cancel()
        let cancelled = await task.value

        #expect(cancelled?.status == .transcribing)
        #expect(cancelled?.error == nil)
        #expect(cancelled?.audioPath == copy)
        #expect(FileManager.default.fileExists(atPath: copy))
        #expect(work.stored.allSatisfy { !$0.hasSuffix(".partial") })

        let again = await work.recorder.transcribeImport(start.call.id, transcriber: FakeTranscriber())
        #expect(again?.status == .done)
        #expect(try !work.store.segments(start.call.id).isEmpty)
    }

    @Test func theRawVideoCopyGoesOnlyOnceTheCallNamesTheAudio() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let start = try await work.recorder.beginImport(try fixture("mov", in: work.source))
        let raw = try #require(start.call.audioPath)
        let call = try #require(await work.recorder.transcribeImport(start.call.id, transcriber: FakeTranscriber()))

        #expect(call.audioPath != raw)
        #expect(!FileManager.default.fileExists(atPath: raw))
        #expect(call.audioPath.map { FileManager.default.fileExists(atPath: $0) } == true)
    }

    @Test func theRowNamesTheFinalPathAndNoPartialRemainsOnceStarted() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let file = try source("wav", in: work.source)
        let start = try await work.recorder.beginImport(file)

        #expect(work.stored == [URL(fileURLWithPath: try #require(start.call.audioPath)).lastPathComponent])
        let again = try await work.recorder.beginImport(file)
        #expect(again.duplicate)
        #expect(work.stored.allSatisfy { !$0.hasSuffix(".partial") })
    }

    @Test func moreThanTwoChannelsAreHeardInBothEars() throws {
        let work = try Workspace()
        defer { work.remove() }
        let wav = work.source.appending(path: "Surround.wav")
        // Dialogue on the centre channel only: the first and second channels are silent.
        try writeAudio(to: wav, sampleRate: 16_000, channels: 3, frames: 32_000,
                       sample: { channel, i in channel == 2 ? sine(440, rate: 16_000, amplitude: 0.6)(0, i) : 0 })

        let m4a = try CallAudio.encode(wav, stereoAtMost: true)

        let encoded = try AVAudioFile(forReading: m4a)
        #expect(encoded.processingFormat.channelCount == 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: encoded.processingFormat, frameCapacity: 16_000)!
        try encoded.read(into: buffer, frameCount: 16_000)
        let left = rms(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))[...])
        let right = rms(Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength)))[...])
        #expect(left > 0.05 && right > 0.05)
        #expect(abs(left - right) < 0.02)
    }

    @Test func aCancelledImportIsReadAgainWithoutRepeatingItsWords() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let file = work.source.appending(path: "long.wav")
        try writeTone(to: file, bursts: 12)
        let start = try await work.recorder.beginImport(file)
        let task = Task { await work.recorder.transcribeImport(start.call.id, transcriber: FakeTranscriber(delay: .milliseconds(200))) }
        try await Task.sleep(for: .milliseconds(600))
        task.cancel()
        _ = await task.value
        let again = await work.recorder.transcribeImport(start.call.id, transcriber: FakeTranscriber())

        #expect(again?.status == .done)
        #expect(try work.store.segments(start.call.id).count == 12)
    }

    @Test func aQuitImportIsRebuiltFromItsCopyWithBackPressure() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let file = work.source.appending(path: "long.wav")
        try writeTone(to: file, bursts: 12)
        let start = try await work.recorder.beginImport(file)
        let progress = Progress()

        let call = try await work.recorder.rebuild(start.call.id, transcriber: FakeTranscriber(delay: .milliseconds(150)),
                                                   onProgress: progress.add)
        await work.recorder.waitForCompression()

        #expect(call.status == .done)
        #expect(try work.store.segments(call.id).count == 12)
        #expect(try work.store.segments(call.id).allSatisfy { $0.channel == .mix })
        #expect(work.recorder.importHighWater <= CallSession.maxQueued + 1)
        #expect(try #require(progress.values.last) > 0.5)
    }

    @Test func anImportDoesNotCountAsTheCurrentCall() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let recording = try work.store.createCall(NewCall(split: true))
        _ = try await work.recorder.beginImport(try source("wav", in: work.source),
                                                at: Date().addingTimeInterval(60))

        #expect(try work.store.currentCall()?.id == recording.id)
        let batch = try await work.store.waitForSegments(nil, after: 0, timeout: .milliseconds(100))
        #expect(batch.call?.id == recording.id)
    }

    @Test func aLiveImportCantBeDeletedAndSaysWhy() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let start = try await work.recorder.beginImport(try source("wav", in: work.source))

        #expect(throws: VoiceError.self) { try work.store.deleteRecording(.call, start.call.id) }
        do {
            try work.store.deleteRecording(.call, start.call.id)
        } catch {
            #expect("\(error)".contains("Wait for the import to finish or stop it before deleting it."))
        }
    }

    @Test func theSameFileIsImportedOnce() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let file = try source("wav", in: work.source)
        let copy = work.source.appending(path: "Another name.wav")
        try FileManager.default.copyItem(at: file, to: copy)

        let first = try await work.importFile(file)
        let again = try await work.recorder.beginImport(copy)

        #expect(again.duplicate)
        #expect(again.call.id == first.id)
        #expect(try work.store.calls(limit: 10).count == 1)
    }

    @Test func aFailedImportDoesNotBlockTheSameFile() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let file = work.source.appending(path: "broken.m4a")
        try Data("not audio at all".utf8).write(to: file)

        let failed = try await work.importFile(file)
        #expect(failed.status == .failed)
        let again = try await work.recorder.beginImport(file)

        #expect(!again.duplicate)
        #expect(again.call.id != failed.id)
        #expect(try work.store.calls(limit: 10).count == 2)
    }

    @Test func anImportIsFoundBySearchAndInTheHistory() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let call = try await work.importFile(try source("wav", in: work.source))

        let hit = try #require(try work.store.search("Northwind").first)
        #expect(hit.kind == .call && hit.id == call.id)
        let entries = try work.store.historyEntries(matching: "budget")
        #expect(entries.map(\.ref) == [call.id])
        #expect(entries.first?.fileName == "Standup recording.wav")
        #expect(entries.first?.kind == .call)
        #expect(try work.store.historyEntries(matching: "recording").map(\.ref) == [call.id])
        #expect(try work.store.historyEntries(matching: "zebra").isEmpty)
    }

    @Test func aSilentImportStaysInTheHistory() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let file = work.source.appending(path: "quiet.wav")
        try writeAudio(to: file, sampleRate: 16_000, channels: 1, frames: 32_000, sample: { _, _ in 0 })

        let call = try await work.importFile(file)

        #expect(call.status == .done)
        #expect(try work.store.historyEntries().map(\.ref) == [call.id])
    }

    @Test func aFinishedImportCanBeTitled() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let long = FakeTranscriber(text: "We should plan the Northwind rollout with Alex before the end of the month.")
        let call = try await work.importFile(try source("wav", in: work.source), transcriber: long)
        let titler = CallTitler()

        #expect(titler.isEligible(call.id, in: work.store))
        #expect(await titler.title(call.id, in: work.store, models: [FakeTitle()]) == "Northwind rollout plan")
        let titled = try #require(try work.store.call(call.id))
        #expect(titled.title == "Northwind rollout plan" && titled.titleSource == .auto)
    }

    @Test func progressRisesToTheEndOfTheFile() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let progress = Progress()

        _ = try await work.importFile(try source("wav", in: work.source), onProgress: progress.add)

        let values = progress.values
        #expect(!values.isEmpty && values == values.sorted())
        #expect(values.allSatisfy { $0 > 0 && $0 <= 1 })
        #expect(try #require(values.last) > 0.5)
    }

    @Test func readingWaitsForWhisperToCatchUp() async throws {
        let work = try Workspace()
        defer { work.remove() }
        let file = work.source.appending(path: "long.wav")
        try writeTone(to: file, bursts: 12)

        let call = try await work.importFile(file, transcriber: FakeTranscriber(delay: .milliseconds(150)))

        #expect(call.status == .done)
        #expect(try work.store.segments(call.id).count == 12)
        #expect(work.recorder.importHighWater > 0)
        // One buffer can add a chunk after the check that let it be read.
        #expect(work.recorder.importHighWater <= CallSession.maxQueued + 1)
    }

    @Test func anImportLeftLiveSaysItWasAFileAndARecordingDoesNot() throws {
        let store = try CallStore(url: temporaryCallDatabase())
        let waiting = try store.createCall(NewCall(split: false, fileName: "a.m4a", status: .transcribing))
        let recording = try store.createCall(NewCall(split: true))
        let stored = try store.createCall(NewCall(split: false, audioPath: "/tmp/x.m4a", fileName: "b.m4a",
                                                  status: .transcribing))

        #expect(try store.failInterruptedCalls(except: [stored.id]) == 2)
        #expect(try store.call(waiting.id)?.error == "Dictate quit before this file was read. Import it again.")
        #expect(try store.call(recording.id)?.error == "Dictate stopped while recording this call.")
        #expect(try store.call(stored.id)?.status == .transcribing)

        #expect(try store.failInterruptedCalls() == 1)
        #expect(try store.call(stored.id)?.error == "Dictate quit before this file was read. Import it again.")
    }

    @Test func markTranscribingKeepsAnEndTimeThatIsSet() throws {
        let store = try CallStore(url: temporaryCallDatabase())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let imported = try store.createCall(NewCall(startedAt: start, split: false, endedAt: start.addingTimeInterval(90)))
        let recorded = try store.createCall(NewCall(startedAt: start, split: false))

        try store.markTranscribing(imported.id, endedAt: start.addingTimeInterval(5))
        try store.markTranscribing(recorded.id, endedAt: start.addingTimeInterval(5))
        try store.finishCall(imported.id)

        #expect(try store.call(imported.id)?.endedAt == start.addingTimeInterval(90))
        #expect(try store.call(recorded.id)?.endedAt == start.addingTimeInterval(5))
    }
}

@Suite struct AudioImportValidationTests {
    private func message(_ path: String) -> String? {
        do {
            _ = try AudioImport.validate(path: path)
            return nil
        } catch {
            return "\(error)"
        }
    }

    private func folder() throws -> URL {
        let dir = realPath(FileManager.default.temporaryDirectory)
            .appending(path: "ImportValidation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func acceptsASupportedFileAnyCase() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "Call.MP3")
        try Data([1]).write(to: file)

        #expect(try AudioImport.validate(path: file.path).resolvingSymlinksInPath().path
                == file.resolvingSymlinksInPath().path)
    }

    @Test func refusesWhatIsNotAnAbsolutePath() {
        #expect(message("calls/standup.m4a") == "Use the full path to the file, starting with / or ~/.")
        #expect(message("") != nil)
        #expect(message("/tmp/a\0b.m4a") == "That isn't a valid file path.")
    }

    @Test func refusesAMissingFileAFolderAndAnotherType() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folderNamedLikeAudio = dir.appending(path: "folder.m4a")
        try FileManager.default.createDirectory(at: folderNamedLikeAudio, withIntermediateDirectories: false)
        let text = dir.appending(path: "notes.txt")
        try Data([1]).write(to: text)

        #expect(message(dir.appending(path: "gone.m4a").path) == "No file at \(dir.appending(path: "gone.m4a").path).")
        #expect(message(folderNamedLikeAudio.path) == "\(folderNamedLikeAudio.path) is not a file.")
        #expect(message(text.path) == "Only audio and video files can be imported.")
    }

    @Test func refusesFilesOverTwoGigabytes() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appending(path: "big.m4a")
        #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(AudioImport.maxBytes) + 1)
        try handle.close()
        let edge = dir.appending(path: "edge.m4a")
        #expect(FileManager.default.createFile(atPath: edge.path, contents: nil))
        let edgeHandle = try FileHandle(forWritingTo: edge)
        try edgeHandle.truncate(atOffset: UInt64(AudioImport.maxBytes))
        try edgeHandle.close()

        #expect(message(big.path) == "Files over 2 GB can't be imported.")
        #expect(message(edge.path) == nil)
    }

    @Test func refusesAPipeAndADevice() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pipe = dir.appending(path: "pipe.m4a")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let zero = dir.appending(path: "zero.m4a")
        try FileManager.default.createSymbolicLink(at: zero, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))

        #expect(message(pipe.path) == "\(pipe.path) is not a file.")
        #expect(message(zero.path) == "\(zero.path) is not a file.")
    }

    @Test func aPathSwappedForAPipeAfterValidationDoesNotHang() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pipe = dir.appending(path: "pipe.m4a")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let store = try CallStore(url: dir.appending(path: "voice.sqlite"))
        let recorder = CallRecorder(store: store, directory: dir.appending(path: "calls"))

        await #expect(throws: AudioImportError.self) { try await recorder.beginImport(pipe) }
        await #expect(throws: AudioImportError.self) { try await recorder.beginImport(URL(fileURLWithPath: "/dev/zero")) }
        #expect(try store.calls(limit: 10).isEmpty)
    }

    @Test func refusesDictatesOwnFoldersButNotTheRestOfLibrary() throws {
        let support = DataMigration.applicationSupport
        let own = [Paths.support, support.appending(path: "Dictate"), support.appending(path: "Voice")]
        for folder in own {
            #expect(message(folder.appending(path: "calls/x.m4a").path) == "Dictate's own files can't be imported.", "\(folder.path)")
        }
        let memo = NSHomeDirectory() + "/Library/Application Support/com.apple.voicememos/Recordings/x.m4a"
        #expect(message(memo)?.hasPrefix("Dictate's own") == false)
    }

    @Test func refusesDictatesOwnFoldersWhateverTheCase() throws {
        let shouted = Paths.support.appending(path: "calls/x.m4a").path.uppercased()
        #expect(message(shouted) == "Dictate's own files can't be imported.")
    }

    @Test func followsASymlinkToTheFile() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "real.m4a")
        try Data([1]).write(to: file)
        let link = dir.appending(path: "latest.mp3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let towardsText = dir.appending(path: "other.m4a")
        let text = dir.appending(path: "notes.txt")
        try Data([1]).write(to: text)
        try FileManager.default.createSymbolicLink(at: towardsText, withDestinationURL: text)

        #expect(try AudioImport.validate(path: link.path).resolvingSymlinksInPath().path
                == file.resolvingSymlinksInPath().path)
        #expect(message(towardsText.path) == "Only audio and video files can be imported.")
    }

    @Test func expandsTheHomeFolder() {
        let name = "dictate-import-test-\(UUID().uuidString).m4a"
        let expanded = URL(fileURLWithPath: NSHomeDirectory()).appending(path: name).standardizedFileURL.path
        #expect(message("~/\(name)") == "No file at \(expanded).")
        #expect(!FileManager.default.fileExists(atPath: expanded))
    }

    @Test func hashesAFileTheSameWhateverItsName() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let one = dir.appending(path: "one.wav")
        let two = dir.appending(path: "two.wav")
        try Data("abc".utf8).write(to: one)
        try Data("abc".utf8).write(to: two)

        #expect(try AudioImport.sha256(of: one) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(try AudioImport.sha256(of: one) == AudioImport.sha256(of: two))
    }
}
