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

    private func item(hasTitle: Bool = false, canTitle: Bool = true, busy: Bool = false, chosen: LocalModel = .apple,
                      apple: AppleModelState = .available, ollama: [String]? = nil) -> TitleRequest.Item {
        TitleRequest.item(hasTitle: hasTitle, canTitle: canTitle, busy: busy, chosen: chosen, apple: apple, ollamaModels: ollama)
    }

    func testTheRowMenuSaysGenerateOrRegenerate() {
        XCTAssertEqual(item(hasTitle: false).label, "Generate Title")
        XCTAssertEqual(item(hasTitle: true).label, "Regenerate Title")
        XCTAssertTrue(item(hasTitle: true).enabled)
        XCTAssertNil(item(hasTitle: true).hint)
    }

    func testTheRowMenuItemIsDisabledForShortTextOrABusyRow() {
        XCTAssertFalse(item(canTitle: false).enabled)
        XCTAssertFalse(item(busy: true).enabled)
    }

    func testWithNoModelTheItemIsDisabledAndGivesTheReason() {
        let none = item(hasTitle: true, chosen: .apple, apple: .turnedOff, ollama: nil)
        XCTAssertFalse(none.enabled)
        XCTAssertEqual(none.label, "Regenerate Title")
        XCTAssertEqual(none.hint, "Start Ollama or turn on Apple Intelligence.")
    }

    func testOnlyTheChosenModelCounts() {
        let ollamaDown = item(chosen: .ollama("llama3"), apple: .available, ollama: nil)
        XCTAssertFalse(ollamaDown.enabled)
        XCTAssertEqual(ollamaDown.hint, "Start Ollama.")
        let missing = item(chosen: .ollama("llama3"), apple: .available, ollama: ["qwen"])
        XCTAssertFalse(missing.enabled)
        XCTAssertEqual(missing.hint, "Add llama3 in Ollama.")
        let appleOff = item(chosen: .apple, apple: .turnedOff, ollama: ["qwen"])
        XCTAssertFalse(appleOff.enabled)
        XCTAssertEqual(appleOff.hint, "Turn on Apple Intelligence.")
        XCTAssertTrue(item(chosen: .ollama("qwen"), apple: .turnedOff, ollama: ["qwen"]).enabled)
    }
}
