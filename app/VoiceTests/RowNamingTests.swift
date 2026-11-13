import VoiceCore
import XCTest

final class RowNamingTests: XCTestCase {
    private func entry(_ kind: HistoryEntry.Kind, ref: String = "short", file: String? = nil,
                       customTitle: String? = nil) -> HistoryEntry {
        HistoryEntry(kind: kind, ref: ref, at: Date(), duration: 240, title: "", changes: 0,
                     customTitle: customTitle, fileName: file)
    }

    func testAnUntitledCallBeingNamedShowsIt() {
        XCTAssertTrue(RowNaming.shows(entry(.call), naming: ["short"], importState: nil))
        XCTAssertFalse(RowNaming.shows(entry(.call), naming: ["other"], importState: nil))
        XCTAssertFalse(RowNaming.shows(entry(.call), naming: [], importState: nil))
    }

    func testOnlyAnUntitledCallIsNamed() {
        XCTAssertFalse(RowNaming.shows(entry(.dictation), naming: ["short"], importState: nil))
        XCTAssertFalse(RowNaming.shows(entry(.call, customTitle: "Budget"), naming: ["short"], importState: nil))
    }

    func testAnImportShowsItsOwnState() {
        let file = entry(.call, file: "Standup.m4a")
        XCTAssertFalse(RowNaming.shows(file, naming: ["short"], importState: .transcribing(0.3)))
        XCTAssertFalse(RowNaming.shows(file, naming: ["short"], importState: .waiting))
        XCTAssertFalse(RowNaming.shows(file, naming: ["short"], importState: .failed("No audio.")))
        XCTAssertTrue(RowNaming.shows(file, naming: ["short"], importState: .ready))
    }

    func testTheLabelUsesTheEllipsisCharacter() {
        XCTAssertEqual(RowNaming.label, "Naming\u{2026}")
    }
}
