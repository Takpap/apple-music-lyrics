import Foundation
import XCTest
@testable import AppleMusicLyrics

final class UpdateServiceTests: XCTestCase {
    func testSemanticVersionComparison() throws {
        XCTAssertEqual(SemanticVersion("v1.5.1"), SemanticVersion("1.5.1"))
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion("1.5.1")), try XCTUnwrap(SemanticVersion("1.6.0")))
        XCTAssertLessThan(try XCTUnwrap(SemanticVersion("1.9.9")), try XCTUnwrap(SemanticVersion("2.0.0")))
        XCTAssertNil(SemanticVersion("development"))
        XCTAssertNil(SemanticVersion("1.5"))
    }

    func testSelectsUniversalDMGFromNewerRelease() throws {
        let service = UpdateService(currentVersion: "1.5.1")
        let update = try XCTUnwrap(service.availableUpdate(from: releaseJSON(tag: "v1.6.0")))

        XCTAssertEqual(update.version, SemanticVersion("1.6.0"))
        XCTAssertEqual(update.assetName, "Apple-Music-Lyrics-1.6.0-macos-universal.dmg")
        XCTAssertEqual(update.checksumURL.lastPathComponent, "SHA256SUMS.txt")
    }

    func testIgnoresCurrentAndPrereleaseVersions() throws {
        let service = UpdateService(currentVersion: "1.5.1")

        XCTAssertNil(try service.availableUpdate(from: releaseJSON(tag: "v1.5.1")))
        XCTAssertNil(try service.availableUpdate(
            from: releaseJSON(tag: "v1.6.0", prerelease: true)
        ))
    }

    func testRejectsUntrustedDownloadHost() throws {
        let service = UpdateService(currentVersion: "1.5.1")
        let data = releaseJSON(
            tag: "v1.6.0",
            downloadBaseURL: "https://downloads.example.com/releases/v1.6.0"
        )

        XCTAssertThrowsError(try service.availableUpdate(from: data)) { error in
            XCTAssertEqual(error as? UpdateServiceError, .downloadUnavailable)
        }
    }

    func testParsesChecksumForExactAssetName() {
        let expected = String(repeating: "a", count: 64)
        let contents = """
        \(String(repeating: "b", count: 64))  other.dmg
        \(expected)  Apple-Music-Lyrics-1.6.0-macos-universal.dmg
        """

        XCTAssertEqual(
            UpdateService.expectedSHA256(
                in: contents,
                for: "Apple-Music-Lyrics-1.6.0-macos-universal.dmg"
            ),
            expected
        )
        XCTAssertNil(UpdateService.expectedSHA256(in: contents, for: "missing.dmg"))
    }

    private func releaseJSON(
        tag: String,
        prerelease: Bool = false,
        downloadBaseURL: String? = nil
    ) -> Data {
        let baseURL = downloadBaseURL
            ?? "https://github.com/Takpap/apple-music-lyrics/releases/download/\(tag)"
        let version = String(tag.drop(while: { $0 == "v" }))
        let object: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/Takpap/apple-music-lyrics/releases/tag/\(tag)",
            "draft": false,
            "prerelease": prerelease,
            "assets": [
                [
                    "name": "Apple-Music-Lyrics-\(version)-macos-universal.zip",
                    "browser_download_url": "\(baseURL)/Apple-Music-Lyrics-\(version)-macos-universal.zip"
                ],
                [
                    "name": "Apple-Music-Lyrics-\(version)-macos-universal.dmg",
                    "browser_download_url": "\(baseURL)/Apple-Music-Lyrics-\(version)-macos-universal.dmg"
                ],
                [
                    "name": "SHA256SUMS.txt",
                    "browser_download_url": "\(baseURL)/SHA256SUMS.txt"
                ]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }
}
