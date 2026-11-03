import Foundation
import XCTest
@testable import AppleMusicLyrics

final class LyricsExporterTests: XCTestCase {
    private let track = TrackInfo(
        title: "Song/Name",
        artist: "Artist",
        album: "Album",
        duration: 125,
        position: 0,
        state: .playing
    )

    private var synced: LyricsDocument {
        LyricsDocument(
            lines: [
                LyricLine(
                    time: 1.0,
                    text: "Hello world",
                    words: [
                        LyricWord(text: "Hello", start: 1.0, end: 1.5),
                        LyricWord(text: " world", start: 1.5, end: 2.25)
                    ],
                    translation: "你好世界",
                    transliteration: "ni hao"
                ),
                LyricLine(time: 62.5, text: "再见", words: [
                    LyricWord(text: "再见", start: 62.5, end: 64)
                ])
            ],
            plainText: nil,
            source: "test",
            isSynced: true,
            wordTiming: .exact
        )
    }

    func testTimestamps() {
        XCTAssertEqual(LyricsExporter.lrcTimestamp(62.505), "01:02.51")
        XCTAssertEqual(LyricsExporter.lrcTimestamp(3725), "62:05.00")
        XCTAssertEqual(LyricsExporter.srtTimestamp(3725.0421), "01:02:05,042")
    }

    func testLineLRCIncludesMetadataAndTranslation() {
        let output = LyricsExporter.export(synced, track: track, format: .lrc)
        let lines = output.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "[ti:Song/Name]")
        XCTAssertTrue(lines.contains("[length:02:05]"))
        XCTAssertTrue(lines.contains("[00:01.00]Hello world"))
        XCTAssertTrue(lines.contains("[00:01.00]你好世界"))
        XCTAssertFalse(output.contains("ni hao"))
        XCTAssertTrue(lines.contains("[01:02.50]再见"))
    }

    func testEnhancedLRCWritesWordTimestamps() {
        let output = LyricsExporter.export(
            synced,
            track: nil,
            format: .enhancedLRC,
            options: LyricsExportOptions(includeTranslation: false, includeTransliteration: true)
        )
        XCTAssertTrue(output.contains("[00:01.00]<00:01.00>Hello<00:01.50> world<00:02.25>"))
        XCTAssertTrue(output.contains("[00:01.00]ni hao"))
        XCTAssertFalse(output.contains("你好世界"))
    }

    func testSRTCues() {
        let output = LyricsExporter.export(synced, track: track, format: .srt)
        XCTAssertTrue(output.hasPrefix("1\n00:00:01,000 --> 00:00:02,250\nHello world\n你好世界\n\n2\n"))
        XCTAssertTrue(output.contains("00:01:02,500 --> 00:01:04,000\n再见"))
    }

    func testPlainTextFallbackAndAvailability() {
        let plain = LyricsDocument(
            lines: [],
            plainText: "Line one\nLine two",
            source: "test",
            isSynced: false,
            wordTiming: .none
        )
        XCTAssertFalse(LyricsExportFormat.lrc.isAvailable(for: plain))
        XCTAssertFalse(LyricsExportFormat.srt.isAvailable(for: plain))
        XCTAssertTrue(LyricsExportFormat.plainText.isAvailable(for: plain))
        XCTAssertTrue(LyricsExportFormat.enhancedLRC.isAvailable(for: synced))

        let output = LyricsExporter.export(plain, track: track, format: .plainText)
        XCTAssertEqual(output, "Song/Name — Artist\n\nLine one\nLine two\n")
    }

    func testSuggestedFilenameStripsPathSeparators() {
        XCTAssertEqual(
            LyricsExporter.suggestedFilename(track: track, format: .srt),
            "Artist - Song_Name.srt"
        )
        XCTAssertEqual(LyricsExporter.suggestedFilename(track: nil, format: .lrc), "Lyrics.lrc")
    }
}
