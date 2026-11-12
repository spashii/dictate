import Foundation
import XCTest

final class BlendMicTests: XCTestCase {
    func testAnInputNamedBlendCounts() {
        XCTAssertTrue(BlendMic.isInstalled(inputNames: ["MacBook Pro Microphone", "Blend Mic"], appURL: nil))
    }

    func testTheAppAloneCounts() {
        XCTAssertTrue(BlendMic.isInstalled(inputNames: [], appURL: URL(fileURLWithPath: "/Applications/Blend.app")))
    }

    func testNeitherMeansNotInstalled() {
        XCTAssertFalse(BlendMic.isInstalled(inputNames: ["MacBook Pro Microphone", "USB Mic"], appURL: nil))
    }

    func testTheWebsiteIsBlendsPage() {
        XCTAssertEqual(BlendMic.website.absoluteString, "https://spashii.github.io/blend/")
        XCTAssertEqual(BlendMic.bundleID, "app.blend.Blend")
    }
}
