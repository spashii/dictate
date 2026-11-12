import AppKit
import SwiftUI
import XCTest
@testable import VoiceCore

/// A History line is as tall as its wrapped text, whatever sits beside it: a long line once
/// drew over the rows under it because a line with no play button measured as one line.
@MainActor
final class HistoryLayoutTests: XCTestCase {
    private let long = String(repeating: "A long sentence that has to wrap onto several lines of the window. ", count: 6)
    private let start = Date(timeIntervalSince1970: 1_794_514_804)

    private func height<V: View>(_ view: V, width: CGFloat = 560) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        return host.fittingSize.height
    }

    private func line(_ text: String, flagged: Bool, speaker: String?) -> HistoryLineView {
        let entry = HistoryEntry(kind: .call, ref: "c", at: start, timeZone: "Europe/Amsterdam", duration: 20, title: "Call",
                                 changes: 0, audioPath: "/tmp/none.m4a")
        let line = HistoryLine(id: 1, speaker: speaker, t0: 9, t1: 12, whisper: text, flagged: flagged, changes: [])
        return HistoryLineView(line: line, entry: entry, audioPath: "/tmp/none.m4a", player: SegmentPlayer(), times: .clock)
    }

    func testALongLineWithNoPlayButtonIsAsTallAsItsWrappedText() {
        let one = height(line("Great.", flagged: false, speaker: "Call"))
        let wrapped = height(line(long, flagged: false, speaker: "Me"))

        XCTAssertGreaterThan(one, 8)
        XCTAssertGreaterThan(wrapped, one * 4, "six sentences wrap onto at least five lines")
    }

    func testALongPlayableLineIsAsTallAsItsText() {
        let one = height(line("Great.", flagged: true, speaker: "Call"))
        let playable = height(line(long, flagged: true, speaker: "Me"))

        XCTAssertGreaterThan(playable, one * 4)
    }

    /// Draws four lines, two of them long, and counts the blank bands between the lines' text.
    /// A line that is shorter than its text draws over the next, and its band disappears.
    func testLongLinesDoNotDrawOverTheLinesUnderThem() throws {
        let entry = HistoryEntry(kind: .call, ref: "c", at: start, timeZone: "Europe/Amsterdam", duration: 20, title: "Call",
                                 changes: 0, audioPath: nil)
        let texts = [(long, "Call"), (long, "Me"), ("Great.", "Call"), ("One more thing.", "Me")]
        let lines = texts.enumerated().map { i, t in
            HistoryLine(id: i, speaker: t.1, t0: Double(i * 8), t1: Double(i * 8 + 5), whisper: t.0, flagged: false, changes: [])
        }
        let detail = HistoryDetail(entry: entry, audioPath: nil, lines: lines, textChanges: [])
        let width: CGFloat = 560
        let host = NSHostingView(rootView: HistoryDetailContent(detail: detail, player: SegmentPlayer(), times: .constant(.clock))
            .frame(width: width, height: 900, alignment: .top).background(Color.white))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.display()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        // The text column, below the header. Ink is anything dark.
        let scale = CGFloat(rep.pixelsWide) / width
        let from = Int(110 * scale), to = Int(width * scale) - 4
        var inked: [Bool] = []
        for y in Int(40 * scale)..<rep.pixelsHigh {
            inked.append((from..<to).contains { x in
                (rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceGray)?.whiteComponent ?? 1) < 0.5
            })
        }
        // Blank runs of at least a full line gap that sit between ink, not before or after it.
        let first = try XCTUnwrap(inked.firstIndex(of: true)), last = try XCTUnwrap(inked.lastIndex(of: true))
        var gaps = 0, run = 0
        for ink in inked[first...last] {
            if ink {
                if CGFloat(run) >= 8 * scale { gaps += 1 }
                run = 0
            } else {
                run += 1
            }
        }
        XCTAssertEqual(gaps, lines.count - 1, "each line has its own band")
    }

    func testARowWithALongTitleKeepsItsHeight() {
        let entry = HistoryEntry(kind: .dictation, ref: "d", at: start, duration: 5, title: long, changes: 0)
        let short = HistoryEntry(kind: .dictation, ref: "d", at: start, duration: 5, title: "Short", changes: 0)

        XCTAssertGreaterThan(height(HistoryRow(entry: entry, copy: { true }), width: 260),
                             height(HistoryRow(entry: short, copy: { true }), width: 260))
    }
}
