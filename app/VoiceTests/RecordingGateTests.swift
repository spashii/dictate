import CryptoKit
import VoiceCore
import XCTest

@MainActor
final class RecordingGateTests: XCTestCase {
    private func activation(_ record: ActivationRecord = ActivationRecord()) -> Activation {
        let name = "gate-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return Activation(store: MemoryActivationStore(record), defaults: defaults, keys: [:])
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

    func testAnActivatedMacAllows() throws {
        let signer = Curve25519.Signing.PrivateKey()
        func b64(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let payload = b64(Data(#"{"kid":"k1","sid":"s1a2b3c4d5e6","n":"n1","iat":1794000000}"#.utf8))
        let token = "dct1.\(payload).\(b64(try signer.signature(for: Data("dct1.\(payload)".utf8))))"
        let name = "gate-tests-\(UUID().uuidString)"
        let activation = Activation(store: MemoryActivationStore(ActivationRecord(token: token)),
                                    defaults: UserDefaults(suiteName: name)!, keys: ["k1": signer.publicKey])
        try RecordingGate.check(activation)
    }
}
