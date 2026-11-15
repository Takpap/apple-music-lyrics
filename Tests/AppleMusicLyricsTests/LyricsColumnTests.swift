import AppKit
import XCTest
@testable import AppleMusicLyrics

@MainActor
final class LyricsColumnTests: XCTestCase {
    private func state(_ items: [LyricDisplayItem], active: Int?) -> LyricsColumnState {
        LyricsColumnState(
            items: items, activeIndex: active, isSynced: true, isUserScrolling: false,
            manualScrollOffset: 0, showTranslation: true, hasExactWordTiming: false, isPlaying: true,
            metrics: LyricsMetrics(fontSize: 36, width: 500), anchorFraction: 0.35
        )
    }

    private func items() -> [LyricDisplayItem] {
        (0..<12).map { index in
            LyricDisplayItem(
                id: index,
                kind: .line(LyricLine(time: Double(index) * 3, text: "Ligne numéro \(index)", translation: "Line \(index)")),
                start: Double(index) * 3,
                end: Double(index) * 3 + 3
            )
        }
    }

    /// Advancing a line moves rows up, and each row's spring starts from
    /// where it was, so it visibly travels upward rather than jumping.
    func testAdvancingLineSpringsRowsUpFromTheirOldPlace() {
        let column = LyricsColumnView(model: ImmersiveLyricsModel())
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 700, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = column
        column.frame = NSRect(x: 0, y: 0, width: 700, height: 800)
        let items = items()
        column.update(state(items, active: 2), animated: false)
        column.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let row = column.rows[4]
        let before = row.frame.minY
        let layerBefore = row.layer!.position.y
        column.update(state(items, active: 3), animated: false)
        let after = row.frame.minY
        XCTAssertLessThan(after, before, "rows move up the column")
        // The layer's y runs the same way as the view's.
        let layerAfter = row.layer!.position.y
        XCTAssertEqual(layerAfter - layerBefore, after - before, accuracy: 0.5)

        let springs = (row.layer!.animationKeys() ?? []).compactMap { row.layer!.animation(forKey: $0) as? CASpringAnimation }
        let move = springs.first { $0.keyPath == "position.y" }
        XCTAssertNotNil(move)
        XCTAssertEqual((move?.fromValue as? CGFloat) ?? 0, before - after, accuracy: 0.5)
        XCTAssertEqual(row.visual.opacity, 1)
        // Eight lines on, a row has faded out and ignores clicks.
        let far = column.rows[11]
        XCTAssertEqual(far.visual.opacity, 0)
        XCTAssertNil(far.hitTest(NSPoint(x: far.frame.midX, y: far.frame.midY)))
        XCTAssertGreaterThan(column.rows[2].visual.blur, 0)
        XCTAssertEqual(column.rows[3].visual.blur, 0)
        XCTAssertGreaterThan(column.rows[3].frame.height, 36)
    }
}
