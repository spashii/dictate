import AVFoundation
import Foundation
import Testing
@testable import VoiceCore

private let day: TimeInterval = 24 * 3600

private func defaults() -> UserDefaults {
    let name = "RetentionTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite struct RetentionPolicyTests {
    @Test func defaultsAreSevenDaysAudioAndThirtyDaysTranscripts() {
        let policy = RetentionPolicy.effective(audio: nil, transcripts: nil, developerMode: false)
        #expect(policy == RetentionPolicy(audio: .sevenDays, transcripts: .thirtyDays))
    }

    @Test func everyStoredChoiceIsHonouredWithoutDeveloperMode() {
        for audio in [AudioRetention.immediately, .sevenDays] {
            for transcripts in TranscriptRetention.allCases {
                let policy = RetentionPolicy.effective(audio: audio, transcripts: transcripts, developerMode: false)
                #expect(policy == RetentionPolicy(audio: audio, transcripts: transcripts))
            }
        }
    }

    @Test func audioForeverReadsAsSevenDaysWithoutDeveloperMode() {
        let policy = RetentionPolicy.effective(audio: .forever, transcripts: .sevenDays, developerMode: false)
        #expect(policy == RetentionPolicy(audio: .sevenDays, transcripts: .sevenDays))
        #expect(RetentionPolicy.shownAudio(.forever, developerMode: false) == .sevenDays)
    }

    @Test func developerModeKeepsEverythingWhateverIsStored() {
        for audio in AudioRetention.allCases {
            for transcripts in TranscriptRetention.allCases {
                #expect(RetentionPolicy.effective(audio: audio, transcripts: transcripts, developerMode: true)
                        == .keepEverything)
            }
        }
        #expect(RetentionPolicy.effective(audio: nil, transcripts: nil, developerMode: true) == .keepEverything)
    }

    @Test func pickersShowForeverInDeveloperModeUntilAChoiceIsStored() {
        #expect(RetentionPolicy.shownAudio(nil, developerMode: true) == .forever)
        #expect(RetentionPolicy.shownTranscripts(nil, developerMode: true) == .forever)
        #expect(RetentionPolicy.shownAudio(.immediately, developerMode: true) == .immediately)
        #expect(RetentionPolicy.shownTranscripts(.sevenDays, developerMode: true) == .sevenDays)
        #expect(RetentionPolicy.shownAudio(nil, developerMode: false) == .sevenDays)
        #expect(RetentionPolicy.shownTranscripts(nil, developerMode: false) == .thirtyDays)
        #expect(RetentionPolicy.shownTranscripts(.forever, developerMode: false) == .forever)
    }
}

@Suite struct RetentionChoicesTests {
    @Test func anOldHistoryChoiceIsIgnored() {
        for old in ["forever", "thirtyDays"] {
            let store = defaults()
            store.set(old, forKey: "history")
            let choices = RetentionChoices.load(from: store)
            #expect(choices == RetentionChoices(audio: nil, transcripts: nil))
            #expect(RetentionPolicy.effective(audio: choices.audio, transcripts: choices.transcripts, developerMode: false)
                    == RetentionPolicy(audio: .sevenDays, transcripts: .thirtyDays))
        }
    }

    @Test func savesAndLoadsAndNilRemovesTheKey() {
        let store = defaults()
        RetentionChoices(audio: .immediately, transcripts: .forever).save(to: store)
        #expect(RetentionChoices.load(from: store) == RetentionChoices(audio: .immediately, transcripts: .forever))
        #expect(store.string(forKey: "audioRetention") == "immediately")
        #expect(store.string(forKey: "transcriptRetention") == "forever")

        RetentionChoices(audio: nil, transcripts: .sevenDays).save(to: store)
        #expect(store.object(forKey: "audioRetention") == nil)
        #expect(RetentionChoices.load(from: store) == RetentionChoices(audio: nil, transcripts: .sevenDays))
    }

    @Test func turningDeveloperModeOffResetsOnlyAudioForever() {
        #expect(RetentionChoices(audio: .forever, transcripts: .forever).afterDeveloperModeOff()
                == RetentionChoices(audio: nil, transcripts: .forever))
        #expect(RetentionChoices(audio: .immediately, transcripts: .sevenDays).afterDeveloperModeOff()
                == RetentionChoices(audio: .immediately, transcripts: .sevenDays))
        #expect(RetentionChoices(audio: nil, transcripts: nil).afterDeveloperModeOff() == RetentionChoices())
    }
}

/// A database with dictations and calls in a temporary folder that goes away with the test.
private final class Bench {
    let dir: URL
    let store: Store
    let calls: CallStore

    init() throws {
        dir = realPath(FileManager.default.temporaryDirectory)
            .appending(path: "RetentionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "voice.sqlite")
        store = try Store(url: url)
        calls = try CallStore(url: url)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func file(_ name: String = UUID().uuidString, ext: String = "wav") throws -> URL {
        let url = dir.appending(path: "\(name).\(ext)")
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    func has(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

    @discardableResult
    func dictation(_ id: String, ageDays: Double = 0, error: String? = nil, imported: Bool = false,
                   audio: URL? = nil, text: String = "Alex asked about the Northwind budget") throws -> URL {
        let audio = try audio ?? file(id)
        var row = Dictation(
            id: id, createdAt: Date().addingTimeInterval(-ageDays * day), audioPath: audio.path, duration: 3,
            mode: .plain, whisperModel: "test", rawText: text, finalText: text, cleanupModel: nil, cleanupSystem: nil,
            timings: .init(), segments: [Segment(t0: 0, t1: 1, text: text, avgLogprob: -0.25, noSpeechProb: 0.01,
                                                   compressionRatio: 1.2, speechSeconds: 0.9, wordsPerSecond: 2.5)],
            error: error)
        if imported { row.origin = Dictation.Origin.imported }
        try store.insert(row)
        return audio
    }

    @discardableResult
    func call(_ id: String = UUID().uuidString, ageDays: Double = 0, status: Call.Status = .done,
              text: String = "Northwind roadmap with Alex") throws -> URL {
        let audio = try file(id, ext: "m4a")
        try calls.createCall(NewCall(id: id, startedAt: Date().addingTimeInterval(-ageDays * day), split: true,
                                     audioPath: audio.path))
        try calls.appendSegments(id, [sampleSegment(.me, 0, text)])
        try calls.tagCall(id, add: ["roadmap"])
        switch status {
        case .done: try calls.finishCall(id)
        case .failed: try calls.failCall(id, error: "no")
        case .transcribing: try calls.markTranscribing(id)
        case .recording: break
        }
        return audio
    }

    func edit(_ target: String) throws {
        try calls.recordEdit(.correctSegment, target: target, client: "test", before: Edit.Value(text: "a"),
                             after: Edit.Value(text: "b", corrected: true))
    }

    /// Edits whose target starts with `prefix`, compared without wildcards.
    func edits(_ prefix: String) -> Int {
        (try? calls.db.query("SELECT count(*) FROM edits WHERE substr(target, 1, length(?1)) = ?1", [prefix]) { $0.int(0) }.first) ?? -1
    }

    func suggestion() throws {
        let edit = try calls.recordEdit(.correctDictation, target: "dictation:x", client: "test",
                                        before: Edit.Value(text: "a"), after: Edit.Value(text: "b", corrected: true))
        try calls.db.run("INSERT INTO key_term_suggestions (term, heard, edit_id, created_at) VALUES (?,?,?,?)",
                         ["Northwind", "north wind", edit.id, Date()])
    }

    func suggestions() -> Int {
        (try? calls.db.query("SELECT count(*) FROM key_term_suggestions", []) { $0.int(0) }.first) ?? -1
    }
}

@Suite struct DictationAudioTests {
    private let bench: Bench
    init() throws { bench = try Bench() }

    @Test func finishedOldRowsLoseTheirFileAndKeepTheirText() throws {
        let old = try bench.dictation("old", ageDays: 8)
        let fresh = try bench.dictation("fresh", ageDays: 1)

        #expect(bench.store.deleteAudio(before: Date().addingTimeInterval(-7 * day), finishedOnly: true) == 1)

        #expect(!bench.has(old))
        #expect(bench.has(fresh))
        #expect(bench.store.recent(10).map(\.id).sorted() == ["fresh", "old"])
        #expect(bench.store.recent(10).first { $0.id == "old" }?.finalText == "Alex asked about the Northwind budget")
        #expect(bench.store.recent(10).first { $0.id == "old" }?.audioPath == old.path)
    }

    @Test func failedRowsKeepTheirFileUnderFinishedOnly() throws {
        let failed = try bench.dictation("failed", ageDays: 8, error: "Whisper failed")

        #expect(bench.store.deleteAudio(before: Date(), finishedOnly: true) == 0)
        #expect(bench.has(failed))
        #expect(bench.store.deleteAudio(before: Date(), finishedOnly: false) == 1)
        #expect(!bench.has(failed))
    }

    @Test func importedRowsAreUntouched() throws {
        let imported = try bench.dictation("imported", ageDays: 400, imported: true)

        #expect(bench.store.deleteAudio(before: Date(), finishedOnly: false) == 0)
        #expect(bench.has(imported))
    }

    @Test func aPathSharedWithAKeptRowStays() throws {
        let shared = try bench.dictation("old", ageDays: 8)
        try bench.dictation("retry", ageDays: 0, audio: shared)

        #expect(bench.store.deleteAudio(before: Date().addingTimeInterval(-7 * day), finishedOnly: true) == 0)
        #expect(bench.has(shared))
    }

    @Test func aMissingFileIsNotCounted() throws {
        let gone = try bench.dictation("gone", ageDays: 8)
        try FileManager.default.removeItem(at: gone)

        #expect(bench.store.deleteAudio(before: Date(), finishedOnly: true) == 0)
    }
}

@Suite struct ImmediateDeletionTests {
    private let bench: Bench
    init() throws { bench = try Bench() }

    @Test func immediatelyDeletesAFreshFinishedDictationsAudioAndSevenDaysKeepsIt() throws {
        let audio = try bench.dictation("fresh")

        RetentionSweep.run(RetentionPolicy(audio: .sevenDays, transcripts: .forever), dictations: bench.store, calls: bench.calls)
        #expect(bench.has(audio))

        let counts = RetentionSweep.run(RetentionPolicy(audio: .immediately, transcripts: .forever),
                                        dictations: bench.store, calls: bench.calls)
        #expect(counts == RetentionCounts(recordings: 0, audioOnly: 1))
        #expect(!bench.has(audio))
        #expect(bench.store.recent(10).map(\.id) == ["fresh"])
    }

    @Test func aFailedDictationKeepsItsAudioUntilSevenDaysOld() throws {
        let recent = try bench.dictation("recent", ageDays: 6, error: "Whisper failed")
        let old = try bench.dictation("old", ageDays: 8, error: "Whisper failed")
        let policy = RetentionPolicy(audio: .immediately, transcripts: .forever)

        RetentionSweep.run(policy, dictations: bench.store, calls: bench.calls)

        #expect(bench.has(recent))
        #expect(!bench.has(old))
    }

    @Test func aFailedCallKeepsItsAudioUntilSevenDaysOld() throws {
        let recent = try bench.call("recent", ageDays: 3, status: .failed)
        let old = try bench.call("old", ageDays: 9, status: .failed)
        let finished = try bench.call("finished", ageDays: 0)

        RetentionSweep.run(RetentionPolicy(audio: .immediately, transcripts: .forever),
                           dictations: bench.store, calls: bench.calls)

        #expect(bench.has(recent))
        #expect(!bench.has(old))
        #expect(!bench.has(finished))
    }
}

@Suite struct ExpiringTranscriptTests {
    private let bench: Bench
    init() throws { bench = try Bench() }

    @Test func expiredDictationsLeaveHistorySearchAndEditsButKeepSuggestions() throws {
        try bench.dictation("old", ageDays: 40, text: "Alex mentioned the pelican budget")
        try bench.dictation("new", ageDays: 2, text: "Alex mentioned the pelican plan")
        try bench.edit("dictation:old")
        try bench.edit("dictation:new")
        try bench.suggestion()
        #expect(try bench.calls.search("pelican").count == 2)

        let counts = RetentionSweep.run(RetentionPolicy(audio: .sevenDays, transcripts: .thirtyDays),
                                        dictations: bench.store, calls: bench.calls)

        #expect(counts.recordings == 1)
        #expect(bench.store.recent(10).map(\.id) == ["new"])
        #expect(try bench.calls.historyEntries().map(\.ref) == ["new"])
        #expect(try bench.calls.historyEntries(matching: "pelican").map(\.ref) == ["new"])
        #expect(try bench.calls.search("pelican").map(\.id) == ["new"])
        #expect(bench.edits("dictation:old") == 0)
        #expect(bench.edits("dictation:new") == 1)
        #expect(bench.suggestions() == 1)
    }

    @Test func expiredCallsLeaveHistorySearchTagsAndEditsButKeepSuggestions() throws {
        try bench.call("old", ageDays: 8, text: "Alex wants the pelican roadmap")
        try bench.call("new", ageDays: 1, text: "Alex wants the pelican schedule")
        try bench.edit("call:old/segment:1")
        try bench.edit("call:old")
        try bench.edit("call:new/segment:1")
        try bench.suggestion()
        #expect(try bench.calls.search("pelican").count == 2)

        let counts = RetentionSweep.run(RetentionPolicy(audio: .sevenDays, transcripts: .sevenDays),
                                        dictations: bench.store, calls: bench.calls)

        #expect(counts.recordings == 1)
        #expect(try bench.calls.historyEntries().map(\.ref) == ["new"])
        #expect(try bench.calls.historyEntries(matching: "pelican").map(\.ref) == ["new"])
        #expect(try bench.calls.search("pelican").map(\.id) == ["new"])
        #expect(try bench.calls.segments("old").isEmpty)
        #expect(try bench.calls.calls(tag: "roadmap", limit: 10).map(\.id) == ["new"])
        #expect(bench.edits("call:old") == 0)
        #expect(bench.edits("call:new") == 1)
        #expect(bench.suggestions() == 1)
    }

    @Test func aCallIdIsNeverAWildcardForTheEditsOfOtherCalls() throws {
        try bench.call("c_1", ageDays: 40)
        try bench.call("cx1", ageDays: 1)
        try bench.edit("call:c_1/segment:1")
        try bench.edit("call:cx1/segment:1")

        try bench.calls.prune(before: Date().addingTimeInterval(-30 * day))

        #expect(bench.edits("call:c_1") == 0)
        #expect(bench.edits("call:cx1") == 1)
    }

    @Test func importedDictationsAreNotExpired() throws {
        try bench.dictation("imported", ageDays: 400, imported: true)

        let counts = RetentionSweep.run(RetentionPolicy(audio: .sevenDays, transcripts: .sevenDays),
                                        dictations: bench.store, calls: bench.calls)

        #expect(counts.isEmpty)
        #expect(bench.store.recent(10).map(\.id) == ["imported"])
    }
}

@Suite struct CallAudioRetentionTests {
    private let bench: Bench
    init() throws { bench = try Bench() }

    @Test func clearAudioForgetsThePathAndRemovesTheFile() throws {
        let audio = try bench.call("done", ageDays: 1)

        #expect(try bench.calls.clearAudio("done"))

        #expect(!bench.has(audio))
        #expect(try bench.calls.call("done")?.audioPath == nil)
        #expect(try bench.calls.callsAwaitingCompression().isEmpty)
        #expect(try !bench.calls.clearAudio("done"))
    }

    @Test func clearAudioKeepsAFileAnotherCallPointsAt() throws {
        let shared = try bench.call("a")
        try bench.calls.createCall(NewCall(id: "b", split: true, audioPath: shared.path))

        #expect(try !bench.calls.clearAudio("a"))
        #expect(bench.has(shared))
    }

    @Test func clearAudioDropsAWaitingWAVFromCompression() throws {
        let wav = try bench.file("waiting", ext: "wav")
        try bench.calls.createCall(NewCall(id: "waiting", split: true, audioPath: wav.path))
        try bench.calls.finishCall("waiting")
        #expect(try bench.calls.callsAwaitingCompression().map(\.id) == ["waiting"])

        try bench.calls.clearAudio("waiting")

        #expect(try bench.calls.callsAwaitingCompression().isEmpty)
    }

    @Test func callsWithAudioNeverListsALiveCall() throws {
        try bench.call("recording", ageDays: 20, status: .recording)
        try bench.call("transcribing", ageDays: 20, status: .transcribing)
        try bench.call("done", ageDays: 20)
        try bench.call("failed", ageDays: 20, status: .failed)
        let now = Date()

        #expect(try bench.calls.callsWithAudio(before: now, finishedOnly: true) == ["done"])
        #expect(try Set(bench.calls.callsWithAudio(before: now, finishedOnly: false)) == ["done", "failed"])
    }

    @Test func aSweepLeavesLiveCallsAlone() throws {
        let recording = try bench.call("recording", ageDays: 400, status: .recording)
        let transcribing = try bench.call("transcribing", ageDays: 400, status: .transcribing)

        let counts = RetentionSweep.run(RetentionPolicy(audio: .immediately, transcripts: .sevenDays),
                                        dictations: bench.store, calls: bench.calls)

        #expect(counts.isEmpty)
        #expect(bench.has(recording))
        #expect(bench.has(transcribing))
        #expect(try bench.calls.call("recording") != nil)
        #expect(try bench.calls.call("transcribing") != nil)
    }

    @Test func aSweepRoutesCallAudioThroughTheGivenDeleter() throws {
        let audio = try bench.call("done", ageDays: 9)
        let asked = Asked()

        let counts = RetentionSweep.run(RetentionPolicy(audio: .sevenDays, transcripts: .forever),
                                        dictations: bench.store, calls: bench.calls,
                                        deleteCallAudio: { asked.add($0); return false })

        #expect(asked.ids == ["done"])
        #expect(counts.isEmpty)
        #expect(bench.has(audio))
    }

    @Test func theRecorderDeletesAudioOfAFinishedCall() throws {
        let recorder = CallRecorder(store: bench.calls, directory: bench.dir)
        let audio = try bench.call("done", ageDays: 1)

        #expect(recorder.deleteAudio("done"))

        #expect(!bench.has(audio))
        #expect(try bench.calls.call("done")?.audioPath == nil)
        #expect(!recorder.deleteAudio("done"))
    }

    @Test func anImportKeepsNoAudioWhenTheRecorderDeletesWhenDone() async throws {
        let recorder = CallRecorder(store: bench.calls, directory: bench.dir.appending(path: "calls"))
        recorder.setDeletesAudioWhenDone(true)
        let source = bench.dir.appending(path: "Standup.wav")
        try writeTone(to: source)

        let start = try await recorder.beginImport(source)
        let stored = try #require(start.call.audioPath)
        _ = await recorder.transcribeImport(start.call.id, transcriber: StaticTranscriber())
        await recorder.waitForCompression()

        let call = try #require(try bench.calls.call(start.call.id))
        #expect(call.status == .done)
        #expect(call.audioPath == nil)
        #expect(!FileManager.default.fileExists(atPath: stored))
        #expect(try bench.calls.segments(call.id).map(\.text) == ["Northwind budget review with Alex"])
    }

    @Test func anImportIsCompressedAsBeforeWhenTheSettingIsOff() async throws {
        let recorder = CallRecorder(store: bench.calls, directory: bench.dir.appending(path: "calls"))
        let source = bench.dir.appending(path: "Standup.wav")
        try writeTone(to: source)

        let start = try await recorder.beginImport(source)
        _ = await recorder.transcribeImport(start.call.id, transcriber: StaticTranscriber())
        await recorder.waitForCompression()

        let path = try #require(try bench.calls.call(start.call.id)?.audioPath)
        #expect(path.hasSuffix(".m4a"))
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

private struct StaticTranscriber: ChunkTranscribing {
    func transcribe(_ samples: [Float], options: WhisperOptions) async throws -> Transcript {
        let text = "Northwind budget review with Alex"
        return Transcript(text: text, segments: [Segment(t0: 0, t1: 1, text: text, avgLogprob: -0.2, noSpeechProb: 0.01,
                                                         compressionRatio: 1.1, speechSeconds: 1, wordsPerSecond: 3)],
                          seconds: 0.01)
    }
}

/// Two seconds of tone and one of silence, 16 kHz mono.
private func writeTone(to url: URL) throws {
    let rate = 16_000.0
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = 3 * 16_000
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames {
        buffer.floatChannelData![0][i] = i < 2 * 16_000 ? Float(sin(2 * .pi * 440 * Double(i) / rate) * 0.5) : 0
    }
    try file.write(from: buffer)
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    func add(_ id: String) { lock.lock(); seen.append(id); lock.unlock() }
    var ids: [String] { lock.lock(); defer { lock.unlock() }; return seen }
}

@Suite struct RetentionSweepTests {
    private let bench: Bench
    init() throws { bench = try Bench() }

    @Test func keepEverythingDeletesNothing() throws {
        let old = try bench.dictation("old", ageDays: 900)
        let call = try bench.call("call", ageDays: 900)

        let counts = RetentionSweep.run(.keepEverything, dictations: bench.store, calls: bench.calls)

        #expect(counts.isEmpty)
        #expect(bench.has(old))
        #expect(bench.has(call))
        #expect(bench.store.recent(10).count == 1)
        #expect(try bench.calls.call("call") != nil)
    }

    @Test func previewCountsWhatRunThenDeletes() throws {
        for audio in AudioRetention.allCases {
            for transcripts in TranscriptRetention.allCases {
                let bench = try Bench()
                try mixedFixture(bench)
                let policy = RetentionPolicy(audio: audio, transcripts: transcripts)

                let preview = RetentionSweep.preview(policy, dictations: bench.store, calls: bench.calls)
                let again = RetentionSweep.preview(policy, dictations: bench.store, calls: bench.calls)
                let run = RetentionSweep.run(policy, dictations: bench.store, calls: bench.calls)

                #expect(preview == run, "\(audio) \(transcripts)")
                #expect(preview == again)
                #expect(RetentionSweep.run(policy, dictations: bench.store, calls: bench.calls).isEmpty)
            }
        }
    }

    @Test func previewAloneDeletesNothing() throws {
        try mixedFixture(bench)
        let before = (try bench.calls.search("Northwind").count, bench.store.recent(50).count,
                      try FileManager.default.contentsOfDirectory(atPath: bench.dir.path).count)

        let counts = RetentionSweep.preview(RetentionPolicy(audio: .immediately, transcripts: .sevenDays),
                                            dictations: bench.store, calls: bench.calls)

        #expect(!counts.isEmpty)
        #expect(try bench.calls.search("Northwind").count == before.0)
        #expect(bench.store.recent(50).count == before.1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bench.dir.path).count == before.2)
    }

    @Test func theMixedFixtureGivesTheExpectedNumbers() throws {
        try mixedFixture(bench)

        // 7 days of transcripts: d-old, d-8, d-8-failed, d-shared-old, d-30 and c-old, c-9,
        // c-9-failed, c-missing go; the live calls and the imported row stay. Of the rest, the
        // finished ones lose their audio at once: d-3, d-now, d-shared-new (it shares a path
        // with a deleted row, which is gone first), c-2, and the failed d-3-failed and
        // c-2-failed keep theirs.
        let policy = RetentionPolicy(audio: .immediately, transcripts: .sevenDays)
        let counts = RetentionSweep.run(policy, dictations: bench.store, calls: bench.calls)

        #expect(counts == RetentionCounts(recordings: 9, audioOnly: 4))
    }
}

/// Old and new, finished and failed, dictations and calls, a shared path, an imported row
/// and a live call.
private func mixedFixture(_ bench: Bench) throws {
    try bench.dictation("d-old", ageDays: 45)
    try bench.dictation("d-8", ageDays: 8)
    try bench.dictation("d-8-failed", ageDays: 8, error: "no")
    try bench.dictation("d-3", ageDays: 3)
    try bench.dictation("d-3-failed", ageDays: 3, error: "no")
    try bench.dictation("d-now")
    let shared = try bench.dictation("d-shared-old", ageDays: 9)
    try bench.dictation("d-shared-new", ageDays: 0, audio: shared)
    try bench.dictation("d-imported", ageDays: 500, imported: true)
    try bench.dictation("d-30", ageDays: 31, error: "no")
    try bench.call("c-old", ageDays: 45)
    try bench.call("c-9", ageDays: 9)
    try bench.call("c-9-failed", ageDays: 9, status: .failed)
    try bench.call("c-2", ageDays: 2)
    try bench.call("c-2-failed", ageDays: 2, status: .failed)
    try bench.call("c-live", ageDays: 90, status: .recording)
    try bench.call("c-transcribing", ageDays: 90, status: .transcribing)
    let missing = try bench.call("c-missing", ageDays: 9)
    try FileManager.default.removeItem(at: missing)
}
