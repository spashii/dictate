import BlendKit
import Foundation
import Testing

@Suite struct ThirdPartyNoticesTests {
    private func notices() throws -> String {
        // Core/Tests/VoiceCoreTests/<this file> up to the repository root.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "THIRD_PARTY_NOTICES.md"), encoding: .utf8)
    }

    /// The binary BlendKit ships holds these, so a release without their notices would break
    /// their licenses.
    @Test func everyComponentInsideBlendKitHasItsNotice() throws {
        let text = try notices()
        #expect(!BlendKit.thirdPartyComponents.isEmpty)
        for component in BlendKit.thirdPartyComponents {
            #expect(text.contains("## \(component.name)"), "no section for \(component.name)")
            #expect(text.contains(component.url), "no link to \(component.url)")
        }
    }

    @Test func blendKitItselfHasASection() throws {
        #expect(try notices().contains("## BlendKit"))
    }
}
