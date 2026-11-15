import AppKit

// The lyrics windows draw their own controls, so the red, yellow and green
// title bar buttons stay hidden. AppKit rebuilds those buttons, visible
// again, whenever a window's style mask changes (resizing switched on or
// off when the floating lyrics are locked or Option is held, or entering
// and leaving full screen), so hiding them once at creation is not enough.

extension NSWindow {
    func hideStandardButtons() {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }
    }
}

final class ButtonlessPanel: NSPanel {
    override var styleMask: NSWindow.StyleMask {
        didSet { hideStandardButtons() }
    }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        hideStandardButtons()
    }
}

final class ButtonlessWindow: NSWindow {
    override var styleMask: NSWindow.StyleMask {
        didSet { hideStandardButtons() }
    }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        hideStandardButtons()
    }
}
