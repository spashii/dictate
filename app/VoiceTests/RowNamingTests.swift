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

    func testADictationOrATitledRecordingShowsItWhileATitleIsMade() {
        XCTAssertTrue(RowNaming.shows(entry(.dictation), naming: ["short"], importState: nil))
        XCTAssertTrue(RowNaming.shows(entry(.call, customTitle: "Budget"), naming: ["short"], importState: nil))
        XCTAssertFalse(RowNaming.shows(entry(.dictation), naming: ["other"], importState: nil))
    }

    func testAnImportShowsItsOwnState() {
        let file = entry(.call, file: "Standup.m4a")
        XCTAssertFalse(RowNaming.shows(file, naming: ["short"], importState: .transcribing(0.3)))
        XCTAssertFalse(RowNaming.shows(file, naming: ["short"], importState: .waiting))
        XCTAssertFalse(RowNaming.shows(file, naming: ["short"], importState: .failed("No audio.")))
        XCTAssertTrue(RowNaming.shows(file, naming: ["short"], importState: .ready))
    }

    func testTheLabelUsesTheEllipsisCharacter() {
        XCTAssertEqual(RowNaming.label, "Generating title\u{2026}")
    }

    func testTheRowMenuSaysGenerateOrRegenerate() {
        func item(hasTitle: Bool) -> TitleRequest.Item {
            TitleRequest.item(hasTitle: hasTitle, canTitle: true, busy: false, noModelCanRun: false, noModelHint: "")
        }
        XCTAssertEqual(item(hasTitle: false).label, "Generate Title")
        XCTAssertEqual(item(hasTitle: true).label, "Regenerate Title")
        XCTAssertTrue(item(hasTitle: true).enabled)
        XCTAssertNil(item(hasTitle: true).hint)
    }

    func testTheRowMenuItemIsDisabledForShortTextOrABusyRow() {
        XCTAssertFalse(TitleRequest.item(hasTitle: false, canTitle: false, busy: false, noModelCanRun: false, noModelHint: "").enabled)
        XCTAssertFalse(TitleRequest.item(hasTitle: false, canTitle: true, busy: true, noModelCanRun: false, noModelHint: "").enabled)
    }

    func testWithNoModelTheItemIsDisabledAndGivesTheReason() {
        let item = TitleRequest.item(hasTitle: true, canTitle: true, busy: false, noModelCanRun: true,
                                     noModelHint: "Start Ollama or turn on Apple Intelligence.")
        XCTAssertFalse(item.enabled)
        XCTAssertEqual(item.label, "Regenerate Title")
        XCTAssertEqual(item.hint, "Start Ollama or turn on Apple Intelligence.")
    }
}
