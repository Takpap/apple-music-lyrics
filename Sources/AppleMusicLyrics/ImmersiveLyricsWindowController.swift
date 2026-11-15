import AppKit
import SwiftUI

/// Owns the full-screen lyrics window. The app normally runs as a menu bar
/// accessory; while this window is open it becomes a regular app so it can
/// take a full-screen Space and appear in Command-Tab.
@MainActor
final class ImmersiveLyricsWindowController: NSObject, NSWindowDelegate {
    let model = ImmersiveLyricsModel()

    private var window: NSWindow?
    private var eventMonitor: Any?
    private var closeAfterExitingFullScreen = false

    var isVisible: Bool { window?.isVisible == true }

    override init() {
        super.init()
        model.onClose = { [weak self] in self?.hide() }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        model.activate()
        installEventMonitor()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible {
            if let screen = Self.preferredScreen() {
                window.setFrame(screen.visibleFrame.insetBy(dx: screen.visibleFrame.width * 0.08, dy: screen.visibleFrame.height * 0.08), display: false)
            }
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                window.animator().alphaValue = 1
            }
            if AppPreferences.immersiveOpensFullScreen,
               !window.styleMask.contains(.fullScreen) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    window.toggleFullScreen(nil)
                }
            }
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The Mac's own display when "Open on Mac's Display" is on (the
    /// default) or `--screen=builtin` / `AML_SCREEN=builtin` is given;
    /// otherwise, or with no built-in display, the display with the active
    /// window. `--screen=main` forces the latter.
    static func preferredScreen() -> NSScreen? {
        let argument = CommandLine.arguments
            .first { $0.hasPrefix("--screen=") }
            .map { String($0.dropFirst("--screen=".count)) }
            ?? ProcessInfo.processInfo.environment["AML_SCREEN"]
        let wantsBuiltIn = argument.map { $0 == "builtin" } ?? AppPreferences.immersiveOnBuiltInDisplay
        if wantsBuiltIn, let builtIn = builtInScreen() {
            return builtIn
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let id = screen.deviceDescription[key] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }

    func hide() {
        guard let window, window.isVisible else { return }
        if window.styleMask.contains(.fullScreen) {
            closeAfterExitingFullScreen = true
            window.toggleFullScreen(nil)
            return
        }
        finishHiding(window)
    }

    private func finishHiding(_ window: NSWindow) {
        closeAfterExitingFullScreen = false
        removeEventMonitor()
        model.deactivate()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                // Reopened while fading out: keep the window.
                guard !self.model.isActive else {
                    window.alphaValue = 1
                    return
                }
                window.orderOut(nil)
                NSApp.setActivationPolicy(.accessory)
                // Drop the window and its SwiftUI tree so a closed player
                // costs no memory; show() builds a fresh one.
                window.delegate = nil
                window.contentView = nil
                if self.window === window { self.window = nil }
                self.model.releaseArtwork()
            }
        })
    }

    private func makeWindow() -> NSWindow {
        let window = ButtonlessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Lyrics"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.minSize = NSSize(width: 520, height: 420)
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.appearance = NSAppearance(named: .darkAqua)
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        window.hideStandardButtons()
        let hosting = NSHostingView(rootView: ImmersiveLyricsRootView(model: model))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setFrameAutosaveName("ImmersiveLyricsWindow")
        return window
    }

    // MARK: Keyboard and scroll input

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            switch event.type {
            case .scrollWheel:
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
                if delta != 0 {
                    self.model.scroll(by: delta, limit: self.model.scrollLimit)
                    self.model.pokeChrome()
                }
                return nil
            case .keyDown:
                return self.handleKey(event) ? nil : event
            default:
                return event
            }
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53: // Escape
            hide()
            return true
        case 49 where modifiers.isEmpty: // Space
            model.togglePlayPause()
            return true
        case 123 where modifiers.contains(.command): // ⌘←
            model.previousTrack()
            return true
        case 124 where modifiers.contains(.command): // ⌘→
            model.nextTrack()
            return true
        case 123:
            model.seek(to: model.position() - 5)
            return true
        case 124:
            model.seek(to: model.position() + 5)
            return true
        case 13 where modifiers.contains(.command): // ⌘W
            hide()
            return true
        case 14 where modifiers.isEmpty: // E: correct the current line's translation
            model.openTranslationEditor()
            return true
        case 17 where modifiers.isEmpty: // T: show or hide translations
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { model.showTranslation.toggle() }
            return true
        default:
            return false
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        window?.hideStandardButtons()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        window?.hideStandardButtons()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.hideStandardButtons()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        window?.hideStandardButtons()
        guard closeAfterExitingFullScreen, let window else { return }
        finishHiding(window)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        window?.hideStandardButtons()
        model.pokeChrome()
    }
}
