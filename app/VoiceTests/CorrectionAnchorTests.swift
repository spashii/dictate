import XCTest

final class CorrectionAnchorTests: XCTestCase {
    func testARedrawClosesAnEditorThatIsNotSaving() {
        XCTAssertTrue(CorrectionAnchor(range: 10..<20).closesOnRefresh)
    }

    func testARedrawKeepsTheConfirmationAndPointsItAtTheNewWords() {
        var anchor = CorrectionAnchor(range: 10..<20)
        anchor.hold(replacement: "Northwind")
        XCTAssertFalse(anchor.closesOnRefresh)
        XCTAssertEqual(anchor.range, 10..<19)
    }

    func testAFailedSaveGoesBackToAnEditorTheRedrawCloses() {
        var anchor = CorrectionAnchor(range: 10..<20)
        anchor.hold(replacement: "Northwind")
        anchor.release()
        XCTAssertTrue(anchor.closesOnRefresh)
        XCTAssertEqual(anchor.range, 10..<20)
    }
}
