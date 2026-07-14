import Foundation
import XCTest
@testable import AppleMusicLyrics

final class AppleTTMLParserTests: XCTestCase {
    func testParsesWordTimingAndPreservesSeparators() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml"
            xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
            itunes:timing="Word">
          <body>
            <div>
              <p begin="1.000" end="3.500">
                <span begin="1.000" end="2.000">Hello</span> <span begin="2.000" end="3.500">world</span>
              </p>
              <p begin="1:02.500" end="1:04.000"><span begin="1:02.500" end="1:04.000">再见</span></p>
            </div>
          </body>
        </tt>
        """

        let result = try AppleTTMLParser.parse(ttml)

        XCTAssertEqual(result.wordTiming, .exact)
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0].text, "Hello world")
        XCTAssertEqual(result.lines[0].words.map(\.text), ["Hello", " world"])
        XCTAssertEqual(result.lines[0].words[0].start, 1, accuracy: 0.001)
        XCTAssertEqual(result.lines[0].words[1].end, 3.5, accuracy: 0.001)
        XCTAssertEqual(result.lines[1].time, 62.5, accuracy: 0.001)
    }

    func testParsesLineTimedTTMLWithoutInventingWordTiming() throws {
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div><p begin="2500ms" end="4s">One line</p></div></body>
        </tt>
        """

        let result = try AppleTTMLParser.parse(ttml)

        XCTAssertEqual(result.wordTiming, .none)
        XCTAssertEqual(result.lines.first?.text, "One line")
        XCTAssertEqual(result.lines.first?.time ?? 0, 2.5, accuracy: 0.001)
    }
}
