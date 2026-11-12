import CoreGraphics
import XCTest

final class PillHoverTests: XCTestCase {
    func testOpacityIsFullUntilTheMouseIsOver() {
        XCTAssertEqual(PillHover.opacity(hovered: false), 1)
        XCTAssertEqual(PillHover.opacity(hovered: true), 0.25)
    }

    func testPointerInsideAFrame() {
        let frames = [CGRect(x: 100, y: 4, width: 200, height: 32), CGRect(x: 90, y: 44, width: 220, height: 60)]
        XCTAssertTrue(PillHover.isOver(CGPoint(x: 150, y: 20), frames: frames))
        XCTAssertTrue(PillHover.isOver(CGPoint(x: 150, y: 80), frames: frames))
        XCTAssertFalse(PillHover.isOver(CGPoint(x: 50, y: 20), frames: frames))
        XCTAssertFalse(PillHover.isOver(CGPoint(x: 150, y: 40), frames: frames))
        XCTAssertFalse(PillHover.isOver(CGPoint(x: 150, y: 20), frames: []))
    }

    /// Screen coordinates grow upward from the bottom left, the panel's downward from its top left.
    func testScreenPointInThePanelsCoordinates() {
        let panel = CGRect(x: 500, y: 700, width: 440, height: 190)
        XCTAssertEqual(PillHover.inPanel(CGPoint(x: 520, y: 880), panel: panel), CGPoint(x: 20, y: 10))
        XCTAssertEqual(PillHover.inPanel(CGPoint(x: 500, y: 890), panel: panel), CGPoint(x: 0, y: 0))
    }
}
