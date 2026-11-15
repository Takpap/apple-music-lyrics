import XCTest
@testable import AppleMusicLyrics

final class LyricsServicePriorityTests: XCTestCase {
    private var root: URL!
    private let track = TrackInfo(
        title: "Song",
        artist: "Artist",
        album: "Album",
        duration: 100,
        position: 0,
        state: .playing
    )

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricsServicePriorityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeService(
        responder: @escaping @Sendable (URLRequest) -> (Data, Int)
    ) -> LyricsService {
        LyricsService(
            provider: AppleMusicCacheLyricsProvider(cacheDirectory: root.appendingPathComponent("no-cache")),
            lrclib: LRCLibLyricsProvider(fetch: { request in responder(request) }),
            userStore: UserLyricsStore(baseDirectory: root.appendingPathComponent("support"))
        )
    }

    private let lrclibResponder: @Sendable (URLRequest) -> (Data, Int) = { _ in
        let body = try! JSONSerialization.data(withJSONObject: [
            "duration": 100, "syncedLyrics": "[00:01.00]Remote line\n[00:02.00]Second"
        ])
        return (body, 200)
    }

    func testFallsBackToLRCLIBThenAppliesUserTranslations() async throws {
        let translations = root.appendingPathComponent("support/Translations", isDirectory: true)
        try FileManager.default.createDirectory(at: translations, withIntermediateDirectories: true)
        try "remote LINE = Mine".write(
            to: translations.appendingPathComponent("Artist - Song.txt"),
            atomically: true,
            encoding: .utf8
        )

        let document = await makeService(responder: lrclibResponder).lyrics(for: track)
        XCTAssertEqual(document.source, "LRCLIB")
        XCTAssertEqual(document.lines.map(\.text), ["Remote line", "Second"])
        XCTAssertEqual(document.lines[0].translation, "Mine")
    }

    func testUserLRCFileBeatsRemote() async throws {
        let lyrics = root.appendingPathComponent("support/Lyrics", isDirectory: true)
        try FileManager.default.createDirectory(at: lyrics, withIntermediateDirectories: true)
        try "[00:01.00]Mine".write(
            to: lyrics.appendingPathComponent("Artist - Song.lrc"),
            atomically: true,
            encoding: .utf8
        )
        let recorder = CallCounter()
        let service = makeService { request in
            recorder.increment()
            return self.lrclibResponder(request)
        }
        let document = await service.lyrics(for: track)
        XCTAssertEqual(document.source, "User file")
        XCTAssertEqual(document.lines.map(\.text), ["Mine"])
        XCTAssertEqual(recorder.count, 0)
    }

    func testNothingFoundReturnsEmptyDocument() async {
        let document = await makeService(responder: { _ in (Data(), 404) }).lyrics(for: track)
        XCTAssertTrue(document.lines.isEmpty)
        XCTAssertNil(document.plainText)
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
