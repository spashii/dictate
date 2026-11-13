import Foundation
import VoiceCore

// Call recording without the app:
//
//   dictate-cli call --file STEREO.wav [--fast] [--db PATH]
//       plays the WAV through CallRecorder as if it were a live call, in real time unless
//       --fast: left is me, right is the call (a mono file is one mixed side). Prints each
//       segment as it is stored, with how long after its words ended
//   dictate-cli call --record SECONDS [--db PATH]
//       records the source the app would choose (a Blend mix, else the default microphone)
//   dictate-cli call --rebuild ID [--db PATH]
//       transcribes a call again from its audio, WAV or m4a
//   dictate-cli call --remove [--db PATH]
//       deletes every call `call --file` wrote, with its audio
//   dictate-cli import FILE [--db PATH]
//       imports an audio or video file as one call, as the app does, and prints its transcript
//   dictate-cli watch-calls [--raw]
//       prints call detection as it happens; --raw adds every process using audio each second

/// Marks the calls `call --file` writes, so --remove deletes those and nothing else.
let testCallBundleID = "io.github.spashii.voice-cli.call"

func callCommand(_ arguments: [String], transcriber: Transcriber, whisper: WhisperOptions, dbPath: String?) async {
    var arguments = arguments
    func option(_ name: String) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
        defer { arguments.removeSubrange(i...(i + 1)) }
        return arguments[i + 1]
    }
    do {
        let store = try CallStore(url: dbPath.map { URL(fileURLWithPath: $0) } ?? Paths.database)
        let recorder = CallRecorder(store: store)
        // Loaded first, as the app does at launch, so the first words don't wait for it.
        try await transcriber.load()
        if arguments.contains("--remove") {
            let tests = try store.calls(limit: 100_000).filter { $0.appBundleID == testCallBundleID }
            for call in tests {
                try store.deleteCall(call.id)
                if let path = call.audioPath { try? FileManager.default.removeItem(atPath: path) }
            }
            print("removed \(tests.count) test call\(tests.count == 1 ? "" : "s")")
        } else if let id = option("--rebuild") {
            let call = try await recorder.rebuild(id, transcriber: transcriber, whisper: whisper)
            await recorder.waitForCompression()
            print(try store.transcript(call.id))
            print("\(call.status.rawValue) \(call.error ?? "")")
        } else if let seconds = option("--record").flatMap(Double.init) {
            let source = CallSources.automatic(CallSources.all(BlendDevices.load(), devices: InputDevices.list()))
            print("source \(source.name) \(source.channels.map(\.rawValue)) \(source.deviceUID ?? "default")")
            let call = try await recorder.start(source, transcriber: transcriber, whisper: whisper,
                                                appBundleID: testCallBundleID, appName: "dictate-cli call")
            print("call \(call.id) split \(call.split) audio \(call.audioPath ?? "")")
            fflush(stdout)
            try await Task.sleep(for: .seconds(seconds))
            let done = await recorder.stop()
            await recorder.waitForCompression()
            print("\(done?.status.rawValue ?? "nothing recorded") \(done?.error ?? "")")
        } else if let file = option("--file") {
            let realTime = !arguments.contains("--fast")
            let printer = Task.detached { try await follow(store) }
            let call = try await recorder.play(URL(fileURLWithPath: file), transcriber: transcriber,
                                               whisper: whisper, realTime: realTime, appBundleID: testCallBundleID,
                                               appName: "dictate-cli call", title: "dictate-cli call") { call in
                print("call \(call.id) split \(call.split) audio \(call.audioPath ?? "")")
                fflush(stdout)
            }
            _ = try? store.tagCall(call.id, add: ["test"])
            await recorder.waitForCompression()
            try await Task.sleep(for: .milliseconds(600))
            printer.cancel()
            print("\(call.status.rawValue) \(call.error ?? "")")
            print(try store.transcript(call.id))
        } else {
            fail("usage: dictate-cli call --file STEREO.wav [--fast] | --record SECONDS | --rebuild ID | --remove")
        }
    } catch {
        fail("dictate-cli call: \(error)")
    }
}

func importCommand(_ arguments: [String], transcriber: Transcriber, whisper: WhisperOptions, dbPath: String?) async {
    guard arguments.count == 1 else { fail("usage: dictate-cli import FILE [--model PATH] [--vad-model PATH] [--db PATH]") }
    do {
        let source = try AudioImport.validate(path: arguments[0].hasPrefix("/") || arguments[0].hasPrefix("~/")
            ? arguments[0] : FileManager.default.currentDirectoryPath + "/" + arguments[0])
        let store = try CallStore(url: dbPath.map { URL(fileURLWithPath: $0) } ?? Paths.database)
        let recorder = CallRecorder(store: store)
        let start = try await recorder.beginImport(source)
        if start.duplicate {
            print("Already imported: \(start.call.id)")
            return
        }
        try await transcriber.load()
        let shown = ProgressShown()
        let call = await recorder.transcribeImport(start.call.id, from: source, transcriber: transcriber,
                                                   whisper: whisper) { fraction in
            let percent = Int(fraction * 100)
            if shown.advance(to: percent) {
                FileHandle.standardError.write(Data("\(percent)%\n".utf8))
            }
        }
        await recorder.waitForCompression()
        guard let call else { fail("dictate-cli import: the call \(start.call.id) was not found.") }
        if call.status == .failed { fail("dictate-cli import: \(call.error ?? "the file could not be transcribed.")") }
        print(call.id)
        print(try store.transcript(call.id))
    } catch {
        fail("dictate-cli import: \(error)")
    }
}

/// Lets progress print each whole percent once, from whichever thread reports it.
private final class ProgressShown: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1

    func advance(to percent: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard percent > last else { return false }
        last = percent
        return true
    }
}

/// Prints the current call's segments as they land: lag is from the end of the words,
/// in call time, to when the segment was stored.
private func follow(_ store: CallStore) async throws {
    var cursor = try store.latestCursor()
    while !Task.isCancelled {
        let batch = try await store.waitForSegments(nil, after: cursor, timeout: .seconds(5))
        for segment in batch.segments {
            let lag = batch.call.map { segment.createdAt.timeIntervalSince($0.startedAt) - Double(segment.endMs) / 1000 }
            print(String(format: "[%@] %@ lag %.2fs: %@", CallTranscript.clock(segment.startMs),
                         segment.channel.rawValue, lag ?? 0, segment.text))
            fflush(stdout)
        }
        cursor = batch.cursor
    }
}

func watchCalls(raw: Bool) async -> Never {
    var tick: (@Sendable ([CallDetector.Usage]) -> Void)?
    if raw {
        tick = { (usage: [CallDetector.Usage]) in
            let all = CallApps.processes().map { process in
                "\(process.bundleID)(\(process.pid))" + (process.input ? " in" : "") + (process.output ? " out" : "")
            }
            let apps = usage.map { (app: CallDetector.Usage) -> String in
                app.name + (app.input ? " in" : "") + (app.output ? " out" : "")
            }
            print("call apps: \(apps.joined(separator: ", ")) | all: \(all.joined(separator: ", "))")
            fflush(stdout)
        }
    }
    let detector = CallDetector(onChange: { (calls: [DetectedCall]) in
        let names = calls.map { "\($0.name) (\($0.bundleID))" }
        print("\(ISO8601DateFormatter().string(from: Date())) in a call: \(calls.isEmpty ? "none" : names.joined(separator: ", "))")
        fflush(stdout)
    }, onTick: tick)
    detector.start()
    print("watching; Ctrl-C to stop")
    fflush(stdout)
    while true { try? await Task.sleep(for: .seconds(3600)) }
}
