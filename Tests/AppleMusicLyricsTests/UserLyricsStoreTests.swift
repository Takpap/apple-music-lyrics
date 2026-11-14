import XCTest
@testable import AppleMusicLyrics

final class UserLyricsStoreTests: XCTestCase {
    private var root: URL!
    private var store: UserLyricsStore!
    private let track = TrackInfo(
        title: "Live/Love: Song",
        artist: "Some Artist",
        album: "",
        duration: 180,
        position: 0,
        state: .playing
    )

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserLyricsStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = UserLyricsStore(baseDirectory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func document(_ lines: [LyricLine]) -> LyricsDocument {
        LyricsDocument(lines: lines, plainText: "p", source: "Apple Music", isSynced: true, wordTiming: .exact)
    }

    func testBaseDirectoryDefaultsToApplicationSupport() {
        XCTAssertTrue(UserLyricsStore().directoryURL.path.hasSuffix("Library/Application Support/AppleMusicLyrics"))
        XCTAssertEqual(store.directoryURL, root)
    }

    func testUserLyricsUsesSanitisedNameAndParsesTranslations() throws {
        try write("[00:01.00]Hola\n[00:01.00]Hello\n[00:03.00]Adios\n", to: "Lyrics/Some Artist - Live-Love- Song.lrc")
        let doc = try XCTUnwrap(store.userLyrics(for: track))
        XCTAssertEqual(doc.source, "User file")
        XCTAssertTrue(doc.isSynced)
        XCTAssertEqual(doc.lines.map(\.text), ["Hola", "Adios"])
        XCTAssertEqual(doc.lines[0].translation, "Hello")
    }

    func testLookupIsCaseInsensitiveAgainstDirectoryListing() throws {
        try write("[00:01.00]x", to: "Lyrics/SOME ARTIST - LIVE-LOVE- SONG.LRC".replacingOccurrences(of: ".LRC", with: ".lrc"))
        XCTAssertNotNil(store.userLyrics(for: track))

        try write("hola = hello", to: "Translations/some artist - live-love- song.txt")
        XCTAssertEqual(store.translations(for: track), ["hola": "hello"])
    }

    func testMissingFilesReturnNilOrEmpty() {
        XCTAssertNil(store.userLyrics(for: track))
        XCTAssertTrue(store.translations(for: track).isEmpty)
    }

    func testTranslationParsingRules() throws {
        try write("""
        # a comment
        Hola   MUNDO = Hello world
        Cost = 5 = five
        a=b
        empty =
        no separator
        Another =

        """, to: "Translations/Some Artist - Live-Love- Song.txt")
        let map = store.translations(for: track)
        XCTAssertEqual(map["hola mundo"], "Hello world")
        XCTAssertEqual(map["cost"], "5 = five")
        XCTAssertEqual(map["a"], "b")
        XCTAssertNil(map["empty"])
        XCTAssertNil(map["another"])
        XCTAssertNil(map["no separator"])
        XCTAssertEqual(map.count, 3)
    }

    func testApplyingTranslationsReplacesAndPreservesFields() {
        let words = [LyricWord(text: "Hola", start: 1, end: 2)]
        let url = URL(string: "https://example.test/a.png")
        let original = LyricsDocument(
            lines: [
                LyricLine(time: 1, text: "Hola", words: words, translation: "old", transliteration: "ola"),
                LyricLine(time: 3, text: "Adios", translation: "keep"),
                LyricLine(time: 5, text: "")
            ],
            plainText: "plain",
            source: "Apple Music",
            isSynced: true,
            wordTiming: .exact,
            artworkURL: url
        )
        let result = store.applyingTranslations(["hola": "Hello", "": "ignored"], to: original)
        XCTAssertEqual(result.lines[0], LyricLine(time: 1, text: "Hola", words: words, translation: "Hello", transliteration: "ola"))
        XCTAssertEqual(result.lines[1], original.lines[1])
        XCTAssertEqual(result.lines[2], original.lines[2])
        XCTAssertEqual(result.plainText, "plain")
        XCTAssertEqual(result.source, "Apple Music")
        XCTAssertEqual(result.wordTiming, .exact)
        XCTAssertEqual(result.artworkURL, url)
        XCTAssertEqual(store.applyingTranslations([:], to: original), original)
    }

    func testTemplateListsUniqueNonEmptyLinesWithExistingTranslations() {
        let doc = document([
            LyricLine(time: 1, text: "Hola", translation: "Hello"),
            LyricLine(time: 2, text: ""),
            LyricLine(time: 3, text: "Adios"),
            LyricLine(time: 4, text: "  hola ")
        ])
        let template = store.translationTemplate(for: track, lyrics: doc)
        let rows = template.components(separatedBy: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
        XCTAssertEqual(rows, ["Hola = Hello", "Adios = "])
        XCTAssertTrue(template.hasPrefix("#"))

        // The template round-trips through the parser.
        XCTAssertEqual(UserLyricsStore.parseTranslations(template), ["hola": "Hello"])
    }

    func testEnsureTranslationsFileCreatesOnceAndNeverOverwrites() throws {
        let doc = document([LyricLine(time: 1, text: "Hola")])
        let url = try store.ensureTranslationsFile(for: track, lyrics: doc)
        XCTAssertEqual(url, store.translationsFileURL(for: track))
        XCTAssertEqual(url.lastPathComponent, "Some Artist - Live-Love- Song.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try String(contentsOf: url).contains("Hola = "))

        try "mine = yours".write(to: url, atomically: true, encoding: .utf8)
        let again = try store.ensureTranslationsFile(for: track, lyrics: doc)
        XCTAssertEqual(again, url)
        XCTAssertEqual(try String(contentsOf: url), "mine = yours")
    }

    func testSetTranslationsCreatesFileThenUpdatesOnlyChangedRows() throws {
        try store.setTranslations([(original: "Dans ma love story", translation: "In my love story")], for: track)
        XCTAssertEqual(store.translations(for: track), ["dans ma love story": "In my love story"])

        let url = store.translationsFileURL(for: track)
        var text = try String(contentsOf: url)
        text += "# keep me\nJe t'attendrai = I'll wait\n"
        try text.write(to: url, atomically: true, encoding: .utf8)

        try store.setTranslations([
            (original: "  DANS ma   love story ", translation: "In my own love story"),
            (original: "Ma love story", translation: "My love\nstory")
        ], for: track)
        let saved = try String(contentsOf: url)
        XCTAssertTrue(saved.contains("# keep me"))
        XCTAssertEqual(saved.components(separatedBy: "Dans ma love story").count + saved.components(separatedBy: "DANS ma").count, 3)
        XCTAssertEqual(store.translations(for: track), [
            "dans ma love story": "In my own love story",
            "je t'attendrai": "I'll wait",
            "ma love story": "My love story"
        ])

        // An empty translation clears the override.
        try store.setTranslations([(original: "Ma love story", translation: "")], for: track)
        XCTAssertNil(store.translations(for: track)["ma love story"])
    }
}
