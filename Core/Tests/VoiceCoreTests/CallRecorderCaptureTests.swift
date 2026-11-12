import AVFoundation
import BlendKit
import Foundation
import os
import Testing
@testable import VoiceCore

/// A capture that delivers what a test tells it to, the way BlendKit does on its own queue,
/// with no audio hardware. `tail` arrives from `stop()`, as BlendKit flushes its ring there.
private final class FakeCapture: CallCapturing, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var frames: CallCapture.Frames?
    private var events: CallCapture.Events?
    private(set) var options: CallCaptureOptions?
    var startError: (any Error)?
    var tail: (me: [Float], call: [Float])?
    private(set) var started = false
    private(set) var stopped = 0

    var factory: CallCaptureFactory {
        { [self] options, frames, events in
            lock.withLock { _ in
                self.options = options
                self.frames = frames
                self.events = events
            }
            return self
        }
    }

    func start() throws {
        if let startError { throw startError }
        started = true
    }

    func stop() {
        stopped += 1
        if let tail { send(me: tail.me, call: tail.call) }
    }

    func send(me: [Float], call: [Float], position: UInt64 = 0) {
        let frames = lock.withLock { _ in self.frames }
        me.withUnsafeBufferPointer { me in
            call.withUnsafeBufferPointer { call in frames?(me, call, position) }
        }
    }

    func emit(_ event: CallCapture.Event) {
        lock.withLock { _ in events }?(event)
    }
}

private final class Notices: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [String]())
    func add(_ text: String) { lock.withLock { $0.append(text) } }
    var all: [String] { lock.withLock { $0 } }
}

private let zoom = CallTapTarget(bundleID: "us.zoom.xos", name: "Zoom")
private let noModel = Transcriber(modelURL: URL(fileURLWithPath: "/nonexistent/ggml.bin"), vadModelURL: nil)
private let rate = 48_000

private func plan(microphone: CallSource = .systemDefault) -> CallPlan {
    CallPlan(mix: nil, microphone: microphone, app: zoom, notices: [])
}

/// A recorder over `capture`, with its own database and folder.
private func recorder(_ capture: FakeCapture, notices: Notices = Notices(),
                      permission: AudioCapturePermission = .authorized) throws -> (CallRecorder, CallStore) {
    let database = temporaryCallDatabase()
    let store = try CallStore(url: database)
    let recorder = CallRecorder(store: store, directory: database.deletingLastPathComponent(),
                                onNotice: { notices.add($0) }, capture: capture.factory,
                                permission: { permission })
    recorder.deviceStart = { _ in try store.createCall(NewCall(split: false)) }
    return (recorder, store)
}

/// Blocks of 10 ms with every Me sample `me` and every Call sample `call`.
private func play(_ capture: FakeCapture, me: Float, call: Float, seconds: Int) {
    let block = rate / 100
    for index in 0..<(seconds * 100) {
        capture.send(me: [Float](repeating: me, count: block), call: [Float](repeating: call, count: block),
                     position: UInt64(index * block))
    }
}

/// The WAV as two arrays. A loud constant is cut as speech and the missing model fails the
/// transcription, so the call is failed and its WAV stays as written; a quiet call would be
/// replaced by an .m4a while the test reads it.
private func channels(of call: Call) throws -> (left: [Float], right: [Float]) {
    let url = URL(fileURLWithPath: try #require(call.audioPath))
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let data = try #require(buffer.floatChannelData)
    let count = Int(buffer.frameLength)
    return (Array(UnsafeBufferPointer(start: data[0], count: count)),
            Array(UnsafeBufferPointer(start: data[1], count: count)))
}

@Suite struct CallRecorderCaptureTests {
    @Test func meIsLeftAndCallIsRightInTheWAV() async throws {
        let capture = FakeCapture()
        let (recorder, _) = try recorder(capture)
        let started = try await recorder.start(plan(), transcriber: noModel)
        #expect(capture.started && started.notices.isEmpty && started.call.split)
        play(capture, me: 0.25, call: 0.5, seconds: 1)
        let call = try #require(await recorder.stop())

        let (left, right) = try channels(of: call)
        #expect(left.count == rate && right.count == rate)
        #expect(abs((left.max() ?? 0) - 0.25) < 0.001 && abs((left.min() ?? 0) - 0.25) < 0.001)
        #expect(abs((right.max() ?? 0) - 0.5) < 0.001 && abs((right.min() ?? 0) - 0.5) < 0.001)
    }

    @Test func theCaptureIsAskedForTheMicrophoneTheAppAndTheFixedRate() async throws {
        let capture = FakeCapture()
        let (recorder, _) = try recorder(capture)
        let microphone = CallSource(deviceUID: "BuiltIn", name: "MacBook Microphone", channels: [.mix],
                                    fromBlend: false)
        _ = try await recorder.start(plan(microphone: microphone), transcriber: noModel)
        let options = try #require(capture.options)
        #expect(options.label == "Dictate" && options.microphoneUID == "BuiltIn")
        #expect(options.call == TapTarget(bundleID: "us.zoom.xos") && options.outputRate == 48_000)
        await recorder.abandon()
    }

    @Test func stopDeliversTheLastFramesBeforeTheCallIsFinished() async throws {
        let capture = FakeCapture()
        capture.tail = (me: [Float](repeating: 0.25, count: 4_800), call: [Float](repeating: 0.5, count: 4_800))
        let (recorder, _) = try recorder(capture)
        _ = try await recorder.start(plan(), transcriber: noModel)
        play(capture, me: 0.25, call: 0.5, seconds: 1)
        let call = try #require(await recorder.stop())

        #expect(capture.stopped == 1)
        let (left, right) = try channels(of: call)
        #expect(left.count == rate + 4_800 && right.count == rate + 4_800)
        #expect(abs((right.last ?? 0) - 0.5) < 0.001)
    }

    @Test func framesBeforeTheSessionExistsAreKept() async throws {
        let capture = FakeCapture()
        let (recorder, _) = try recorder(capture)
        // Frames can arrive while start() is still running, before any call exists.
        let first = [Float](repeating: 0.25, count: 4_800)
        let second = [Float](repeating: 0.5, count: 4_800)
        let frames = CallFrames()
        first.withUnsafeBufferPointer { me in second.withUnsafeBufferPointer { call in
            frames.push(me: me, call: call)
        } }
        let session = try recorder.begin(format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!,
                                         labels: [.me, .call], order: [0, 1], deviceUID: nil, noModel,
                                         WhisperOptions(), appBundleID: nil, appName: nil, title: nil)
        frames.attach(session)
        frames.detach()
        await recorder.abandon()
        let call = try #require(try recorder.store.call(session.callID))
        let (left, right) = try channels(of: call)
        #expect(left.count == 4_800 && right.count == 4_800)
        #expect(abs((left.first ?? 0) - 0.25) < 0.001 && abs((right.first ?? 0) - 0.5) < 0.001)
    }

    @Test func aCallAppThatCantBeCapturedFallsBackToTheMicrophoneWithANotice() async throws {
        let capture = FakeCapture()
        capture.startError = CallCaptureError.callUnavailable
        let (recorder, store) = try recorder(capture)
        let started = try await recorder.start(plan(), transcriber: noModel)

        #expect(started.notices == [CallPlanner.tapFailedNotice("Zoom")])
        #expect(!capture.started)
        // The call that records is the microphone's own, and nothing failed beside it.
        let calls = try store.recentCalls(limit: 10)
        #expect(calls.map(\.id) == [started.call.id])
        #expect(calls.allSatisfy { $0.status != .failed })
    }

    @Test func aMissingMicrophoneFailsTheStartWithoutACall() async throws {
        let capture = FakeCapture()
        capture.startError = CallCaptureError.microphoneUnavailable
        let (recorder, store) = try recorder(capture)
        await #expect(throws: (any Error).self) { try await recorder.start(plan(), transcriber: noModel) }
        #expect(try store.recentCalls(limit: 10).isEmpty)
    }

    @Test func eventsGiveNoticesAndNeverEndTheCall() async throws {
        let capture = FakeCapture()
        let notices = Notices()
        let (recorder, store) = try recorder(capture, notices: notices, permission: .authorized)
        let started = try await recorder.start(plan(), transcriber: noModel)
        play(capture, me: 0.0001, call: 0, seconds: 1)

        capture.emit(.callTapLost(reason: "the app restarted"))
        play(capture, me: 0.0001, call: 0, seconds: 1)
        capture.emit(.callTapRestored)
        capture.emit(.callSilent)
        capture.emit(.microphoneLost)
        capture.emit(.echoCancellationFailed)
        capture.emit(.overflow)
        capture.emit(.microphoneRestarted)
        play(capture, me: 0.0001, call: 0, seconds: 1)

        #expect(notices.all == [
            "Lost Zoom's sound. Your microphone keeps recording, and Dictate keeps trying to get it back.",
            "Recording Zoom's sound again.",
            "Can't hear Zoom. Is it muted or playing somewhere else?",
            "Lost your microphone. The call keeps recording and Dictate keeps looking for it.",
            "Echo cancellation stopped, so your microphone may pick up the call.",
        ])
        #expect(try store.call(started.call.id)?.status == .recording)
        #expect(recorder.callID == started.call.id)
        let call = try #require(await recorder.stop())
        #expect(call.status == .done && call.error == nil)
    }

    @Test func aSilentCallAppWithTheAudioPermissionOffSaysSo() async throws {
        let capture = FakeCapture()
        let notices = Notices()
        let (recorder, _) = try recorder(capture, notices: notices, permission: .denied)
        _ = try await recorder.start(plan(), transcriber: noModel)
        capture.emit(.callSilent)
        #expect(notices.all == [CallPlanner.silentPermissionNotice])
        let call = try #require(await recorder.stop())
        #expect(call.status == .done)
    }
}
