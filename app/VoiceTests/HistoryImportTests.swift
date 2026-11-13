import VoiceCore
import XCTest

final class HistoryImportTests: XCTestCase {
    private func entry(_ kind: HistoryEntry.Kind, file: String? = nil, duration: Double = 60,
                       error: String? = nil) -> HistoryEntry {
        HistoryEntry(kind: kind, ref: "x", at: Date(), duration: duration, title: "", changes: 0,
                     fileName: file, error: error)
    }

    func testFiltersSplitCallsFromFiles() {
        let dictation = entry(.dictation)
        let call = entry(.call)
        let file = entry(.call, file: "Standup.m4a")
        XCTAssertEqual([dictation, call, file].filter(HistoryFilter.all.includes), [dictation, call, file])
        XCTAssertEqual([dictation, call, file].filter(HistoryFilter.dictations.includes), [dictation])
        XCTAssertEqual([dictation, call, file].filter(HistoryFilter.calls.includes), [call])
        XCTAssertEqual([dictation, call, file].filter(HistoryFilter.files.includes), [file])
        XCTAssertEqual(HistoryFilter.allCases.map(\.rawValue), ["All", "Dictations", "Calls", "Files"])
    }

    func testRowStateOfAnImport() {
        let file = entry(.call, file: "Standup.m4a", duration: 0)
        XCTAssertEqual(ImportRowState.of(file, progress: nil, waiting: true), .waiting)
        XCTAssertEqual(ImportRowState.of(file, progress: 0.4, waiting: false), .transcribing(0.4))
        XCTAssertEqual(ImportRowState.of(file, progress: nil, waiting: false), .ready)
        let failed = entry(.call, file: "Standup.m4a", error: "This file has no audio Dictate can read.")
        XCTAssertEqual(ImportRowState.of(failed, progress: nil, waiting: false),
                       .failed("This file has no audio Dictate can read."))
    }

    func testRecordingsHaveNoImportState() {
        XCTAssertNil(ImportRowState.of(entry(.call), progress: 0.5, waiting: true))
        XCTAssertNil(ImportRowState.of(entry(.dictation), progress: nil, waiting: false))
    }

    func testDurationHidesOnlyForAnImportNotYetRead() {
        XCTAssertFalse(ImportRowState.showsDuration(entry(.call, file: "a.m4a", duration: 0)))
        XCTAssertTrue(ImportRowState.showsDuration(entry(.call, file: "a.m4a", duration: 12)))
        XCTAssertTrue(ImportRowState.showsDuration(entry(.dictation, duration: 0)))
    }

    func testDropKeepsSupportedFilesInOrder() {
        let urls = ["/a/one.MP3", "/a/notes.txt", "/a/two.mov", "/a/photo.png"].map { URL(fileURLWithPath: $0) }
        XCTAssertEqual(ImportDrop.supported(urls).map(\.lastPathComponent), ["one.MP3", "two.mov"])
        XCTAssertTrue(ImportDrop.supported([URL(fileURLWithPath: "/a/notes.txt")]).isEmpty)
        XCTAssertTrue(ImportDrop.supported([URL(string: "https://example.com/a.mp3")!]).isEmpty)
    }

    func testNoPasteIntoDictateItself() {
        XCTAssertFalse(PasteDecision.pastes(frontmostPID: 42, ownPID: 42))
        XCTAssertTrue(PasteDecision.pastes(frontmostPID: 7, ownPID: 42))
        XCTAssertTrue(PasteDecision.pastes(frontmostPID: nil, ownPID: 42))
    }
}
