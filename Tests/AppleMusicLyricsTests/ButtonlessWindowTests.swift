import AppKit
import XCTest
@testable import AppleMusicLyrics

@MainActor
final class ButtonlessWindowTests: XCTestCase {
    private let mask: NSWindow.StyleMask = [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow]

    func testButtonlessPanelKeepsButtonsHiddenAcrossStyleChanges() throws {
        let panel = ButtonlessPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: mask, backing: .buffered, defer: false)
        for _ in 0..<3 {
            panel.styleMask.remove(.resizable)
            XCTAssertEqual(panel.standardWindowButton(.closeButton)?.isHidden, true)
            panel.styleMask.insert(.resizable)
            XCTAssertEqual(panel.standardWindowButton(.closeButton)?.isHidden, true)
            XCTAssertEqual(panel.standardWindowButton(.zoomButton)?.isHidden, true)
        }
    }

    func testButtonlessWindowHidesButtonsFromTheStart() throws {
        let window = ButtonlessWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, true)
        window.styleMask.remove(.resizable)
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, true)
    }
}
