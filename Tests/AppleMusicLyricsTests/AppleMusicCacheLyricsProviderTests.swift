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

    func testReadsInlineDatabaseResponse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let response = try cachedResponse(
            title: "Inline Song",
            artist: "Inline Artist",
            localizations: [
                "en-US": "<tt><body><div><p begin=\"1.0\" end=\"2.0\"><span begin=\"1.0\" end=\"2.0\">Inline lyric</span></p></div></body></tt>"
            ]
        )
        let databaseURL = root.appendingPathComponent("Cache.db")
        try runSQLite(
            databaseURL,
            sql: """
            CREATE TABLE cfurl_cache_response(entry_ID INTEGER PRIMARY KEY, request_key TEXT, time_stamp TEXT);
            CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER PRIMARY KEY, isDataOnFS INTEGER, receiver_data BLOB);
            INSERT INTO cfurl_cache_response VALUES(1, 'https://example.test/syllable-lyrics', '2026-01-01');
            INSERT INTO cfurl_cache_receiver_data VALUES(1, 0, X'\(response.hexEncodedString)');
            """
        )

        let track = TrackInfo(
            title: "Inline Song",
            artist: "Inline Artist",
            album: "Test Album",
            duration: 180,
            position: 1.5,
            state: .playing
        )
        let document = AppleMusicCacheLyricsProvider(cacheDirectory: root).lyrics(for: track)

        XCTAssertEqual(document.lines.first?.text, "Inline lyric")
        XCTAssertEqual(document.wordTiming, .exact)
    }

    func testFallsBackToDirectoryWhenIndexedFileIsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dataDirectory = root.appendingPathComponent("fsCachedData", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let response = try cachedResponse(
            title: "Fallback Song",
            artist: "Fallback Artist",
            localizations: "<tt><body><div><p begin=\"1.0\" end=\"2.0\"><span begin=\"1.0\" end=\"2.0\">Fallback lyric</span></p></div></body></tt>"
        )
        try response.write(to: dataDirectory.appendingPathComponent(UUID().uuidString))

        let databaseURL = root.appendingPathComponent("Cache.db")
        let missingName = UUID().uuidString.data(using: .utf8)!.hexEncodedString
        try runSQLite(
            databaseURL,
            sql: """
            CREATE TABLE cfurl_cache_response(entry_ID INTEGER PRIMARY KEY, request_key TEXT, time_stamp TEXT);
            CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER PRIMARY KEY, isDataOnFS INTEGER, receiver_data BLOB);
            INSERT INTO cfurl_cache_response VALUES(1, 'https://example.test/syllable-lyrics', '2026-01-01');
            INSERT INTO cfurl_cache_receiver_data VALUES(1, 1, X'\(missingName)');
            """
        )

        let track = TrackInfo(
            title: "Fallback Song",
            artist: "Fallback Artist",
            album: "Test Album",
            duration: 180,
            position: 1.5,
            state: .playing
        )
        let document = AppleMusicCacheLyricsProvider(cacheDirectory: root).lyrics(for: track)

        XCTAssertEqual(document.lines.first?.text, "Fallback lyric")
    }

    private func cachedResponse(
        title: String,
        artist: String,
        localizations: Any
    ) throws -> Data {
        let response: [String: Any] = [
            "data": [[
                "attributes": [
                    "name": title,
                    "artistName": artist,
                    "albumName": "Test Album",
                    "durationInMillis": 180_000
                ],
                "relationships": [
                    "syllable-lyrics": [
                        "data": [["attributes": ["ttmlLocalizations": localizations]]]
                    ]
                ]
            ]]
        ]
        return try JSONSerialization.data(withJSONObject: response)
    }

    private func runSQLite(_ databaseURL: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private extension Data {
    var hexEncodedString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
