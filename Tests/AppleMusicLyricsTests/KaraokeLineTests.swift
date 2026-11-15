import AppKit
import QuartzCore
import XCTest
@testable import AppleMusicLyrics

@MainActor
final class KaraokeLineTests: XCTestCase {
    /// When a word's sweep finishes, the opaque part of its mask must cover
    /// the whole word, so no letter is left dim (the first letters were).
    func testFinishedSweepLightsWholeWord() throws {
        let view = KaraokeLineNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let metrics = LyricsMetrics(fontSize: 40, width: 600)
        let groups: [[SyllableToken]] = [
            [SyllableToken(text: "All ", start: 1, end: 1.4)],
            [SyllableToken(text: "my ", start: 1.4, end: 1.7)],
            [SyllableToken(text: "bro", start: 1.7, end: 2.0), SyllableToken(text: "thers", start: 2.0, end: 2.6)]
        ]
        view.configure(groups: groups, metrics: metrics)
        let words = try XCTUnwrap(view.clock.sublayers)
        XCTAssertEqual(words.count, 4)
        for word in words {
            let bright = try XCTUnwrap(word.sublayers?.last)
            let mask = try XCTUnwrap(bright.mask as? CAGradientLayer)
            let sweep = try XCTUnwrap(mask.animation(forKey: "sweep") as? CABasicAnimation)
            let from = try XCTUnwrap(sweep.fromValue as? CGFloat)
            let to = try XCTUnwrap(sweep.toValue as? CGFloat)
            let locations = try XCTUnwrap(mask.locations).map { CGFloat($0.doubleValue) }
            let width = word.bounds.width
            // Start: the opaque part and the fade sit wholly left of the word.
            XCTAssertLessThanOrEqual(from + locations[2] * mask.bounds.width, 0.5)
            // End: opaque from the word's left edge to its right edge.
            XCTAssertLessThanOrEqual(to + locations[0] * mask.bounds.width, 0)
            XCTAssertGreaterThanOrEqual(to + locations[1] * mask.bounds.width, width - 0.5)
        }
    }
}
