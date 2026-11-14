import XCTest
@testable import AppleMusicLyrics

/// Mirrors the structure Music.app caches for line-timed French lyrics that
/// carry Apple's English translation inside <head>.
final class AppleTTMLEmbeddedTranslationTests: XCTestCase {
    private let ttml = """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" \
    xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Line" xml:lang="fr"><head><metadata>\
    <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal" leadingSilence="0.120">\
    <translations><translation automaticallyCreated="true" type="subtitle" xml:lang="zh-Hans">\
    <text for="L1">在我的爱情故事里</text></translation>\
    <translation automaticallyCreated="true" type="subtitle" xml:lang="en-US">\
    <text for="L1">In my love story</text><text for="L2">I'll wait for you at the port</text>\
    </translation></translations>\
    <transliterations><transliteration xml:lang="fr-Latn"><text for="L2"><span>Je</span> <span>t'attendrai</span></text></transliteration></transliterations>\
    </iTunesMetadata></metadata></head><body><div>\
    <p begin="10.0" end="13.5" itunes:key="L1">Dans ma love story</p>\
    <p begin="14.0" end="17.0" itunes:key="L2">Je t'attendrai sur le port</p>\
    <p begin="18.0" end="20.0" itunes:key="L3">Ma love story</p>\
    </div></body></tt>
    """

    func testEmbeddedTranslationMatchingPreferredLanguageIsAttached() throws {
        let parsed = try AppleTTMLParser.parse(ttml, preferredLanguages: ["en-US"])
        XCTAssertEqual(parsed.wordTiming, .none)
        XCTAssertEqual(parsed.lines.map(\.text), ["Dans ma love story", "Je t'attendrai sur le port", "Ma love story"])
        XCTAssertEqual(parsed.lines.map(\.translation), ["In my love story", "I'll wait for you at the port", nil])
        XCTAssertEqual(parsed.lines[1].transliteration, "Je t'attendrai")
    }

    func testPreferredLanguageOrderPicksTranslation() throws {
        let parsed = try AppleTTMLParser.parse(ttml, preferredLanguages: ["zh-Hans-CN", "en"])
        XCTAssertEqual(parsed.lines[0].translation, "在我的爱情故事里")
        XCTAssertNil(parsed.lines[1].translation)
    }

    func testTranslationInOtherLanguageIsIgnored() throws {
        let parsed = try AppleTTMLParser.parse(ttml, preferredLanguages: ["de-DE"])
        XCTAssertTrue(parsed.lines.allSatisfy { $0.translation == nil })
    }

    func testRealCachedLyricsCarryEnglishTranslation() throws {
        // Optional check against Music.app's live cache when a path is given.
        guard let path = ProcessInfo.processInfo.environment["AML_CACHED_RESPONSE"] else {
            throw XCTSkip("Set AML_CACHED_RESPONSE to a cached catalog response")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let song = (json?["data"] as? [[String: Any]])?.first
        let lyrics = ((song?["relationships"] as? [String: Any])?["syllable-lyrics"] as? [String: Any])?["data"] as? [[String: Any]]
        let raw = (lyrics?.first?["attributes"] as? [String: Any])?["ttmlLocalizations"] as? String
        let parsed = try AppleTTMLParser.parse(try XCTUnwrap(raw), preferredLanguages: ["en-US"])
        let translated = parsed.lines.filter { $0.translation != nil }.count
        XCTAssertGreaterThan(translated, parsed.lines.count / 2)
        print("REAL: lines=\(parsed.lines.count) translated=\(translated) first=\(parsed.lines.first.map { "\($0.text) => \($0.translation ?? "-")" } ?? "")")
    }
}
