import XCTest
@testable import AppleMusicLyrics

final class LyricDisplayItemTests: XCTestCase {
    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> LyricWord {
        LyricWord(text: text, start: start, end: end)
    }

    private func document(_ lines: [LyricLine], synced: Bool = true) -> LyricsDocument {
        LyricsDocument(
            lines: lines,
            plainText: nil,
            source: "test",
            isSynced: synced,
            wordTiming: lines.contains { !$0.words.isEmpty } ? .exact : .none
        )
    }

    func testIntroInterludeBeforeLateFirstLine() {
        let items = LyricDisplayItem.makeItems(from: document([
            LyricLine(time: 9, text: "Hello", words: [word("Hello", 9, 10)])
        ]))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].kind, .interlude)
        XCTAssertEqual(items[0].start, 0)
        XCTAssertEqual(items[0].end, 9)
        XCTAssertEqual(items[1].line?.text, "Hello")
    }

    func testNoIntroForEarlyFirstLine() {
        let items = LyricDisplayItem.makeItems(from: document([
            LyricLine(time: 1, text: "Hello", words: [word("Hello", 1, 2)])
        ]))
        XCTAssertEqual(items.map(\.line?.text), ["Hello"])
    }

    func testInterludeInsertedForLongGapAfterWordTimedLine() {
        let items = LyricDisplayItem.makeItems(from: document([
            LyricLine(time: 1, text: "One", words: [word("One", 1, 2)]),
            LyricLine(time: 10, text: "Two", words: [word("Two", 10, 11)]),
            LyricLine(time: 12, text: "Three", words: [word("Three", 12, 13)])
        ]))
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[1].kind, .interlude)
        XCTAssertEqual(items[1].start, 2)
        XCTAssertEqual(items[1].end, 10)
        XCTAssertEqual(items[3].line?.text, "Three")
        XCTAssertEqual(items.map(\.id), [0, 1, 2, 3])
    }

    func testEmptyLRCRowBecomesInterludeAndLineEndsAtNextLine() {
        let items = LyricDisplayItem.makeItems(from: document([
            LyricLine(time: 1, text: "One"),
            LyricLine(time: 5, text: ""),
            LyricLine(time: 12, text: "Two")
        ]))
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].end, 5)
        XCTAssertEqual(items[1].kind, .interlude)
        XCTAssertEqual(items[1].start, 5)
        XCTAssertEqual(items[1].end, 12)
    }

    func testUnsyncedLyricsBecomeStaticRows() {
        let doc = LyricsDocument(
            lines: [],
            plainText: "First\nSecond",
            source: "test",
            isSynced: false,
            wordTiming: .none
        )
        let items = LyricDisplayItem.makeItems(from: doc)
        XCTAssertEqual(items.map(\.line?.text), ["First", "Second"])
    }
}
