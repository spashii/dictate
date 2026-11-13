import VoiceCore
import XCTest

final class RecentCallLabelTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 720_000_000)

    private func call(title: String? = nil, app: String? = "Slack", minutes: Double? = 32,
                      status: Call.Status = .done) -> Call {
        var json: [String: Any] = [
            "id": "c", "startedAt": start.timeIntervalSinceReferenceDate, "appName": app as Any,
            "split": true, "status": status.rawValue, "tags": [String](),
        ]
        if let minutes { json["endedAt"] = start.addingTimeInterval(minutes * 60).timeIntervalSinceReferenceDate }
        if let title { json["title"] = title }
        if app == nil { json.removeValue(forKey: "appName") }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Call.self, from: data)
    }

    private func lines(_ call: Call) -> RecentCallLabel.Lines {
        RecentCallLabel.lines(call, time: { _ in "14:05" })
    }

    func testUntitledKeepsTodaysLine() {
        XCTAssertEqual(lines(call()), .init(title: nil, detail: "Slack call, 14:05 \u{00B7} 32 min"))
        XCTAssertEqual(lines(call(app: nil)).detail, "Call, 14:05 \u{00B7} 32 min")
    }

    func testTitledPutsTheTitleFirstAndTheLineUnderIt() {
        XCTAssertEqual(lines(call(title: "Northwind rollout with Alex")),
                       .init(title: "Northwind rollout with Alex", detail: "Slack call, 14:05 \u{00B7} 32 min"))
    }

    func testALongTitleIsCutToSixtyCharacters() {
        let long = String(repeating: "word ", count: 20)
        let title = lines(call(title: long)).title!
        XCTAssertEqual(title.count, 60)
        XCTAssertTrue(title.hasSuffix("\u{2026}"))
        let exact = String(repeating: "a", count: 60)
        XCTAssertEqual(lines(call(title: exact)).title, exact)
    }

    func testFailedAndRecordingShowInTheLine() {
        XCTAssertEqual(lines(call(status: .failed)).detail, "Slack call, 14:05 \u{00B7} 32 min \u{00B7} failed")
        XCTAssertEqual(lines(call(minutes: nil, status: .recording)).detail, "Slack call, 14:05 \u{00B7} recording")
        XCTAssertEqual(lines(call(title: "Plan", status: .failed)).detail, "Slack call, 14:05 \u{00B7} 32 min \u{00B7} failed")
    }

    func testABlankTitleCountsAsUntitled() {
        XCTAssertNil(lines(call(title: "  ")).title)
    }
}
