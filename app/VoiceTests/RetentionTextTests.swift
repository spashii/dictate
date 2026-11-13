import VoiceCore
import XCTest

final class RetentionTextTests: XCTestCase {
    private func body(_ recordings: Int, _ audioOnly: Int, _ audio: AudioRetention = .sevenDays,
                      _ transcripts: TranscriptRetention = .thirtyDays) -> String {
        RetentionText.body(counts: RetentionCounts(recordings: recordings, audioOnly: audioOnly),
                           policy: RetentionPolicy(audio: audio, transcripts: transcripts))
    }

    func testBothParts() {
        XCTAssertEqual(body(40, 12),
                       "Dictate will delete 40 recordings older than 30 days and the audio of 12 more older than 7 days. You can\u{2019}t undo this.")
    }

    func testOnlyRecordings() {
        XCTAssertEqual(body(3, 0, .sevenDays, .sevenDays),
                       "Dictate will delete 3 recordings older than 7 days. You can\u{2019}t undo this.")
    }

    func testOnlyAudio() {
        XCTAssertEqual(body(0, 12),
                       "Dictate will delete the audio of 12 recordings older than 7 days. You can\u{2019}t undo this.")
    }

    func testSingular() {
        XCTAssertEqual(body(1, 0), "Dictate will delete 1 recording older than 30 days. You can\u{2019}t undo this.")
        XCTAssertEqual(body(0, 1), "Dictate will delete the audio of 1 recording older than 7 days. You can\u{2019}t undo this.")
        XCTAssertEqual(body(1, 1),
                       "Dictate will delete 1 recording older than 30 days and the audio of 1 more older than 7 days. You can\u{2019}t undo this.")
    }

    func testUntilTranscribedPhrasing() {
        XCTAssertEqual(body(0, 4, .untilTranscribed),
                       "Dictate will delete the audio of 4 recordings that are already transcribed. You can\u{2019}t undo this.")
        XCTAssertEqual(body(2, 4, .untilTranscribed),
                       "Dictate will delete 2 recordings older than 30 days and the audio of 4 more that are already transcribed. You can\u{2019}t undo this.")
    }

    func testOneDayPhrasing() {
        XCTAssertEqual(body(0, 2, .oneDay),
                       "Dictate will delete the audio of 2 recordings older than 1 day. You can\u{2019}t undo this.")
    }

    func testNothingToDeleteHasNoBody() {
        XCTAssertEqual(body(0, 0), "")
    }

    func testAlertsCarryTheBodyAndTheirButtons() {
        let counts = RetentionCounts(recordings: 2, audioOnly: 0)
        let policy = RetentionPolicy(audio: .sevenDays, transcripts: .sevenDays)
        let off = RetentionText.turnOffDeveloperMode(counts: counts, policy: policy)
        XCTAssertEqual(off.title, "Turn off Developer mode?")
        XCTAssertEqual(off.confirm, "Turn Off and Delete")
        XCTAssertEqual(off.cancel, "Cancel")
        XCTAssertEqual(off.body, RetentionText.body(counts: counts, policy: policy))
        let change = RetentionText.deleteOldRecordings(counts: counts, policy: policy)
        XCTAssertEqual(change.title, "Delete old recordings?")
        XCTAssertEqual(change.confirm, "Delete")
    }

    func testForeverAudioIsOfferedOnlyInDeveloperMode() {
        XCTAssertEqual(RetentionText.audioOptions(developerMode: true), [.untilTranscribed, .oneDay, .sevenDays, .forever])
        XCTAssertEqual(RetentionText.audioOptions(developerMode: false), [.untilTranscribed, .oneDay, .sevenDays])
        XCTAssertEqual(RetentionText.transcriptOptions, [.sevenDays, .thirtyDays, .forever])
    }

    func testOptionTitles() {
        XCTAssertEqual(AudioRetention.allCases.map(RetentionText.title), ["Until transcribed", "1 day", "7 days", "Forever"])
        XCTAssertEqual(TranscriptRetention.allCases.map(RetentionText.title), ["7 days", "30 days", "Forever"])
    }
}
