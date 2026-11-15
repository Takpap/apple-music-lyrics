import Foundation
import Translation
import XCTest
@testable import AppleMusicLyrics

final class LyricsTranslationMergerTests: XCTestCase {
    func testAddsTranslationWithoutChangingAppleWordTiming() {
        let original = LyricLine(
            time: 12.5,
            text: "Je danse",
            words: [
                LyricWord(text: "Je ", start: 12.5, end: 12.8),
                LyricWord(text: "danse", start: 12.8, end: 13.4)
            ]
        )
        let document = LyricsDocument(
            lines: [original],
            plainText: original.text,
            source: "Apple Music",
            isSynced: true,
            wordTiming: .exact
        )

        let result = LyricsTranslationMerger.applying(
            ["Je danse": "I dance"],
            to: document
        )

        XCTAssertEqual(result.lines[0].translation, "I dance")
        XCTAssertEqual(result.lines[0].time, original.time)
        XCTAssertEqual(result.lines[0].words, original.words)
        XCTAssertEqual(result.lines[0].text, original.text)
        XCTAssertEqual(result.wordTiming, .exact)
        XCTAssertEqual(result.source, "Apple Music")
    }

    func testKeepsAppleProvidedTranslation() {
        let original = LyricLine(
            time: 2,
            text: "Bonjour",
            translation: "Good morning"
        )
        let document = LyricsDocument(
            lines: [original],
            plainText: original.text,
            source: "Apple Music",
            isSynced: true,
            wordTiming: .none
        )

        let result = LyricsTranslationMerger.applying(
            ["Bonjour": "Hello"],
            to: document
        )

        XCTAssertEqual(result.lines[0].translation, "Good morning")
    }

    func testTranslatesFrenchLyricsUsingInstalledOnDeviceModel() async throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("On-device translation fallback requires macOS 26 or later")
        }
        let availability = await LanguageAvailability().status(
            from: Locale.Language(identifier: "fr"),
            to: Locale.Language(identifier: "en")
        )
        guard availability == .installed else {
            throw XCTSkip("The French-to-English on-device language pair is not installed")
        }

        let line = LyricLine(
            time: 12.5,
            text: "Je danse avec le vent et la pluie",
            words: [LyricWord(text: "Je danse", start: 12.5, end: 14.0)]
        )
        let document = LyricsDocument(
            lines: [line],
            plainText: line.text,
            source: "Apple Music",
            isSynced: true,
            wordTiming: .exact
        )

        let translated = await OnDeviceLyricsTranslator().addEnglishTranslations(to: document)

        XCTAssertFalse(translated.lines[0].translation?.isEmpty ?? true)
        XCTAssertEqual(translated.lines[0].time, line.time)
        XCTAssertEqual(translated.lines[0].words, line.words)
        XCTAssertEqual(translated.lines[0].text, line.text)
    }
}
