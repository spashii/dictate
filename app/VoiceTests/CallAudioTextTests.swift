import XCTest

final class CallAudioTextTests: XCTestCase {
    func testStatusSaysWhatTheAppDoes() {
        XCTAssertEqual(CallAudioText.status(playing: true, listening: true), "In a call, playing sound")
        XCTAssertEqual(CallAudioText.status(playing: false, listening: true), "Using the microphone")
        XCTAssertEqual(CallAudioText.status(playing: true, listening: false), "Playing sound")
        XCTAssertNil(CallAudioText.status(playing: false, listening: false))
    }

    func testLevelIsAWordNotANumber() {
        XCTAssertEqual(CallAudioText.level(0), "silent")
        XCTAssertEqual(CallAudioText.level(0.05), "quiet")
        XCTAssertEqual(CallAudioText.level(0.2), "medium")
        XCTAssertEqual(CallAudioText.level(0.9), "loud")
    }

    func testAccessibilityValueJoinsStateLevelAndSelection() {
        XCTAssertEqual(CallAudioText.accessibilityValue(status: "Playing sound", level: 0.2, selected: true),
                       "Playing sound, level medium, selected")
        XCTAssertEqual(CallAudioText.accessibilityValue(status: nil, level: nil, selected: false), "")
    }
}
