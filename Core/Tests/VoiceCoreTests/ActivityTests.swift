import XCTest
@testable import VoiceCore

final class ActivityTests: XCTestCase {
    func testNothingGoingOnIsQuiet() {
        XCTAssertTrue(Activity().isQuiet)
    }

    func testAnyDictationCallOrFixWorkIsNotQuiet() {
        let busy: [Activity] = [
            Activity(dictationRecording: true),
            Activity(dictationTranscribing: true),
            Activity(fixing: true),
            Activity(callRecording: true),
            Activity(callTranscribing: true),
            Activity(callAppInCall: true),
        ]

        XCTAssertEqual(busy.map(\.isQuiet), Array(repeating: false, count: busy.count))
    }
}
