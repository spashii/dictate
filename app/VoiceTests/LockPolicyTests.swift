import CryptoKit
import VoiceCore
import XCTest

@MainActor
final class LockPolicyTests: XCTestCase {
    private let signer = Curve25519.Signing.PrivateKey()

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func token(nonce: String) throws -> String {
        let payload = base64url(Data(#"{"kid":"k1","sid":"s1a2b3c4d5e6","n":"\#(nonce)","iat":1794000000}"#.utf8))
        let signature = try signer.signature(for: Data("dct1.\(payload)".utf8))
        return "dct1.\(payload).\(base64url(signature))"
    }

    private func link(nonce: String) throws -> URL {
        URL(string: "in.firstversion.dictate://activate?t=\(try token(nonce: nonce))")!
    }

    private func makeActivation(_ store: MemoryActivationStore = MemoryActivationStore(), now: Date = Date()) -> Activation {
        let name = "lock-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return Activation(store: store, defaults: defaults, now: { now }, keys: ["k1": signer.publicKey],
                          makeNonce: { "n1" })
    }

    func testLockedReachesOnlyWelcomeAndAbout() {
        let policy = LockPolicy(makeActivation())
        XCTAssertEqual(MainPane.allCases.filter(policy.reaches), [.welcome, .about])
        for pane in MainPane.allCases where pane != .about {
            XCTAssertEqual(policy.landing(for: pane), .welcome)
        }
        XCTAssertEqual(policy.landing(for: .about), .about)
        XCTAssertFalse(policy.showsRecordingMenu)
    }

    func testLockedKeepsHotkeysAndTheAgentServerOff() {
        var enabled = 0, disabled = 0
        let hotkeys = Hotkeys(enable: { enabled += 1 }, disable: { disabled += 1 })
        let policy = LockPolicy(makeActivation())
        hotkeys.apply(policy)
        XCTAssertFalse(hotkeys.isRegistered)
        XCTAssertFalse(policy.startsAgentServer)
        XCTAssertEqual(disabled, 1)
        XCTAssertEqual(enabled, 0)
    }

    func testAcceptRegistersTheHotkeysAndOpensEverything() throws {
        var enabled = 0
        let hotkeys = Hotkeys(enable: { enabled += 1 }, disable: {})
        let activation = makeActivation()
        hotkeys.apply(LockPolicy(activation))
        activation.begin()
        try activation.accept(url: link(nonce: "n1")).get()
        let policy = LockPolicy(activation)
        hotkeys.apply(policy)
        XCTAssertTrue(hotkeys.isRegistered)
        XCTAssertEqual(enabled, 1)
        XCTAssertTrue(policy.startsAgentServer)
        XCTAssertTrue(policy.showsRecordingMenu)
        XCTAssertEqual(MainPane.allCases.filter(policy.reaches), MainPane.allCases)
    }

    func testAWrongTokenLeavesItLocked() throws {
        let hotkeys = Hotkeys(enable: { XCTFail("registered") }, disable: {})
        let activation = makeActivation()
        activation.begin()
        _ = activation.accept(url: try link(nonce: "other"))
        hotkeys.apply(LockPolicy(activation))
        XCTAssertFalse(hotkeys.isRegistered)
    }

    func testGraceRegistersThenTheEndUnregisters() {
        let start = Date()
        var now = start
        let store = MemoryActivationStore(ActivationRecord(graceStart: start))
        let name = "lock-tests-\(UUID().uuidString)"
        let activation = Activation(store: store, defaults: UserDefaults(suiteName: name)!, now: { now }, keys: [:])
        var log: [String] = []
        let hotkeys = Hotkeys(enable: { log.append("on") }, disable: { log.append("off") })
        hotkeys.apply(LockPolicy(activation))
        now = start.addingTimeInterval(8 * 24 * 3600)
        activation.refresh()
        hotkeys.apply(LockPolicy(activation))
        XCTAssertEqual(log, ["on", "off"])
    }

    func testApplyingTwiceRegistersOnce() {
        var enabled = 0
        let hotkeys = Hotkeys(enable: { enabled += 1 }, disable: {})
        hotkeys.apply(LockPolicy(unlocked: true))
        hotkeys.apply(LockPolicy(unlocked: true))
        XCTAssertEqual(enabled, 1)
    }

    func testAGraceThatEndsMidRecordingKeepsTheWayToStop() {
        let unlocked = LockPolicy(unlocked: true), locked = LockPolicy(unlocked: false)
        XCTAssertEqual(LockPolicy.next(current: locked, applied: unlocked, recording: true), unlocked)
        XCTAssertEqual(LockPolicy.next(current: locked, applied: unlocked, recording: false), locked)
        XCTAssertEqual(LockPolicy.next(current: unlocked, applied: locked, recording: true), locked)
        XCTAssertEqual(LockPolicy.next(current: locked, applied: nil, recording: true), locked)
    }

    func testTheHotkeysStayOnUntilTheRecordingEnds() {
        let start = Date()
        var now = start
        let store = MemoryActivationStore(ActivationRecord(graceStart: start))
        let activation = Activation(store: store, defaults: UserDefaults(suiteName: "lock-\(UUID().uuidString)")!,
                                    now: { now }, keys: [:])
        var log: [String] = []
        let hotkeys = Hotkeys(enable: { log.append("on") }, disable: { log.append("off") })
        var applied = LockPolicy(activation)
        hotkeys.apply(applied)
        now = start.addingTimeInterval(8 * 24 * 3600)
        activation.refresh()
        applied = LockPolicy.next(current: LockPolicy(activation), applied: applied, recording: true)
        hotkeys.apply(applied)
        XCTAssertEqual(log, ["on"])
        applied = LockPolicy.next(current: LockPolicy(activation), applied: applied, recording: false)
        hotkeys.apply(applied)
        XCTAssertEqual(log, ["on", "off"])
    }

    func testForcingRegistersAgainForALateHandler() {
        var disabled = 0
        let hotkeys = Hotkeys(enable: {}, disable: { disabled += 1 })
        hotkeys.apply(LockPolicy(unlocked: false))
        hotkeys.apply(LockPolicy(unlocked: false), force: true)
        XCTAssertEqual(disabled, 2)
    }
}
