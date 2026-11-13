import XCTest

final class UpdateAvailabilityTests: XCTestCase {
    private let html = "<ul><li>One thing.</li><li>Another &amp; more.</li></ul>"

    func testNewerVersionIsAvailableWithNotes() {
        var state = UpdateAvailability()
        state.found(version: "0.15.0", description: html, currentVersion: "0.14.0")
        XCTAssertEqual(state.available, AvailableUpdate(version: "0.15.0", notes: ["One thing.", "Another & more."]))
    }

    func testSameOrOlderVersionIsIgnored() {
        var state = UpdateAvailability()
        state.found(version: "0.14.0", description: html, currentVersion: "0.14.0")
        XCTAssertNil(state.available)
        state.found(version: "0.9.0", description: html, currentVersion: "0.14.0")
        XCTAssertNil(state.available)
    }

    func testNotFoundClears() {
        var state = UpdateAvailability()
        state.found(version: "0.15.0", description: nil, currentVersion: "0.14.0")
        XCTAssertEqual(state.available?.notes, [])
        state.notFound()
        XCTAssertNil(state.available)
    }

    func testDotShowsOnlyOnAboutWhileAnUpdateWaits() {
        var state = UpdateAvailability()
        func dots() -> [MainPane] {
            MainPane.allCases.filter { $0.showsUpdateDot(updateAvailable: state.available != nil) }
        }
        XCTAssertEqual(dots(), [])
        state.found(version: "0.15.0", description: html, currentVersion: "0.14.0")
        XCTAssertEqual(dots(), [.about])
        state.notFound()
        XCTAssertEqual(dots(), [])
    }
}
