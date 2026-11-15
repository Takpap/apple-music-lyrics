import XCTest
@testable import AppleMusicLyrics

final class LRCParserTests: XCTestCase {
    func testParsesCentisecondMillisecondAndWholeSecondStamps() {
        let lines = LRCParser.parse("""
        [00:01.50]one
        [00:02.250]two
        [00:03]three
        """)
        XCTAssertEqual(lines.map(\.time), [1.5, 2.25, 3.0])
        XCTAssertEqual(lines.map(\.text), ["one", "two", "three"])
        XCTAssertTrue(lines.allSatisfy { $0.words.isEmpty })
    }

    func testMultipleTimestampsProduceSortedLines() {
        let lines = LRCParser.parse("""
        [00:12.00][01:30.00]chorus
        [00:20.00]verse
        """)
        XCTAssertEqual(lines.map(\.time), [12, 20, 90])
        XCTAssertEqual(lines.map(\.text), ["chorus", "verse", "chorus"])
    }

    func testMetadataIgnoredAndOffsetApplied() {
        let lines = LRCParser.parse("""
        [ar:Artist]
        [ti:Title]
        [offset:+500]
        [00:10.00]hello
        """)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].time, 9.5, accuracy: 0.0001)

        let negative = LRCParser.parse("[offset:-1000]\n[00:10.00]hello")
        XCTAssertEqual(negative[0].time, 11, accuracy: 0.0001)
    }

    func testEmptyTextLinesAreKept() {
        let lines = LRCParser.parse("[00:01.00]a\n[00:05.00]\n[00:09.00]b")
        XCTAssertEqual(lines.map(\.text), ["a", "", "b"])
        XCTAssertEqual(lines.map(\.time), [1, 5, 9])
    }

    func testDuplicateTimestampBecomesTranslation() {
        let lines = LRCParser.parse("""
        [00:01.00]Je danse
        [00:01.00]I dance
        [00:04.00]Encore
        """)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "Je danse")
        XCTAssertEqual(lines[0].translation, "I dance")
        XCTAssertNil(lines[1].translation)
    }

    func testEnhancedWordTags() {
        let lines = LRCParser.parse("""
        [00:01.00]<00:01.00>Hel<00:01.50>lo <00:02.00>world<00:02.80>
        [00:03.00]<00:03.00>Next<00:03.50>
        """)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "Hello world")
        XCTAssertEqual(lines[0].words, [
            LyricWord(text: "Hel", start: 1.0, end: 1.5),
            LyricWord(text: "lo ", start: 1.5, end: 2.0),
            LyricWord(text: "world", start: 2.0, end: 2.8)
        ])
        XCTAssertEqual(lines[1].words, [LyricWord(text: "Next", start: 3.0, end: 3.5)])
    }

    func testEnhancedLastWordWithoutTrailingTagUsesNextLineThenOneSecond() {
        let lines = LRCParser.parse("""
        [00:01.00]<00:01.00>a<00:01.40>b
        [00:05.00]<00:05.00>c
        """)
        XCTAssertEqual(lines[0].words.last, LyricWord(text: "b", start: 1.4, end: 5.0))
        XCTAssertEqual(lines[1].words.last, LyricWord(text: "c", start: 5.0, end: 6.0))
    }

    func testCRLFAndBOMAndGarbageLines() {
        let lines = LRCParser.parse("\u{FEFF}just text\r\n[00:01.00]a\r\n[bad]\r\n[00:02.00]b\r\n")
        XCTAssertEqual(lines.map(\.text), ["a", "b"])
    }

    func testOffsetShiftsWordTimes() {
        let lines = LRCParser.parse("[offset:1000]\n[00:05.00]<00:05.00>x<00:06.00>")
        XCTAssertEqual(lines[0].time, 4, accuracy: 0.0001)
        XCTAssertEqual(lines[0].words[0].start, 4, accuracy: 0.0001)
        XCTAssertEqual(lines[0].words[0].end, 5, accuracy: 0.0001)
    }
}
