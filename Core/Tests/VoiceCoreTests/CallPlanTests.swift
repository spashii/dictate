import CoreAudio
import Foundation
import Testing
@testable import VoiceCore

private let zoom = DetectedCall(bundleID: "us.zoom.xos", name: "Zoom")
private let chrome = DetectedCall(bundleID: "com.google.Chrome", name: "Google Chrome")
private let mixSplit = CallSource(deviceUID: "mix.split", name: "Blend Mic", channels: [.me, .call], fromBlend: true)
private let mixOne = CallSource(deviceUID: "mix.one", name: "Everything", channels: [.mix], fromBlend: true)
private let builtIn = InputDevice(uid: "BuiltIn", name: "MacBook Microphone")

private func inputs(_ choice: CallAudioChoice = .automatic, microphone: String = "", detected: [DetectedCall] = [],
                    running: [CallTapTarget] = [], mixes: [CallSource] = [],
                    permission: AudioCapturePermission = .authorized) -> CallPlanner.Inputs {
    CallPlanner.Inputs(choice: choice, microphoneUID: microphone, detected: detected, running: running, mixes: mixes,
                       devices: [builtIn], permission: permission, ownBundleID: "dictate.own")
}

@Suite struct CallPlanTests {
    @Test func automaticTapsTheCallAppDetected() {
        let plan = CallPlanner.plan(inputs(detected: [zoom]))
        #expect(plan.app == CallTapTarget(bundleID: "us.zoom.xos", name: "Zoom"))
        #expect(plan.mix == nil && plan.split && plan.notices.isEmpty)
        #expect(plan.microphone == .systemDefault)
    }

    @Test func theAppTheRecordingStartedForOutranksOtherCalls() {
        let plan = CallPlanner.plan(inputs(detected: [zoom, chrome]), appStarted: chrome)
        #expect(plan.app?.bundleID == "com.google.Chrome")
    }

    @Test func automaticPrefersTheCallAppToABlendMix() {
        let plan = CallPlanner.plan(inputs(detected: [zoom], mixes: [mixSplit]))
        #expect(plan.app?.bundleID == "us.zoom.xos" && plan.mix == nil)
    }

    @Test func automaticWithNoCallUsesASplitMixThenTheMicrophone() {
        #expect(CallPlanner.plan(inputs(mixes: [mixOne, mixSplit])).mix == mixSplit)
        let alone = CallPlanner.plan(inputs(mixes: [mixOne]))
        #expect(alone.mix == nil && alone.app == nil && !alone.split)
        #expect(alone.notices.isEmpty)
    }

    @Test func neverTapsItself() {
        let own = DetectedCall(bundleID: "dictate.own", name: "Dictate")
        #expect(CallPlanner.plan(inputs(detected: [own])).app == nil)
    }

    @Test func aChosenAppIsTappedWhileItRuns() {
        let target = CallTapTarget(bundleID: "com.hnc.Discord", name: "Discord")
        let plan = CallPlanner.plan(inputs(.app(bundleID: "com.hnc.Discord"), detected: [zoom], running: [target]))
        #expect(plan.app == target && plan.notices.isEmpty)
    }

    @Test func aChosenAppThatIsntRunningFallsBackToAutomaticWithANotice() {
        let plan = CallPlanner.plan(inputs(.app(bundleID: "com.hnc.Discord"), detected: [zoom]))
        #expect(plan.app?.bundleID == "us.zoom.xos")
        #expect(plan.notices.count == 1)
    }

    @Test func aChosenMixIsReadAsADevice() {
        let plan = CallPlanner.plan(inputs(.blendMix(deviceUID: "mix.split"), detected: [zoom], mixes: [mixSplit]))
        #expect(plan.mix == mixSplit && plan.app == nil && plan.split)
    }

    @Test func aChosenMixThatIsGoneFallsBackWithANotice() {
        let plan = CallPlanner.plan(inputs(.blendMix(deviceUID: "mix.split"), detected: [zoom]))
        #expect(plan.mix == nil && plan.app?.bundleID == "us.zoom.xos")
        #expect(plan.notices.count == 1)
    }

    @Test func deniedPermissionRecordsTheMicrophoneAlone() {
        let plan = CallPlanner.plan(inputs(detected: [zoom], permission: .denied))
        #expect(plan.app == nil && !plan.split)
        #expect(plan.notices == [CallPlanner.permissionNotice])
    }

    @Test func unknownPermissionStillTriesTheTap() {
        #expect(CallPlanner.plan(inputs(detected: [zoom], permission: .unknown)).app != nil)
    }

    @Test func deniedPermissionDoesNotAffectAMix() {
        let plan = CallPlanner.plan(inputs(.blendMix(deviceUID: "mix.split"), mixes: [mixSplit], permission: .denied))
        #expect(plan.mix == mixSplit && plan.notices.isEmpty)
    }

    @Test func theCallMicrophoneIsUsedWhileConnected() {
        let plan = CallPlanner.plan(inputs(microphone: "BuiltIn", detected: [zoom]))
        #expect(plan.microphone.deviceUID == "BuiltIn" && plan.microphone.name == "MacBook Microphone")
        let gone = CallPlanner.plan(inputs(microphone: "Unplugged", detected: [zoom]))
        #expect(gone.microphone == .systemDefault && gone.notices.count == 1)
    }

    @Test func aBlendMixIsNeverTheCallMicrophone() {
        let mixDevice = InputDevice(uid: "mix.split", name: "Blend Mic")
        var input = inputs(microphone: "mix.split", mixes: [mixSplit])
        input.devices = [builtIn, mixDevice]
        #expect(CallPlanner.plan(input).microphone == .systemDefault)
    }

    @Test func theChoiceRoundTripsThroughItsStoredForm() {
        for choice: CallAudioChoice in [.automatic, .app(bundleID: "us.zoom.xos"), .blendMix(deviceUID: "app.blend.mix.1")] {
            #expect(CallAudioChoice(stored: choice.stored) == choice)
        }
        #expect(CallAudioChoice(stored: "app:") == .automatic)
        #expect(CallAudioChoice(stored: "garbage") == .automatic)
    }

    @Test func anOldCallInputKeepsItsMeaning() throws {
        let connected: Set<String> = ["mix.split", "BuiltIn"]
        #expect(CallAudioChoice.migrate(legacyInput: "mix.split", mixUIDs: ["mix.split"], connectedUIDs: connected)?.choice
                == .blendMix(deviceUID: "mix.split"))
        let mic = try #require(CallAudioChoice.migrate(legacyInput: "BuiltIn", mixUIDs: ["mix.split"], connectedUIDs: connected))
        #expect(mic.choice == .automatic && mic.microphoneUID == "BuiltIn")
        let none = try #require(CallAudioChoice.migrate(legacyInput: nil, mixUIDs: [], connectedUIDs: []))
        #expect(none.choice == .automatic && none.microphoneUID.isEmpty)
    }

    /// The mix isn't listed yet at the first refresh: keep the old key instead of making it a microphone.
    @Test func aStoredInputThatIsNotConnectedWaits() {
        #expect(CallAudioChoice.migrate(legacyInput: "mix.split", mixUIDs: [], connectedUIDs: ["BuiltIn"]) == nil)
        #expect(CallAudioChoice.migrate(legacyInput: "mix.split", mixUIDs: ["mix.split"], connectedUIDs: ["BuiltIn"])?.choice
                == .blendMix(deviceUID: "mix.split"))
    }
}
