import XCTest
@testable import AppleMusicLyrics

private final class FetchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var responder: @Sendable (URLRequest) -> (Data, Int)

    init(responder: @escaping @Sendable (URLRequest) -> (Data, Int)) {
        self.responder = responder
    }

    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        lock.lock()
        requests.append(request)
        let responder = self.responder
        lock.unlock()
        return responder(request)
    }

    var paths: [String] { requests.map { $0.url?.path ?? "" } }
}

private final class Clock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_000_000)
}

final class LRCLibLyricsProviderTests: XCTestCase {
    private let track = TrackInfo(
        title: "Song & Co",
        artist: "The Artist",
        album: "Album",
        duration: 200.4,
        position: 0,
        state: .playing
    )

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func testGetReturnsSyncedDocumentAndSendsHeaders() async {
        let recorder = FetchRecorder { _ in
            (self.json([
                "trackName": "Song", "duration": 200,
                "plainLyrics": "a\nb",
                "syncedLyrics": "[00:01.00]a\n[00:02.00]b"
            ]), 200)
        }
        let provider = LRCLibLyricsProvider(fetch: recorder.fetch)
        let document = await provider.lyrics(for: track)

        XCTAssertEqual(document?.source, "LRCLIB")
        XCTAssertEqual(document?.isSynced, true)
        XCTAssertEqual(document?.wordTiming, WordTimingQuality.none)
        XCTAssertEqual(document?.lines.map(\.text), ["a", "b"])
        XCTAssertEqual(recorder.paths, ["/api/get"])

        let request = recorder.requests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "AppleMusicLyrics (https://github.com/Takpap/apple-music-lyrics)")
        XCTAssertEqual(request.timeoutInterval, 8)
        let query = request.url?.query ?? ""
        XCTAssertTrue(query.contains("track_name=Song%20%26%20Co"), query)
        XCTAssertTrue(query.contains("artist_name=The%20Artist"), query)
        XCTAssertTrue(query.contains("album_name=Album"), query)
        XCTAssertTrue(query.contains("duration=200"), query)
    }

    func testEnhancedLyricsReportExactWordTiming() async {
        let recorder = FetchRecorder { _ in
            (self.json(["duration": 200, "syncedLyrics": "[00:01.00]<00:01.00>a<00:01.50>b<00:02.00>"]), 200)
        }
        let document = await LRCLibLyricsProvider(fetch: recorder.fetch).lyrics(for: track)
        XCTAssertEqual(document?.wordTiming, .exact)
    }

    func testFallsBackToSearchOn404PickingClosestDurationWithSyncedLyrics() async {
        let recorder = FetchRecorder { request in
            if request.url?.path == "/api/get" { return (Data("{}".utf8), 404) }
            return (self.json([
                ["duration": 200, "plainLyrics": "plain only"],
                ["duration": 190, "syncedLyrics": "[00:01.00]far"],
                ["duration": 202, "syncedLyrics": "[00:01.00]near"],
                ["duration": 199, "syncedLyrics": "[00:01.00]nearest"]
            ]), 200)
        }
        let document = await LRCLibLyricsProvider(fetch: recorder.fetch).lyrics(for: track)
        XCTAssertEqual(recorder.paths, ["/api/get", "/api/search"])
        XCTAssertEqual(document?.lines.map(\.text), ["nearest"])
        XCTAssertFalse((recorder.requests[1].url?.query ?? "").contains("duration"))
    }

    func testSearchRejectsDurationDifferenceOverFourSeconds() async {
        let recorder = FetchRecorder { request in
            if request.url?.path == "/api/get" { return (Data(), 404) }
            return (self.json([["duration": 206, "syncedLyrics": "[00:01.00]x"]]), 200)
        }
        let document = await LRCLibLyricsProvider(fetch: recorder.fetch).lyrics(for: track)
        XCTAssertNil(document)
    }

    func testPlainOnlyReturnsUnsyncedDocument() async {
        let recorder = FetchRecorder { request in
            if request.url?.path == "/api/get" {
                return (self.json(["duration": 200, "plainLyrics": "la la\nla"]), 200)
            }
            return (Data("[]".utf8), 200)
        }
        let document = await LRCLibLyricsProvider(fetch: recorder.fetch).lyrics(for: track)
        XCTAssertEqual(document?.isSynced, false)
        XCTAssertEqual(document?.plainText, "la la\nla")
        XCTAssertEqual(document?.lines, [])
        XCTAssertEqual(document?.source, "LRCLIB")
    }

    func testCachesPositiveAndNegativeResultsFor10Minutes() async {
        let clock = Clock()
        let recorder = FetchRecorder { _ in (Data("{}".utf8), 404) }
        let provider = LRCLibLyricsProvider(fetch: recorder.fetch, now: { clock.date })

        let first = await provider.lyrics(for: track)
        XCTAssertNil(first)
        let callsAfterFirst = recorder.requests.count
        XCTAssertEqual(callsAfterFirst, 2)

        clock.date.addTimeInterval(9 * 60)
        _ = await provider.lyrics(for: track)
        XCTAssertEqual(recorder.requests.count, callsAfterFirst, "negative result should be cached")

        clock.date.addTimeInterval(2 * 60)
        _ = await provider.lyrics(for: track)
        XCTAssertEqual(recorder.requests.count, callsAfterFirst * 2, "negative cache should expire after 10 minutes")
    }

    func testSuccessIsCachedPerIdentityKey() async {
        let recorder = FetchRecorder { _ in
            (self.json(["duration": 200, "syncedLyrics": "[00:01.00]a"]), 200)
        }
        let provider = LRCLibLyricsProvider(fetch: recorder.fetch)
        _ = await provider.lyrics(for: track)
        _ = await provider.lyrics(for: track)
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testServerErrorReturnsNil() async {
        let recorder = FetchRecorder { _ in (Data(), 500) }
        let document = await LRCLibLyricsProvider(fetch: recorder.fetch).lyrics(for: track)
        XCTAssertNil(document)
    }

    func testRetriesRateLimitedRequests() async {
        let calls = FetchRecorder { _ in (Data(), 0) }
        let counter = Clock()
        calls.responder = { _ in
            counter.date = counter.date.addingTimeInterval(1)
            if counter.date.timeIntervalSince1970 < 1_000_002 { return (Data(), 429) }
            return ((try? JSONSerialization.data(withJSONObject: [
                "duration": 200, "syncedLyrics": "[00:01.00]a"
            ])) ?? Data(), 200)
        }
        let provider = LRCLibLyricsProvider(fetch: calls.fetch, sleep: { _ in })
        let document = await provider.lyrics(for: track)
        XCTAssertEqual(document?.lines.map(\.text), ["a"])
        XCTAssertEqual(calls.paths, ["/api/get", "/api/get"])
    }

    func testSearchesAgainWithDecorationsStripped() async {
        let decorated = TrackInfo(
            title: "I Ain't Worried (Mixed)", artist: "OneRepublic & Friend", album: "A",
            duration: 148, position: 0, state: .playing
        )
        let recorder = FetchRecorder { request in
            let query = request.url?.query ?? ""
            if request.url?.path == "/api/get" { return (Data("{}".utf8), 404) }
            if query.contains("Mixed") { return (Data("[]".utf8), 200) }
            return ((try? JSONSerialization.data(withJSONObject: [[
                "duration": 147.5, "syncedLyrics": "[00:01.00]worried"
            ]])) ?? Data(), 200)
        }
        let document = await LRCLibLyricsProvider(fetch: recorder.fetch, sleep: { _ in }).lyrics(for: decorated)
        XCTAssertEqual(document?.lines.map(\.text), ["worried"])
        XCTAssertEqual(recorder.paths, ["/api/get", "/api/search", "/api/search"])
    }

    func testSearchVariants() {
        XCTAssertEqual(LRCLibLyricsProvider.strippedTitle("Rather Be (feat. Jess Glynne)"), "Rather Be")
        XCTAssertEqual(LRCLibLyricsProvider.strippedTitle("You(th) [Demo]"), "You")
        XCTAssertEqual(LRCLibLyricsProvider.strippedTitle("Song - Remastered 2011"), "Song")
        XCTAssertEqual(LRCLibLyricsProvider.strippedTitle("(Intro)"), "(Intro)")
        XCTAssertEqual(LRCLibLyricsProvider.primaryArtist("Sam Fender & Olivia Dean"), "Sam Fender")
        XCTAssertEqual(LRCLibLyricsProvider.primaryArtist("Florence + the Machine"), "Florence + the Machine")
        XCTAssertEqual(LRCLibLyricsProvider.searchVariants(title: "Song", artist: "A").count, 1)
        XCTAssertEqual(LRCLibLyricsProvider.searchVariants(title: "Song (Live)", artist: "A, B").count, 4)
    }
}
