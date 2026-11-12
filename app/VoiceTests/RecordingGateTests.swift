import VoiceCore
import XCTest

@MainActor
final class RecordingGateTests: XCTestCase {
    private func activation(_ record: ActivationRecord = ActivationRecord(), now: Date = Date()) -> Activation {
        let name = "gate-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return Activation(store: MemoryActivationStore(record), defaults: defaults, now: { now }, keys: [:])
    }

    func testLockedRefusesWithTheAgentsMessage() {
        XCTAssertThrowsError(try RecordingGate.check(activation())) {
            XCTAssertEqual("\($0)", "Dictate is not activated yet")
        }
    }

    func testPendingStillRefuses() {
        let locked = activation()
        locked.begin()
        XCTAssertThrowsError(try RecordingGate.check(locked))
    }

    func testGraceAllows() throws {
        let now = Date()
        try RecordingGate.check(activation(ActivationRecord(graceStart: now.addingTimeInterval(-3600)), now: now))
    }

    func testAnEndedGraceRefuses() {
        let now = Date()
        let ended = ActivationRecord(graceStart: now.addingTimeInterval(-8 * 24 * 3600))
        XCTAssertThrowsError(try RecordingGate.check(activation(ended, now: now)))
    }
}
