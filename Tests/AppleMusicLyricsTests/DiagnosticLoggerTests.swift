import Foundation
import XCTest
@testable import AppleMusicLyrics

final class DiagnosticLoggerTests: XCTestCase {
    func testWritesSanitizedMessages() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logger = DiagnosticLogger(directoryURL: directory)
        logger.info("first line\nsecond line")

        let contents = logger.contents()
        XCTAssertTrue(contents.contains("[INFO] first line second line"))
        XCTAssertFalse(contents.contains("first line\nsecond line"))
    }

    func testRotatesAtSizeLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logger = DiagnosticLogger(directoryURL: directory, maximumBytes: 1)
        logger.info("older entry")
        logger.info("newer entry")

        let previous = try String(contentsOf: logger.previousLogFileURL, encoding: .utf8)
        XCTAssertTrue(previous.contains("older entry"))
        XCTAssertTrue(logger.contents().contains("newer entry"))
    }
}
