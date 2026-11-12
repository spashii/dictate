import XCTest

final class OtherInstanceTests: XCTestCase {
    func testNothingRunningNeverAsks() {
        var asked = false
        XCTAssertTrue(OtherInstance.clear(running: { 0 }, askToQuit: { asked = true }, pause: { _ in }))
        XCTAssertFalse(asked)
    }

    func testAnInstanceThatQuitsClearsTheWay() {
        var count = 1
        var asked = false
        let cleared = OtherInstance.clear(running: { count }, askToQuit: { asked = true },
                                          pause: { _ in count = 0 })
        XCTAssertTrue(cleared)
        XCTAssertTrue(asked)
    }

    func testAnInstanceThatWontQuitBlocksAfterTheTimeout() {
        var paused = 0.0
        let cleared = OtherInstance.clear(running: { 1 }, askToQuit: {}, pause: { paused += $0 }, timeout: 1, step: 0.25)
        XCTAssertFalse(cleared)
        XCTAssertEqual(paused, 1, accuracy: 0.01)
    }
}
