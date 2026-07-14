import XCTest
@testable import AppleMusicLyrics

final class AppleMusicCacheIntegrationTests: XCTestCase {
    func testCurrentMusicTrackWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["APPLE_MUSIC_CACHE_INTEGRATION"] == "1" else {
            throw XCTSkip("Set APPLE_MUSIC_CACHE_INTEGRATION=1 to test the current Music.app track")
        }
        guard case .success(let current?) = NowPlayingService().fetch() else {
            XCTFail("Music.app has no current track")
            return
        }

        let document = AppleMusicCacheLyricsProvider().lyrics(for: current)
        XCTAssertFalse(document.lines.isEmpty, "No matching Apple Music cache response")
        XCTAssertEqual(document.source, "Apple Music")
        XCTAssertEqual(document.wordTiming, .exact)
        XCTAssertTrue(document.lines.contains { !$0.words.isEmpty })
    }
}
