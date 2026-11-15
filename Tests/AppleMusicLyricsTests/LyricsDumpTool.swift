import XCTest
@testable import AppleMusicLyrics

/// Developer tool, skipped by default: dumps the lyric lines each source
/// returns for a list of tracks so translation files can be written against
/// the exact line text the app matches on.
///
///     AML_DUMP_TRACKS=tracks.tsv AML_DUMP_OUT=out.json swift test --filter LyricsDumpTool
///
/// `tracks.tsv` rows: title<TAB>artist<TAB>album<TAB>duration
final class LyricsDumpTool: XCTestCase {
    func testDumpLyricLines() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["AML_DUMP_TRACKS"], let output = env["AML_DUMP_OUT"] else {
            throw XCTSkip("Set AML_DUMP_TRACKS and AML_DUMP_OUT to dump lyric lines")
        }
        let cache = AppleMusicCacheLyricsProvider()
        let lrclib = LRCLibLyricsProvider()
        let store = UserLyricsStore()
        var result: [[String: Any]] = []
        for row in try String(contentsOfFile: input, encoding: .utf8).split(separator: "\n") {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { continue }
            let track = TrackInfo(
                title: fields[0], artist: fields[1], album: fields[2],
                duration: Double(fields[3]) ?? 0, position: 0, state: .stopped
            )
            let apple = cache.lyrics(for: track)
            let remote = await lrclib.lyrics(for: track)
            // How many lines the user's translations file covers, per source.
            let map = store.translations(for: track)
            func covered(_ doc: LyricsDocument?) -> [Int] {
                guard let doc else { return [0, 0] }
                let lines = doc.lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.text != "♪" }
                let applied = store.applyingTranslations(map, to: LyricsDocument(
                    lines: lines, plainText: nil, source: doc.source, isSynced: doc.isSynced, wordTiming: doc.wordTiming
                ))
                return [applied.lines.filter { $0.translation != nil }.count, lines.count]
            }
            result.append([
                "title": track.title,
                "artist": track.artist,
                "baseName": UserLyricsStore.baseName(for: track),
                "apple": apple.lines.map(\.text),
                "appleTranslations": apple.lines.map { $0.translation ?? "" },
                "lrclib": remote?.lines.map(\.text) ?? [],
                "lrclibPlain": remote?.plainText ?? "",
                "userCoverage": ["apple": covered(apple.lines.isEmpty ? nil : apple), "lrclib": covered(remote)]
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
    }
}
