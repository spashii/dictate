import XCTest

final class BundleRenameTests: XCTestCase {
    func testAnOldNamedBundleMovesBesideItself() {
        let url = URL(fileURLWithPath: "/Applications/Voice.app")
        XCTAssertEqual(BundleRename.destination(for: url, exists: { _ in false })?.path, "/Applications/Dictate.app")
    }

    func testADictateAppThatExistsIsNeverReplaced() {
        let url = URL(fileURLWithPath: "/Applications/Voice.app")
        XCTAssertNil(BundleRename.destination(for: url, exists: { _ in true }))
    }

    func testOtherNamesStay() {
        XCTAssertNil(BundleRename.destination(for: URL(fileURLWithPath: "/Applications/Dictate.app"), exists: { _ in false }))
        XCTAssertNil(BundleRename.destination(for: URL(fileURLWithPath: "/tmp/Voice 2.app"), exists: { _ in false }))
    }
}
