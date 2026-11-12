import XCTest

final class BundleRenameTests: XCTestCase {
    private let old = URL(fileURLWithPath: "/Applications/Voice.app")

    func testAnOldNamedBundleMovesBesideItself() {
        XCTAssertEqual(BundleRename.destination(for: old, exists: { _ in false })?.path, "/Applications/Dictate.app")
    }

    func testADictateAppThatExistsIsNeverReplaced() {
        XCTAssertNil(BundleRename.destination(for: old, exists: { _ in true }))
    }

    func testOtherNamesStay() {
        XCTAssertNil(BundleRename.destination(for: URL(fileURLWithPath: "/Applications/Dictate.app"), exists: { _ in false }))
        XCTAssertNil(BundleRename.destination(for: URL(fileURLWithPath: "/tmp/Voice 2.app"), exists: { _ in false }))
    }

    /// A successful move hands back the new path: the caller starts from there and exits.
    func testASuccessfulMoveReturnsTheNewPath() {
        var moved: (URL, URL)?
        let result = BundleRename.renameIfNeeded(bundle: old, exists: { _ in false }, move: { moved = ($0, $1) })
        XCTAssertEqual(result?.path, "/Applications/Dictate.app")
        XCTAssertEqual(moved?.0, old)
        XCTAssertEqual(moved?.1.path, "/Applications/Dictate.app")
    }

    /// A failed move keeps running from where it is: no relaunch.
    func testAFailedMoveStaysPut() {
        struct Denied: Error {}
        XCTAssertNil(BundleRename.renameIfNeeded(bundle: old, exists: { _ in false }, move: { _, _ in throw Denied() }))
    }

    func testNothingMovesForAnAlreadyRenamedBundle() {
        var called = false
        let result = BundleRename.renameIfNeeded(bundle: URL(fileURLWithPath: "/Applications/Dictate.app"),
                                                 exists: { _ in false }, move: { _, _ in called = true })
        XCTAssertNil(result)
        XCTAssertFalse(called)
    }

    func testTheRelaunchOpensANewInstanceAtTheNewPath() {
        let command = BundleRename.relaunchCommand(for: URL(fileURLWithPath: "/Applications/Dictate.app"))
        XCTAssertEqual(command.executable, "/usr/bin/open")
        XCTAssertEqual(command.arguments, ["-n", "/Applications/Dictate.app"])
    }
}
