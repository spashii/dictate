import VoiceCore
import XCTest

final class HistoryCorrectionTests: XCTestCase {
    /// The blocks of one split call whose lines are the given texts, all said by one side.
    private func block(_ lines: [String]) throws -> DisplayBlock {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "dictate-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "voice.sqlite")
        let store = try CallStore(url: url)
        let call = try store.createCall(NewCall(split: true))
        _ = try store.appendSegments(call.id, lines.enumerated().map {
            NewCallSegment(channel: .me, startMs: $0.offset * 2000, endMs: $0.offset * 2000 + 1500, text: $0.element)
        })
        let entry = try XCTUnwrap(try store.historyEntries().first)
        let detail = try XCTUnwrap(try store.historyDetail(entry))
        return try XCTUnwrap(DisplayBlock.make(detail, generation: 0).first)
    }

    func testAWordLosesTheMarksAroundIt() throws {
        let block = try block(["ask Alex, then (Acme) too"])
        XCTAssertEqual(block.word(at: 5).map { (block.string as NSString).substring(with: NSRange($0)) }, "Alex")
        XCTAssertEqual(block.word(at: 17).map { (block.string as NSString).substring(with: NSRange($0)) }, "Acme")
        XCTAssertNil(block.word(at: 3))
    }

    func testADragCoversWholeWordsAndStaysInOneLine() throws {
        let block = try block(["we met ana", "at the harbour"])
        let range = try XCTUnwrap(block.phrase(from: 8, to: 5))
        XCTAssertEqual((block.string as NSString).substring(with: NSRange(range)), "met ana")
        let first = try XCTUnwrap(block.lineRange(at: 4))
        XCTAssertEqual((block.string as NSString).substring(with: NSRange(first.range)), "we met ana")
        let second = try XCTUnwrap(block.lineRange(at: 14))
        XCTAssertEqual((block.string as NSString).substring(with: NSRange(second.range)), "at the harbour")
    }
}
