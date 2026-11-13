import XCTest

final class SecureInputTests: XCTestCase {
    func testTheHolderIsTheSessionsSecureInputProcess() {
        let users: [[String: Any]] = [["kCGSSessionUserNameKey": "alex", "kCGSSessionSecureInputPID": NSNumber(value: 4242)]]
        XCTAssertEqual(SecureInput.pid(in: users), 4242)
    }

    func testNoEntryOrAZeroPidMeansNoHolder() {
        XCTAssertNil(SecureInput.pid(in: []))
        XCTAssertNil(SecureInput.pid(in: [["kCGSSessionUserNameKey": "alex"]]))
        XCTAssertNil(SecureInput.pid(in: [["kCGSSessionSecureInputPID": NSNumber(value: 0)]]))
    }

    func testTheMenuNamesTheAppOrSaysAnotherOne() {
        XCTAssertEqual(SecureInput.Holder(name: "Brave Browser").menuText,
                       "Brave Browser has keyboard input locked, so shortcuts are paused.")
        XCTAssertEqual(SecureInput.Holder(name: nil).menuText,
                       "Another app has keyboard input locked, so shortcuts are paused.")
    }
}
