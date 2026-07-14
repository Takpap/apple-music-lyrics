import Foundation
import XCTest
@testable import AppleMusicLyrics

final class AppleMusicCacheLyricsProviderTests: XCTestCase {
    func testReadsMatchingAppleMusicCacheResponse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataDirectory = root.appendingPathComponent("fsCachedData", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
          <p begin="1.0" end="2.0"><span begin="1.0" end="2.0">Local lyric</span></p>
        </div></body></tt>
        """
        let response: [String: Any] = [
            "data": [[
                "attributes": [
                    "name": "Test Song",
                    "artistName": "Test Artist",
                    "albumName": "Test Album",
                    "durationInMillis": 180_000
                ],
                "relationships": [
                    "syllable-lyrics": [
                        "data": [[
                            "attributes": ["ttmlLocalizations": ttml]
                        ]]
                    ]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: response)
        try data.write(to: dataDirectory.appendingPathComponent(UUID().uuidString))

        let provider = AppleMusicCacheLyricsProvider(cacheDirectory: root)
        let track = TrackInfo(
            title: "Test Song",
            artist: "Test Artist",
            album: "Test Album",
            duration: 180,
            position: 1.5,
            state: .playing
        )
        let document = provider.lyrics(for: track)

        XCTAssertEqual(document.source, "Apple Music")
        XCTAssertEqual(document.lines.first?.text, "Local lyric")
        XCTAssertEqual(document.wordTiming, .exact)
    }

    func testRejectsDifferentArtistWithSameTitle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataDirectory = root.appendingPathComponent("fsCachedData", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let response: [String: Any] = [
            "data": [[
                "attributes": [
                    "name": "Shared Title",
                    "artistName": "Wrong Artist",
                    "durationInMillis": 180_000
                ],
                "relationships": [
                    "syllable-lyrics": [
                        "data": [["attributes": ["ttmlLocalizations": "<tt><body/></tt>"]]]
                    ]
                ]
            ]]
        ]
        try JSONSerialization.data(withJSONObject: response)
            .write(to: dataDirectory.appendingPathComponent(UUID().uuidString))

        let provider = AppleMusicCacheLyricsProvider(cacheDirectory: root)
        let track = TrackInfo(
            title: "Shared Title",
            artist: "Right Artist",
            album: "",
            duration: 180,
            position: 0,
            state: .playing
        )

        XCTAssertTrue(provider.lyrics(for: track).lines.isEmpty)
    }
}
