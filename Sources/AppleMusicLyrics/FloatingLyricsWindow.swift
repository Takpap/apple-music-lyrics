import AppKit
import CoreVideo
import QuartzCore

/// Floating Apple Music-style lyrics panel with a custom, continuously animated canvas.
final class FloatingLyricsController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "No track")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let headerLabels = NSStackView()
    private let canvas = LyricsCanvasView()
    private let toolbar = NSVisualEffectView()
    private let lockButton = NSButton()
    private let clickThroughButton = NSButton()
    private let modeButton = NSButton()
    private let settingsButton = NSButton()
    private let closeButton = NSButton()
    private let backdropView = NSVisualEffectView()
    private let contrastOverlay = PassthroughView()
    private weak var glassBackdropView: NSView?
    private var frameSaveWorkItem: DispatchWorkItem?
    private var moveEndWorkItem: DispatchWorkItem?
    private var localModifierMonitor: Any?
    private var globalModifierMonitor: Any?
    private var immersiveHeight = CGFloat(AppPreferences.floatingLyricsImmersiveHeight)
    private var frameBeforeZoom: NSRect?

    var onVisibilityChanged: ((Bool) -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    var onInteractionChanged: ((Bool, Bool) -> Void)?

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        configureContent()
        restoreFrame()
        applyPreferences(animated: false)
        installModifierMonitors()
    }

    deinit {
        if let localModifierMonitor { NSEvent.removeMonitor(localModifierMonitor) }
        if let globalModifierMonitor { NSEvent.removeMonitor(globalModifierMonitor) }
    }

    private func configurePanel() {
        panel.title = "Lyrics"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 300, height: 220)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.acceptsMouseMovedEvents = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func configureContent() {
        let effect = HoverTrackingView(frame: panel.contentView?.bounds ?? .zero)
        effect.autoresizingMask = [.width, .height]
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true

        backdropView.frame = effect.bounds
        backdropView.autoresizingMask = [.width, .height]
        backdropView.blendingMode = .behindWindow
        backdropView.state = .active
        effect.addSubview(backdropView)
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: effect.bounds)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = 10
            glass.style = .regular
            effect.addSubview(glass)
            glassBackdropView = glass
        }
#endif

        contrastOverlay.frame = effect.bounds
        contrastOverlay.autoresizingMask = [.width, .height]
        contrastOverlay.wantsLayer = true
        effect.addSubview(contrastOverlay)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor.withAlphaComponent(0.88)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.72)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        headerLabels.addArrangedSubview(titleLabel)
        headerLabels.addArrangedSubview(subtitleLabel)
        headerLabels.orientation = .vertical
        headerLabels.alignment = .leading
        headerLabels.spacing = 1
        headerLabels.translatesAutoresizingMaskIntoConstraints = false

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.onSeek = { [weak self] position in self?.onSeek?(position) }
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 8
        toolbar.layer?.masksToBounds = true

        let controls = NSStackView(views: [
            lockButton, clickThroughButton, modeButton, settingsButton, closeButton
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 2
        controls.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        controls.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(controls)

        configureToolbarButton(
            lockButton,
            symbol: "lock.open",
            toolTip: "Lock floating lyrics",
            action: #selector(handleToggleLocked(_:))
        )
        configureToolbarButton(
            clickThroughButton,
            symbol: "cursorarrow.rays",
            toolTip: "Let clicks pass through",
            action: #selector(handleToggleClickThrough(_:))
        )
        configureToolbarButton(
            modeButton,
            symbol: "rectangle.compress.vertical",
            toolTip: "Switch display mode",
            action: #selector(toggleMode)
        )
        configureToolbarButton(
            settingsButton,
            symbol: "slider.horizontal.3",
            toolTip: "Floating lyrics settings",
            action: #selector(showSettings)
        )
        configureToolbarButton(
            closeButton,
            symbol: "xmark",
            toolTip: "Hide floating lyrics",
            action: #selector(hideFromToolbar)
        )

        effect.addSubview(headerLabels)
        effect.addSubview(canvas)
        effect.addSubview(toolbar)
        panel.contentView = effect
        effect.onHoverChanged = { [weak self] hovering in
            self?.setToolbarVisible(hovering)
            self?.canvas.setPointerInside(hovering)
        }
        effect.onDoubleClickTop = { [weak self] in
            self?.toggleZoomedFrame()
        }

        NSLayoutConstraint.activate([
            headerLabels.topAnchor.constraint(equalTo: effect.topAnchor, constant: 14),
            headerLabels.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            headerLabels.trailingAnchor.constraint(lessThanOrEqualTo: toolbar.leadingAnchor, constant: -10),

            canvas.topAnchor.constraint(equalTo: headerLabels.bottomAnchor, constant: 8),
            canvas.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6),
            toolbar.centerYAnchor.constraint(equalTo: headerLabels.centerYAnchor),
            toolbar.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            controls.topAnchor.constraint(equalTo: toolbar.topAnchor),
            controls.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor)
        ])
        toolbar.alphaValue = 0
        toolbar.isHidden = true
    }

    private func configureToolbarButton(
        _ button: NSButton,
        symbol: String,
        toolTip: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = toolTip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    func show() {
        panel.orderFrontRegardless()
        canvas.setWindowVisible(true)
        onVisibilityChanged?(true)
        saveFrame()
    }

    func hide() {
        canvas.setWindowVisible(false)
        panel.orderOut(nil)
        onVisibilityChanged?(false)
        saveFrame()
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func setVisible(_ visible: Bool) {
        visible ? show() : hide()
    }

    func toggleLocked() {
        AppPreferences.floatingLyricsLocked.toggle()
        applyInteractionPreferences()
        applyAppearancePreferences()
        notifyInteractionChanged()
    }

    func toggleClickThrough() {
        AppPreferences.floatingLyricsClickThrough.toggle()
        applyInteractionPreferences()
        notifyInteractionChanged()
        if AppPreferences.floatingLyricsClickThrough {
            setToolbarVisible(false)
        }
    }

    private func applyPreferences(animated: Bool) {
        applyInteractionPreferences()
        applyAppearancePreferences()
        applySpacePreferences()
        applyMode(AppPreferences.floatingLyricsMode, animated: animated)
        canvas.setSupplementaryLyrics(
            showTranslation: AppPreferences.floatingLyricsShowTranslation,
            showTransliteration: AppPreferences.floatingLyricsShowTransliteration
        )
    }

    private func applyInteractionPreferences(optionHeld: Bool = false) {
        let locked = AppPreferences.floatingLyricsLocked
        let clickThrough = AppPreferences.floatingLyricsClickThrough
        panel.isMovableByWindowBackground = !locked
        if locked {
            panel.styleMask.remove(.resizable)
        } else {
            panel.styleMask.insert(.resizable)
        }
        panel.ignoresMouseEvents = (locked || clickThrough) && !optionHeld
        panel.hasShadow = !locked
        headerLabels.isHidden = locked
        if locked && !optionHeld {
            setToolbarVisible(false)
        }
        lockButton.image = NSImage(
            systemSymbolName: locked ? "lock.fill" : "lock.open",
            accessibilityDescription: locked ? "Unlock floating lyrics" : "Lock floating lyrics"
        )
        lockButton.toolTip = locked ? "Unlock floating lyrics" : "Lock floating lyrics"
        clickThroughButton.image = NSImage(
            systemSymbolName: clickThrough ? "cursorarrow.slash" : "cursorarrow.rays",
            accessibilityDescription: clickThrough ? "Disable click-through" : "Let clicks pass through"
        )
        clickThroughButton.contentTintColor = clickThrough ? .controlAccentColor : nil
    }

    private func applyAppearancePreferences() {
        let locked = AppPreferences.floatingLyricsLocked
        let blurStrength = AppPreferences.floatingLyricsBlurStrength
        backdropView.material = AppPreferences.floatingLyricsBlurStrength.material
        backdropView.alphaValue = CGFloat(AppPreferences.floatingLyricsOpacity)
        backdropView.isHidden = locked
        let overlayAlpha: CGFloat
        switch blurStrength {
        case .subtle: overlayAlpha = 0.06
        case .regular: overlayAlpha = 0.12
        case .strong: overlayAlpha = 0.18
        }
        contrastOverlay.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(overlayAlpha)
            .cgColor
        contrastOverlay.isHidden = locked
#if compiler(>=6.2)
        if #available(macOS 26.0, *),
           let glass = glassBackdropView as? NSGlassEffectView {
            backdropView.isHidden = true
            glass.style = blurStrength == .subtle ? .clear : .regular
            let tintAlpha: CGFloat
            switch blurStrength {
            case .subtle: tintAlpha = 0.08
            case .regular: tintAlpha = 0.16
            case .strong: tintAlpha = 0.26
            }
            glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(tintAlpha)
            glass.alphaValue = CGFloat(AppPreferences.floatingLyricsOpacity)
            glass.isHidden = locked
        }
#endif
    }

    private func applySpacePreferences() {
        var behavior: NSWindow.CollectionBehavior = []
        switch AppPreferences.floatingLyricsSpaceBehavior {
        case .currentDesktop:
            behavior.insert(.moveToActiveSpace)
        case .allSpaces:
            behavior.formUnion([.canJoinAllSpaces, .stationary])
        }
        if AppPreferences.floatingLyricsShowOverFullScreen {
            behavior.insert(.fullScreenAuxiliary)
        }
        panel.collectionBehavior = behavior
    }

    private func applyMode(_ mode: FloatingLyricsMode, animated: Bool) {
        let previousMode = canvas.displayMode
        canvas.setDisplayMode(mode)
        modeButton.image = NSImage(
            systemSymbolName: mode == .immersive
                ? "rectangle.compress.vertical"
                : "rectangle.expand.vertical",
            accessibilityDescription: "Switch display mode"
        )

        var frame = panel.frame
        if mode == .desktop {
            if previousMode == .immersive, frame.height > 260 {
                immersiveHeight = frame.height
                AppPreferences.floatingLyricsImmersiveHeight = frame.height
            }
            panel.minSize = NSSize(width: 300, height: 210)
            panel.maxSize = NSSize(width: 10_000, height: 260)
            let targetHeight = min(240, max(210, frame.height))
            frame.origin.y += frame.height - targetHeight
            frame.size.height = targetHeight
        } else {
            panel.minSize = NSSize(width: 300, height: 220)
            panel.maxSize = NSSize(width: 10_000, height: 10_000)
            if previousMode != .immersive {
                let targetHeight = max(220, immersiveHeight)
                frame.origin.y -= targetHeight - frame.height
                frame.size.height = targetHeight
            }
        }
        if panel.frame != frame {
            panel.setFrame(frame, display: true, animate: animated)
        }
        saveFrame()
    }

    private func installModifierMonitors() {
        localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.applyTemporaryOptionInteraction(event.modifierFlags.contains(.option))
            return event
        }
        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            DispatchQueue.main.async {
                self?.applyTemporaryOptionInteraction(event.modifierFlags.contains(.option))
            }
        }
    }

    private func applyTemporaryOptionInteraction(_ optionHeld: Bool) {
        guard AppPreferences.floatingLyricsLocked
                || AppPreferences.floatingLyricsClickThrough else { return }
        applyInteractionPreferences(optionHeld: optionHeld)
        if optionHeld {
            panel.orderFrontRegardless()
            setToolbarVisible(true)
        } else {
            setToolbarVisible(false)
        }
    }

    private func setToolbarVisible(_ visible: Bool) {
        guard !visible || !panel.ignoresMouseEvents else { return }
        if visible { toolbar.isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            toolbar.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            if !visible, self?.toolbar.alphaValue == 0 {
                self?.toolbar.isHidden = true
            }
        }
    }

    @objc private func handleToggleLocked(_ sender: Any?) {
        toggleLocked()
    }

    @objc private func handleToggleClickThrough(_ sender: Any?) {
        toggleClickThrough()
    }

    @objc private func toggleMode(_ sender: Any?) {
        let mode: FloatingLyricsMode = AppPreferences.floatingLyricsMode == .immersive
            ? .desktop
            : .immersive
        AppPreferences.floatingLyricsMode = mode
        applyMode(mode, animated: true)
    }

    @objc private func hideFromToolbar(_ sender: Any?) {
        hide()
    }

    private func toggleZoomedFrame() {
        if let restoreFrame = frameBeforeZoom {
            frameBeforeZoom = nil
            panel.setFrame(
                restoreFrame,
                display: true,
                animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
            saveFrame()
            return
        }

        guard let screen = panel.screen ?? NSScreen.main else { return }
        frameBeforeZoom = panel.frame
        panel.setFrame(
            screen.visibleFrame,
            display: true,
            animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    @objc private func showSettings(_ sender: NSButton) {
        let menu = settingsMenu()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: sender.bounds.maxX, y: sender.bounds.minY),
            in: sender
        )
    }

    private func settingsMenu() -> NSMenu {
        let menu = NSMenu(title: "Floating Lyrics Settings")

        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "Appearance")
        for strength in FloatingLyricsBlurStrength.allCases {
            let item = NSMenuItem(
                title: "Blur: \(strength.title)",
                action: #selector(selectBlurStrength(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = strength.rawValue
            item.state = AppPreferences.floatingLyricsBlurStrength == strength ? .on : .off
            appearanceMenu.addItem(item)
        }
        appearanceMenu.addItem(.separator())
        let opacityItem = NSMenuItem()
        let opacityControl = OpacityMenuControl(value: AppPreferences.floatingLyricsOpacity)
        opacityControl.slider.target = self
        opacityControl.slider.action = #selector(changeOpacity(_:))
        opacityItem.view = opacityControl
        appearanceMenu.addItem(opacityItem)
        appearance.submenu = appearanceMenu
        menu.addItem(appearance)

        let spaces = NSMenuItem(title: "Desktop & Full Screen", action: nil, keyEquivalent: "")
        let spacesMenu = NSMenu(title: "Desktop & Full Screen")
        for behavior in FloatingLyricsSpaceBehavior.allCases {
            let item = NSMenuItem(
                title: behavior.title,
                action: #selector(selectSpaceBehavior(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = behavior.rawValue
            item.state = AppPreferences.floatingLyricsSpaceBehavior == behavior ? .on : .off
            spacesMenu.addItem(item)
        }
        let fullScreen = NSMenuItem(
            title: "Show Above Full-Screen Apps",
            action: #selector(toggleFullScreenVisibility(_:)),
            keyEquivalent: ""
        )
        fullScreen.target = self
        fullScreen.state = AppPreferences.floatingLyricsShowOverFullScreen ? .on : .off
        spacesMenu.addItem(.separator())
        spacesMenu.addItem(fullScreen)
        spaces.submenu = spacesMenu
        menu.addItem(spaces)

        menu.addItem(.separator())
        menu.addItem(toggleItem(
            title: "Show Translation",
            enabled: AppPreferences.floatingLyricsShowTranslation,
            action: #selector(toggleTranslation(_:))
        ))
        menu.addItem(toggleItem(
            title: "Show Transliteration",
            enabled: AppPreferences.floatingLyricsShowTransliteration,
            action: #selector(toggleTransliteration(_:))
        ))
        return menu
    }

    private func toggleItem(title: String, enabled: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = enabled ? .on : .off
        return item
    }

    @objc private func selectBlurStrength(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let strength = FloatingLyricsBlurStrength(rawValue: rawValue) else { return }
        AppPreferences.floatingLyricsBlurStrength = strength
        applyAppearancePreferences()
    }

    @objc private func changeOpacity(_ sender: NSSlider) {
        AppPreferences.floatingLyricsOpacity = sender.doubleValue
        applyAppearancePreferences()
    }

    @objc private func selectSpaceBehavior(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let behavior = FloatingLyricsSpaceBehavior(rawValue: rawValue) else { return }
        AppPreferences.floatingLyricsSpaceBehavior = behavior
        applySpacePreferences()
    }

    @objc private func toggleFullScreenVisibility(_ sender: NSMenuItem) {
        AppPreferences.floatingLyricsShowOverFullScreen.toggle()
        applySpacePreferences()
    }

    @objc private func toggleTranslation(_ sender: NSMenuItem) {
        AppPreferences.floatingLyricsShowTranslation.toggle()
        canvas.setSupplementaryLyrics(
            showTranslation: AppPreferences.floatingLyricsShowTranslation,
            showTransliteration: AppPreferences.floatingLyricsShowTransliteration
        )
    }

    @objc private func toggleTransliteration(_ sender: NSMenuItem) {
        AppPreferences.floatingLyricsShowTransliteration.toggle()
        canvas.setSupplementaryLyrics(
            showTranslation: AppPreferences.floatingLyricsShowTranslation,
            showTransliteration: AppPreferences.floatingLyricsShowTransliteration
        )
    }

    private func notifyInteractionChanged() {
        onInteractionChanged?(
            AppPreferences.floatingLyricsLocked,
            AppPreferences.floatingLyricsClickThrough
        )
    }

    func apply(status: AppStatus) {
        switch status {
        case .idle:
            updateHeader(title: "No track", subtitle: "")
            canvas.clear()

        case .musicNotRunning:
            updateHeader(title: "Music is not running", subtitle: "Open Music to show lyrics")
            canvas.showMessage("Waiting for Music")

        case .stopped:
            updateHeader(title: "Playback stopped", subtitle: "")
            canvas.showMessage("Playback stopped")

        case .loadingLyrics(let track):
            updateHeader(title: track.title, subtitle: track.artist)
            canvas.showMessage("Loading lyrics...")

        case .showing(let track, let lyrics, _):
            updateHeader(title: track.title, subtitle: headerSubtitle(for: track))
            if lyrics.isSynced {
                canvas.setLyrics(lyrics, track: track)
            } else if let plain = lyrics.plainText {
                canvas.showPlainText(plain)
            } else {
                canvas.showMessage("No lyrics")
            }

        case .noLyrics(let track):
            updateHeader(title: track.title, subtitle: headerSubtitle(for: track))
            canvas.showMessage("No lyrics in Music cache")

        case .error(let message):
            updateHeader(title: "Unable to show lyrics", subtitle: "")
            canvas.showMessage(message)
        }
    }

    /// Lightweight path used for position samples within the same lyrics document.
    func updateHighlight(for track: TrackInfo, lyrics: LyricsDocument) {
        guard lyrics.isSynced else { return }
        subtitleLabel.stringValue = headerSubtitle(for: track)
        canvas.update(track: track, lyrics: lyrics)
    }

    private func updateHeader(title: String, subtitle: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        panel.title = title
    }

    private func headerSubtitle(for track: TrackInfo) -> String {
        let state = track.state == .paused ? "Paused" : "Playing"
        return track.artist.isEmpty ? state : "\(track.artist)  ·  \(state)"
    }

    private func saveFrame() {
        frameSaveWorkItem?.cancel()
        frameSaveWorkItem = nil
        guard frameBeforeZoom == nil else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        var frames = AppPreferences.floatingLyricsFramesByDisplay
        let id = displayID(for: screen)
        frames[id] = NSStringFromRect(panel.frame)
        AppPreferences.floatingLyricsFramesByDisplay = frames
        AppPreferences.floatingLyricsLastDisplay = id
        if canvas.displayMode == .immersive {
            immersiveHeight = panel.frame.height
            AppPreferences.floatingLyricsImmersiveHeight = panel.frame.height
        }
    }

    private func scheduleFrameSave() {
        frameSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveFrame()
        }
        frameSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func restoreFrame() {
        let frames = AppPreferences.floatingLyricsFramesByDisplay
        let lastDisplay = AppPreferences.floatingLyricsLastDisplay
        let preferredScreens = NSScreen.screens.sorted {
            displayID(for: $0) == lastDisplay && displayID(for: $1) != lastDisplay
        }
        for screen in preferredScreens {
            guard let raw = frames[displayID(for: screen)] else { continue }
            let frame = NSRectFromString(raw)
            if frame.width > 100,
               frame.height > 100,
               frame.intersects(screen.visibleFrame) {
                panel.setFrame(frame, display: false)
                return
            }
        }
        // Migration from versions that stored one frame for every display.
        if let raw = UserDefaults.standard.string(forKey: "floatingLyrics.frame") {
            let frame = NSRectFromString(raw)
            if frame.width > 100, frame.height > 100 {
                panel.setFrame(frame, display: false)
                return
            }
        }
        if let screen = NSScreen.main {
            let size = panel.frame.size
            panel.setFrameOrigin(
                NSPoint(
                    x: screen.visibleFrame.midX - size.width / 2,
                    y: screen.visibleFrame.minY + 80
                )
            )
        }
    }

    private func displayID(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return number.stringValue
        }
        return String(format: "%.0f,%.0f", screen.frame.origin.x, screen.frame.origin.y)
    }

    func windowWillClose(_ notification: Notification) {
        canvas.setWindowVisible(false)
        onVisibilityChanged?(false)
        saveFrame()
    }

    func windowWillMove(_ notification: Notification) {
        moveEndWorkItem?.cancel()
        saveFrame()
        panel.hasShadow = false
        canvas.beginWindowMove()
    }

    func windowDidMove(_ notification: Notification) {
        guard !panel.inLiveResize else { return }
        scheduleFrameSave()

        moveEndWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.canvas.endWindowMove()
            self.panel.hasShadow = !AppPreferences.floatingLyricsLocked
            self.panel.invalidateShadow()
        }
        moveEndWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        panel.hasShadow = false
        canvas.beginLiveResize()
    }

    func windowDidResize(_ notification: Notification) {
        if panel.inLiveResize {
            canvas.updateLiveResize()
            return
        }
        scheduleFrameSave()
        canvas.invalidateGeometry()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        canvas.endLiveResize()
        panel.hasShadow = !AppPreferences.floatingLyricsLocked
        panel.invalidateShadow()
        saveFrame()
    }
}

private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class HoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onDoubleClickTop: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, location.y >= bounds.maxY - 54 {
            onDoubleClickTop?()
            return
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

private final class OpacityMenuControl: NSView {
    let slider: NSSlider

    init(value: Double) {
        slider = NSSlider(value: value, minValue: 0.35, maxValue: 1, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 38))
        let label = NSTextField(labelWithString: "Opacity")
        label.font = .menuFont(ofSize: 0)
        label.translatesAutoresizingMaskIntoConstraints = false
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(slider)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 54),
            slider.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Lyrics canvas

private final class LyricsCanvasView: NSView {
    private struct PendingLyricClick {
        let lineIndex: Int
        let screenLocation: NSPoint
    }

    private enum AnimationSpec {
        static let lineStateDuration: CFTimeInterval = 0.33
        static let lineSpringMass: CGFloat = 1
        static let lineSpringStiffness: CGFloat = 140
        static let lineSpringDamping: CGFloat = 24
        static let lineScrollHeadstart: TimeInterval = 0.5
        static let manualScrollFollowDelay: TimeInterval = 3
        static let lineTapProgressFreezeDuration: TimeInterval = 0.55
        static let featherWidth: CGFloat = 10
        static let animationHeadstart: TimeInterval = 0
        static let clickDragThreshold: CGFloat = 5
    }

    private var layoutSize: NSSize {
        guard isLiveResizing else { return bounds.size }
        return NSSize(
            width: max(1, (bounds.width / 12).rounded() * 12),
            height: max(1, (bounds.height / 10).rounded() * 10)
        )
    }

    private var typographyScale: CGFloat {
        let widthScale = layoutSize.width / 460
        let heightScale = layoutSize.height / 315
        var scale = min(widthScale, heightScale)
        if displayMode == .immersive {
            let aspectRatio = layoutSize.height / max(1, layoutSize.width)
            let tallWindowBoost = min(1.14, max(1, 1 + (aspectRatio - 1.6) * 0.10))
            scale = min(widthScale * 1.12, scale * tallWindowBoost)
        }
        return min(2.2, max(0.85, scale))
    }

    private var horizontalInset: CGFloat {
        min(64, max(20, layoutSize.width * 0.055))
    }

    private var contentOriginX: CGFloat {
        (bounds.width - layoutSize.width) / 2 + horizontalInset
    }

    private var contentWidth: CGFloat {
        max(80, layoutSize.width - horizontalInset * 2)
    }

    private var activeFont: NSFont {
        .systemFont(ofSize: 19 * typographyScale, weight: .semibold)
    }

    // The lyric container flips its sublayer geometry, so the content-space
    // ratio is the inverse of the desired visual position.
    private var scrollFocusRatio: CGFloat {
        displayMode == .desktop ? 0.55 : 0.56
    }

    private var visibleLineRadius: Int {
        guard displayMode == .immersive else { return 1 }
        let averageHeight: CGFloat
        if lineHeights.isEmpty {
            averageHeight = 39 * typographyScale
        } else {
            averageHeight = lineHeights.reduce(0, +) / CGFloat(lineHeights.count)
                + 5 * typographyScale
        }
        let rowsNeeded = Int(ceil(bounds.height * 0.62 / max(1, averageHeight))) + 1
        return min(18, max(5, rowsNeeded))
    }

    private var lines: [LyricLine] = []
    private var activeIndex: Int?
    private var message: String?
    private var plainText: String?

    private var lineCenters: [CGFloat] = []
    private var lineHeights: [CGFloat] = []
    private var geometryWidth: CGFloat = 0
    private var geometryScale: CGFloat = 0
    private var geometryLinesID: [String] = []

    private lazy var displayLink = DisplayLinkDriver { [weak self] in
        self?.updateLayerPresentation()
    }
    private var isLiveResizing = false
    private var liveResizeBaseSize: NSSize = .zero
    private var liveResizeBaseTypographyScale: CGFloat = 1
    private var isWindowMoving = false
    private var isWindowVisible = false
    private(set) var displayMode: FloatingLyricsMode = .immersive
    private var showsTranslation = true
    private var showsTransliteration = true
    private var hoveredLineIndex: Int?
    private var pointerInside = false
    private var browsingIndex: Int?
    private var isManualScrolling = false
    private var autoFollowResumeDeadline: CFTimeInterval = 0
    private var manualScrollEndWorkItem: DispatchWorkItem?
    private var frozenPosition: TimeInterval?
    private var frozenPositionDeadline: CFTimeInterval = 0
    private var pendingLyricClick: PendingLyricClick?

    var onSeek: ((TimeInterval) -> Void)?

    private var basePosition: TimeInterval = 0
    private var sampledAt = CACurrentMediaTime()
    private var isPlaying = false

    private let edgeMask = CAGradientLayer()
    private let lyricsLayer = NoImplicitAnimationLayer()
    private var karaokeLayers: [KaraokeLineLayer] = []
    private var visualActiveIndex: Int?
    private var visualScrollIndex: Int?
    private var isScrollStateInitialized = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        manualScrollEndWorkItem?.cancel()
        displayLink.stop()
    }

    override var isFlipped: Bool { true }

    private func setup() {
        wantsLayer = true
        lyricsLayer.isGeometryFlipped = true
        layer?.addSublayer(lyricsLayer)
        edgeMask.colors = [
            NSColor.clear.cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.clear.cgColor
        ]
        edgeMask.locations = [0, 0.12, 0.88, 1]
        edgeMask.startPoint = CGPoint(x: 0.5, y: 0)
        edgeMask.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.mask = edgeMask
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    func setDisplayMode(_ mode: FloatingLyricsMode) {
        guard displayMode != mode else { return }
        displayMode = mode
        updateLayerPresentation(animateLineChange: false)
    }

    func setSupplementaryLyrics(showTranslation: Bool, showTransliteration: Bool) {
        guard showsTranslation != showTranslation
                || showsTransliteration != showTransliteration else { return }
        showsTranslation = showTranslation
        showsTransliteration = showTransliteration
        invalidateGeometry()
    }

    func setPointerInside(_ inside: Bool) {
        pointerInside = inside
        if !inside { updateHoveredLine(nil) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeMask.frame = bounds
        if isLiveResizing {
            applyLiveResizeTransform()
        } else {
            resetLyricsLayerGeometry()
        }
        CATransaction.commit()
        if !isLiveResizing
            && (
                abs(geometryWidth - layoutSize.width) > 0.5
                    || abs(geometryScale - typographyScale) > 0.01
            ) {
            // AppKit forbids recursively rebuilding TextKit content from layout().
            // The next playback update or resize delegate callback performs it.
            geometryWidth = 0
            geometryScale = 0
            geometryLinesID = []
        }
    }

    func setLyrics(_ document: LyricsDocument, track: TrackInfo) {
        let changed = document.lines != lines
        lines = document.lines
        message = nil
        plainText = nil
        updateClock(track)
        activeIndex = document.lineIndex(at: track.position)
        if changed {
            invalidateGeometry()
        }
        rebuildLayersIfNeeded()
        updateLayerPresentation(animateLineChange: false)
        updateTimerState()
        needsDisplay = true
    }

    func update(track: TrackInfo, lyrics: LyricsDocument) {
        if lyrics.lines != lines {
            setLyrics(lyrics, track: track)
            return
        }
        updateClock(track)
        rebuildLayersIfNeeded()
        updateLayerPresentation()
        updateTimerState()
    }

    func clear() {
        lines = []
        message = nil
        plainText = nil
        stopTimer()
        clearKaraokeLayers()
        needsDisplay = true
    }

    func showMessage(_ text: String) {
        lines = []
        plainText = nil
        message = text
        stopTimer()
        clearKaraokeLayers()
        needsDisplay = true
    }

    func showPlainText(_ text: String) {
        lines = []
        message = nil
        plainText = text
        stopTimer()
        clearKaraokeLayers()
        needsDisplay = true
    }

    func invalidateGeometry() {
        geometryWidth = 0
        geometryScale = 0
        geometryLinesID = []
        if !isLiveResizing {
            rebuildLayersIfNeeded()
            updateLayerPresentation(animateLineChange: false)
        }
        needsDisplay = true
    }

    func beginLiveResize() {
        guard !isLiveResizing else { return }
        pendingLyricClick = nil
        liveResizeBaseSize = bounds.size
        liveResizeBaseTypographyScale = typographyScale
        isLiveResizing = true
        updateLiveResize()
        updateTimerState()
    }

    func updateLiveResize() {
        guard isLiveResizing else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeMask.frame = bounds
        applyLiveResizeTransform()
        CATransaction.commit()
    }

    func endLiveResize() {
        guard isLiveResizing else { return }
        isLiveResizing = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        resetLyricsLayerGeometry()
        CATransaction.commit()
        liveResizeBaseSize = .zero
        invalidateGeometry()
        updateTimerState()
    }

    private func applyLiveResizeTransform() {
        guard liveResizeBaseSize.width > 0,
              liveResizeBaseSize.height > 0 else { return }
        let widthScale = bounds.width / 460
        let heightScale = bounds.height / 315
        let targetTypographyScale = min(2.2, max(0.85, min(widthScale, heightScale)))
        let scale = targetTypographyScale / max(0.01, liveResizeBaseTypographyScale)
        lyricsLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        lyricsLayer.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    private func resetLyricsLayerGeometry() {
        lyricsLayer.transform = CATransform3DIdentity
        var layerBounds = lyricsLayer.bounds
        layerBounds.size = bounds.size
        lyricsLayer.bounds = layerBounds
        lyricsLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func beginWindowMove() {
        guard !isWindowMoving else { return }
        pendingLyricClick = nil
        isWindowMoving = true
        stopTimer()
    }

    func endWindowMove() {
        guard isWindowMoving else { return }
        isWindowMoving = false
        updateTimerState()
    }

    func setWindowVisible(_ visible: Bool) {
        isWindowVisible = visible
        updateTimerState()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // This view is transparent and layer-backed. Clear retained pixels so
        // a previously sung line cannot keep the next line fully highlighted.
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)

        if let message {
            drawMessage(message)
            return
        }
        if let plainText {
            drawPlainText(plainText)
            return
        }
        // Synced lyrics are persistent sublayers and never redraw through AppKit.
    }

    private func rebuildLayersIfNeeded() {
        let ids = lines.map(\.id)
        let scale = typographyScale
        guard abs(geometryWidth - layoutSize.width) > 0.5
                || abs(geometryScale - scale) > 0.01
                || geometryLinesID != ids else { return }

        geometryWidth = layoutSize.width
        geometryScale = scale
        geometryLinesID = ids
        let width = contentWidth
        var cursor: CGFloat = 0
        lineCenters = []
        lineHeights = []
        clearKaraokeLayers()

        for (index, line) in lines.enumerated() {
            let fallbackEnd = index + 1 < lines.count
                ? max(line.time + 0.01, lines[index + 1].time)
                : max(line.time + 2, line.endTime)
            let lineLayer = KaraokeLineLayer(
                line: line,
                fallbackEnd: fallbackEnd,
                font: activeFont,
                supplementaryText: supplementaryText(for: line),
                width: width,
                contentsScale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
                featherWidth: AnimationSpec.featherWidth * scale
            )
            let height = max(34 * scale, lineLayer.textHeight + 12 * scale)
            lineHeights.append(height)
            lineCenters.append(cursor + height / 2)
            lineLayer.bounds = CGRect(x: 0, y: 0, width: width, height: lineLayer.textHeight)
            lineLayer.position = CGPoint(
                x: contentOriginX + width / 2,
                y: cursor + height / 2
            )
            lineLayer.isHidden = true
            lyricsLayer.addSublayer(lineLayer)
            karaokeLayers.append(lineLayer)
            cursor += height + 5 * scale
        }
        let contentHeight = max(0, cursor - 5 * scale)
        for index in karaokeLayers.indices {
            let mirroredCenter = contentHeight - lineCenters[index]
            lineCenters[index] = mirroredCenter
            karaokeLayers[index].position.y = mirroredCenter
        }
        lyricsLayer.isHidden = lines.isEmpty
    }

    private func drawMessage(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: min(22, 14 * typographyScale),
                    weight: .medium
                ),
                .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.72),
                .paragraphStyle: paragraph
            ]
        )
        let width = contentWidth
        let height = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        attributed.draw(
            with: NSRect(
                x: contentOriginX,
                y: (bounds.height - height) / 2,
                width: width,
                height: height
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    private func drawPlainText(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineSpacing = 5
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: min(24, 14 * typographyScale),
                    weight: .regular
                ),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.72),
                .paragraphStyle: paragraph
            ]
        )
        attributed.draw(
            with: NSRect(
                x: contentOriginX,
                y: 20 * min(1.6, typographyScale),
                width: contentWidth,
                height: max(0, bounds.height - 40 * min(1.6, typographyScale))
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    private func updateClock(_ track: TrackInfo) {
        let now = CACurrentMediaTime()
        if let frozenPosition,
           abs(track.position - frozenPosition) < 0.8 {
            self.frozenPosition = nil
            frozenPositionDeadline = 0
        }
        let estimated = interpolatedPosition(at: now)
        let error = track.position - estimated
        if isPlaying, abs(error) < 0.75 {
            basePosition = estimated + error * 0.06
        } else {
            basePosition = track.position
        }
        sampledAt = now
        isPlaying = track.state == .playing
    }

    private func interpolatedPosition(at now: CFTimeInterval) -> TimeInterval {
        if let frozenPosition, now < frozenPositionDeadline {
            return frozenPosition
        }
        return basePosition + (isPlaying ? max(0, now - sampledAt) : 0)
    }

    private func lineIndex(at position: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        var lowerBound = 0
        var upperBound = lines.count - 1
        var result: Int?

        while lowerBound <= upperBound {
            let index = (lowerBound + upperBound) / 2
            if lines[index].time <= position {
                result = index
                lowerBound = index + 1
            } else {
                upperBound = index - 1
            }
        }
        return result
    }

    private func updateLayerPresentation(animateLineChange: Bool = true) {
        guard !lines.isEmpty else { return }
        if !isLiveResizing {
            rebuildLayersIfNeeded()
        }

        let frameTime = CACurrentMediaTime()
        let position = interpolatedPosition(at: frameTime)
        let resolvedIndex: Int
        if let index = lineIndex(at: position) {
            resolvedIndex = index
        } else {
            resolvedIndex = 0
        }
        let lineChanged = activeIndex != resolvedIndex
        let previousIndex = activeIndex
        activeIndex = resolvedIndex
        guard resolvedIndex < karaokeLayers.count else { return }
        var needsLineStateUpdate = lineChanged || visualActiveIndex != resolvedIndex
        let anticipatedIndex = lineIndex(
            at: position + AnimationSpec.lineScrollHeadstart
        ) ?? resolvedIndex
        let scrollIndex = min(resolvedIndex + 1, anticipatedIndex)
        let shouldResumeAutoFollow = !isManualScrolling
            && autoFollowResumeDeadline > 0
            && frameTime >= autoFollowResumeDeadline
        if shouldResumeAutoFollow {
            autoFollowResumeDeadline = 0
            browsingIndex = nil
            visualScrollIndex = nil
            needsLineStateUpdate = true
        }
        let autoFollowSuppressed = isManualScrolling || autoFollowResumeDeadline > frameTime
        let needsScrollUpdate = visualScrollIndex != scrollIndex

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if needsLineStateUpdate || !animateLineChange {
            updateLineStates(activeIndex: resolvedIndex, animated: animateLineChange)
            if !animateLineChange
                || previousIndex == nil
                || abs((previousIndex ?? resolvedIndex) - resolvedIndex) > 1 {
                for (index, lineLayer) in karaokeLayers.enumerated() where index != resolvedIndex {
                    lineLayer.updateProgress(
                        position: position + AnimationSpec.animationHeadstart,
                        animated: animateLineChange
                    )
                }
            } else if let previousIndex, previousIndex < karaokeLayers.count {
                karaokeLayers[previousIndex].updateProgress(
                    position: position + AnimationSpec.animationHeadstart,
                    animated: animateLineChange
                )
            }
        }
        if !autoFollowSuppressed && (needsScrollUpdate || !animateLineChange) {
            visualScrollIndex = scrollIndex
            let isContinuousAdvance = previousIndex == nil
                || abs((previousIndex ?? resolvedIndex) - resolvedIndex) <= 1
            scroll(
                to: scrollIndex,
                animated: animateLineChange && isContinuousAdvance
            )
        }
        karaokeLayers[resolvedIndex].updateProgress(
            position: position + AnimationSpec.animationHeadstart,
            animated: animateLineChange
        )
        CATransaction.commit()
    }

    private func updateLineStates(activeIndex: Int, animated: Bool) {
        let previous = visualActiveIndex
        visualActiveIndex = activeIndex
        let visibilityCenter = browsingIndex ?? activeIndex
        let visibleRadius = visibleLineRadius

        for index in karaokeLayers.indices {
            let lineLayer = karaokeLayers[index]
            let viewportDistance = abs(index - visibilityCenter)
            let wasRecentlyActive = previous.map { abs(index - $0) <= 1 } ?? false
            if viewportDistance <= visibleRadius + 2 || wasRecentlyActive {
                lineLayer.prepareForDisplay()
            }
            let opacity: Float
            if index == activeIndex {
                opacity = 1
            } else {
                opacity = max(0.10, 0.68 - Float(viewportDistance) * 0.10)
            }
            lineLayer.setVisualState(
                opacity: opacity,
                scale: 1,
                hidden: displayMode == .desktop
                    ? !(index == visibilityCenter || index == visibilityCenter + 1)
                    : viewportDistance > visibleRadius,
                animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                duration: AnimationSpec.lineStateDuration
            )
        }
    }

    private func scroll(to index: Int, animated: Bool) {
        let target = lineCenters[index] - bounds.height * scrollFocusRatio
        if !isScrollStateInitialized {
            isScrollStateInitialized = true
            setScrollPosition(target)
            return
        }

        guard animated,
              isPlaying,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            lyricsLayer.removeAnimation(forKey: "lineScroll")
            setScrollPosition(target)
            return
        }

        let current = lyricsLayer.presentation()?.bounds.origin.y
            ?? lyricsLayer.bounds.origin.y
        lyricsLayer.removeAnimation(forKey: "lineScroll")
        setScrollPosition(target)
        let spring = CASpringAnimation(keyPath: "bounds.origin.y")
        spring.fromValue = current
        spring.toValue = target
        spring.mass = AnimationSpec.lineSpringMass
        spring.stiffness = AnimationSpec.lineSpringStiffness
        spring.damping = AnimationSpec.lineSpringDamping
        spring.duration = spring.settlingDuration
        lyricsLayer.add(spring, forKey: "lineScroll")
    }

    private func setScrollPosition(_ position: CGFloat) {
        var newBounds = lyricsLayer.bounds
        newBounds.origin.y = position
        lyricsLayer.bounds = newBounds
    }

    private func clearKaraokeLayers() {
        karaokeLayers.forEach { $0.removeFromSuperlayer() }
        karaokeLayers = []
        visualActiveIndex = nil
        visualScrollIndex = nil
        lyricsLayer.removeAnimation(forKey: "lineScroll")
        browsingIndex = nil
        isManualScrolling = false
        pendingLyricClick = nil
        autoFollowResumeDeadline = 0
        manualScrollEndWorkItem?.cancel()
        manualScrollEndWorkItem = nil
        isScrollStateInitialized = false
        lyricsLayer.isHidden = true
    }

    private func supplementaryText(for line: LyricLine) -> String? {
        var values: [String] = []
        if showsTransliteration,
           let transliteration = line.transliteration,
           !transliteration.isEmpty {
            values.append(transliteration)
        }
        if showsTranslation,
           let translation = line.translation,
           !translation.isEmpty {
            values.append(translation)
        }
        return values.isEmpty ? nil : values.joined(separator: "\n")
    }

    override func scrollWheel(with event: NSEvent) {
        pendingLyricClick = nil
        guard !lines.isEmpty,
              !isLiveResizing else {
            super.scrollWheel(with: event)
            return
        }

        let current = lyricsLayer.presentation()?.bounds.origin.y
            ?? lyricsLayer.bounds.origin.y
        lyricsLayer.removeAnimation(forKey: "lineScroll")
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let proposed = current + event.scrollingDeltaY * multiplier
        let targets = lineCenters.map { $0 - bounds.height * scrollFocusRatio }
        guard let minimum = targets.min(), let maximum = targets.max() else { return }
        let position = min(maximum, max(minimum, proposed))

        isScrollStateInitialized = true
        isManualScrolling = true
        autoFollowResumeDeadline = CACurrentMediaTime()
            + AnimationSpec.manualScrollFollowDelay
        setScrollPosition(position)
        browsingIndex = nearestLineIndex(toScrollPosition: position)
        visualScrollIndex = nil
        updateHoveredLine(nil)
        if let activeIndex {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateLineStates(activeIndex: activeIndex, animated: false)
            CATransaction.commit()
        }

        manualScrollEndWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishManualScroll()
        }
        manualScrollEndWorkItem = workItem
        let delay: TimeInterval = event.momentumPhase == .ended ? 0.04 : 0.16
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func finishManualScroll() {
        manualScrollEndWorkItem = nil
        guard isManualScrolling else { return }
        isManualScrolling = false
        let visiblePosition = lyricsLayer.presentation()?.bounds.origin.y
            ?? lyricsLayer.bounds.origin.y
        guard let index = nearestLineIndex(toScrollPosition: visiblePosition) else { return }
        browsingIndex = index
        autoFollowResumeDeadline = CACurrentMediaTime()
            + AnimationSpec.manualScrollFollowDelay
        scroll(to: index, animated: true)
        if let activeIndex {
            updateLineStates(activeIndex: activeIndex, animated: true)
        }
    }

    private func nearestLineIndex(toScrollPosition position: CGFloat) -> Int? {
        guard !lineCenters.isEmpty else { return nil }
        let contentFocus = position + bounds.height * scrollFocusRatio
        return lineCenters.indices.min {
            abs(lineCenters[$0] - contentFocus) < abs(lineCenters[$1] - contentFocus)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard pointerInside, !isLiveResizing else {
            updateHoveredLine(nil)
            return
        }
        updateHoveredLine(lyricLineIndex(at: event, hitSlop: 0.7))
    }

    override func mouseExited(with event: NSEvent) {
        updateHoveredLine(nil)
    }

    override func mouseDown(with event: NSEvent) {
        // Mouse movement has already resolved the row against the exact
        // presentation shown to the user. Prefer that stable result because a
        // spring scroll can advance between mouseMoved and mouseDown.
        let clickedIndex = hoveredLineIndex ?? lyricLineIndex(at: event, hitSlop: 1)
        guard let selectedIndex = clickedIndex,
              selectedIndex < lines.count else {
            pendingLyricClick = nil
            super.mouseDown(with: event)
            return
        }
        updateHoveredLine(selectedIndex)
        pendingLyricClick = PendingLyricClick(
            lineIndex: selectedIndex,
            screenLocation: NSEvent.mouseLocation
        )
    }

    override func mouseDragged(with event: NSEvent) {
        if let pendingLyricClick,
           distance(from: pendingLyricClick.screenLocation, to: NSEvent.mouseLocation)
                > AnimationSpec.clickDragThreshold {
            self.pendingLyricClick = nil
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let pendingLyricClick else {
            super.mouseUp(with: event)
            return
        }
        self.pendingLyricClick = nil
        guard !isWindowMoving,
              !isLiveResizing,
              distance(from: pendingLyricClick.screenLocation, to: NSEvent.mouseLocation)
                <= AnimationSpec.clickDragThreshold else {
            super.mouseUp(with: event)
            return
        }
        seek(toLineAt: pendingLyricClick.lineIndex)
    }

    private func distance(from start: NSPoint, to end: NSPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    private func seek(toLineAt selectedIndex: Int) {
        let target = lines[selectedIndex].time
        DiagnosticLogger.shared.info(
            "Lyric click; index=\(selectedIndex); time=\(target); text=\(lines[selectedIndex].text)"
        )
        let now = CACurrentMediaTime()
        frozenPosition = target
        frozenPositionDeadline = now + AnimationSpec.lineTapProgressFreezeDuration
        basePosition = target
        sampledAt = now
        browsingIndex = nil
        isManualScrolling = false
        autoFollowResumeDeadline = frozenPositionDeadline
        visualScrollIndex = nil
        scroll(to: selectedIndex, animated: true)
        updateLayerPresentation()
        onSeek?(target)
    }

    private func lyricLineIndex(at event: NSEvent, hitSlop: CGFloat) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        let visibleBounds = lyricsLayer.presentation()?.bounds ?? lyricsLayer.bounds
        // The lyric container flips its sublayer geometry. Mirror through the
        // currently presented bounds so hover tracks the rendered row while a
        // spring scroll is in flight.
        let contentY = visibleBounds.maxY - point.y
        let candidates = karaokeLayers.indices.filter { !karaokeLayers[$0].isHidden }
        guard let nearest = candidates.min(by: {
            abs(lineCenters[$0] - contentY) < abs(lineCenters[$1] - contentY)
        }),
        abs(lineCenters[nearest] - contentY)
            <= lineHeights[nearest] * 0.5 + 6 * hitSlop else {
            return nil
        }
        return nearest
    }

    private func updateHoveredLine(_ index: Int?) {
        guard hoveredLineIndex != index else { return }
        if let hoveredLineIndex, hoveredLineIndex < karaokeLayers.count {
            karaokeLayers[hoveredLineIndex].setHovered(false)
        }
        hoveredLineIndex = index
        if let index, index < karaokeLayers.count {
            karaokeLayers[index].setHovered(true)
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func activateTimer() {
        guard isPlaying,
              isWindowVisible,
              !isWindowMoving else { return }
        displayLink.start()
    }

    private func updateTimerState() {
        if isPlaying, isWindowVisible, !isWindowMoving, !lines.isEmpty {
            activateTimer()
        } else {
            stopTimer()
        }
    }

    private func stopTimer() {
        displayLink.stop()
    }
}

private final class DisplayLinkDriver {
    private let onFrame: () -> Void
    private let lock = NSLock()
    private var displayLink: CVDisplayLink?
    private var framePending = false

    init(onFrame: @escaping () -> Void) {
        self.onFrame = onFrame
    }

    deinit {
        stop()
    }

    func start() {
        if displayLink == nil {
            var link: CVDisplayLink?
            guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
                  let link else { return }
            CVDisplayLinkSetOutputCallback(
                link,
                { _, _, _, _, _, context in
                    guard let context else { return kCVReturnError }
                    Unmanaged<DisplayLinkDriver>
                        .fromOpaque(context)
                        .takeUnretainedValue()
                        .scheduleFrame()
                    return kCVReturnSuccess
                },
                Unmanaged.passUnretained(self).toOpaque()
            )
            displayLink = link
        }
        guard let displayLink, !CVDisplayLinkIsRunning(displayLink) else { return }
        CVDisplayLinkStart(displayLink)
    }

    func stop() {
        guard let displayLink, CVDisplayLinkIsRunning(displayLink) else { return }
        CVDisplayLinkStop(displayLink)
        lock.lock()
        framePending = false
        lock.unlock()
    }

    private func scheduleFrame() {
        lock.lock()
        guard !framePending else {
            lock.unlock()
            return
        }
        framePending = true
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.framePending = false
            self.lock.unlock()
            self.onFrame()
        }
    }
}

// MARK: - Retained karaoke layers

private class NoImplicitAnimationLayer: CALayer {
    override init() {
        super.init()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func action(forKey event: String) -> (any CAAction)? {
        nil
    }
}

private final class KaraokeTextLayer: NoImplicitAnimationLayer {
    struct GlyphFragment {
        let glyphRange: NSRange
        let rect: CGRect
    }

    private let storage: NSTextStorage
    private let textLayoutManager: NSLayoutManager
    private let textContainer: NSTextContainer

    let textHeight: CGFloat

    init(text: String, font: NSFont, color: NSColor, width: CGFloat, scale: CGFloat) {
        textLayoutManager = NSLayoutManager()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1
        storage = NSTextStorage(
            string: text.isEmpty ? "·" : text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
        textContainer = NSTextContainer(
            size: NSSize(width: width, height: .greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textLayoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(textLayoutManager)
        textLayoutManager.ensureLayout(for: textContainer)
        textHeight = ceil(max(1, textLayoutManager.usedRect(for: textContainer).height))

        super.init()
        contentsScale = scale
        drawsAsynchronously = false
        bounds = CGRect(x: 0, y: 0, width: width, height: textHeight)
        setNeedsDisplay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override init(layer: Any) {
        guard let source = layer as? KaraokeTextLayer else {
            fatalError("Unexpected layer copy")
        }
        storage = source.storage
        textLayoutManager = source.textLayoutManager
        textContainer = source.textContainer
        textHeight = source.textHeight
        super.init(layer: layer)
    }

    override func draw(in context: CGContext) {
        drawGlyphs(
            in: context,
            glyphRange: textLayoutManager.glyphRange(for: textContainer),
            at: .zero
        )
    }

    func drawGlyphs(in context: CGContext, glyphRange: NSRange, at origin: CGPoint) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        textLayoutManager.drawGlyphs(
            forGlyphRange: glyphRange,
            at: origin
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    func prepareForDisplay() {
        displayIfNeeded()
    }

    func fragments(for characterRange: NSRange) -> [GlyphFragment] {
        let glyphRange = textLayoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        var result: [GlyphFragment] = []
        var glyphIndex = glyphRange.location
        let end = NSMaxRange(glyphRange)

        while glyphIndex < end {
            var lineRange = NSRange()
            _ = textLayoutManager.lineFragmentUsedRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineRange
            )
            let intersection = NSIntersectionRange(lineRange, glyphRange)
            if intersection.length > 0 {
                result.append(
                    GlyphFragment(
                        glyphRange: intersection,
                        rect: textLayoutManager.boundingRect(
                            forGlyphRange: intersection,
                            in: textContainer
                        )
                    )
                )
            }
            let next = NSMaxRange(lineRange)
            if next <= glyphIndex { break }
            glyphIndex = next
        }
        return result
    }
}

private final class KaraokeGlyphFragmentLayer: NoImplicitAnimationLayer {
    private let source: KaraokeTextLayer
    private let glyphRange: NSRange
    private let textRect: CGRect

    init(source: KaraokeTextLayer, fragment: KaraokeTextLayer.GlyphFragment) {
        self.source = source
        glyphRange = fragment.glyphRange
        textRect = fragment.rect
        super.init()
        contentsScale = source.contentsScale
        drawsAsynchronously = false
        frame = fragment.rect
        setNeedsDisplay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override init(layer: Any) {
        guard let sourceLayer = layer as? KaraokeGlyphFragmentLayer else {
            fatalError("Unexpected layer copy")
        }
        source = sourceLayer.source
        glyphRange = sourceLayer.glyphRange
        textRect = sourceLayer.textRect
        super.init(layer: layer)
    }

    override func draw(in context: CGContext) {
        source.drawGlyphs(
            in: context,
            glyphRange: glyphRange,
            at: CGPoint(x: -textRect.minX, y: -textRect.minY)
        )
    }

    func prepareForDisplay() {
        displayIfNeeded()
    }
}

private final class ProgressMaskSegmentLayer: NoImplicitAnimationLayer {
    private let fillLayer: NoImplicitAnimationLayer
    private let gradientLayer: CAGradientLayer
    private let segmentWidth: CGFloat
    private let featherWidth: CGFloat
    private var lastFraction: CGFloat = -1

    init(rect: CGRect, featherWidth: CGFloat) {
        fillLayer = NoImplicitAnimationLayer()
        gradientLayer = CAGradientLayer()
        segmentWidth = rect.width
        self.featherWidth = min(featherWidth, max(1, rect.width))
        super.init()
        frame = rect.insetBy(dx: 0, dy: -2)
        masksToBounds = true
        fillLayer.backgroundColor = NSColor.white.cgColor
        gradientLayer.colors = [NSColor.white.cgColor, NSColor.clear.cgColor]
        gradientLayer.locations = [0, 1]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        addSublayer(fillLayer)
        addSublayer(gradientLayer)
        update(fraction: 0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override init(layer: Any) {
        guard let source = layer as? ProgressMaskSegmentLayer else {
            fatalError("Unexpected layer copy")
        }
        fillLayer = source.fillLayer
        gradientLayer = source.gradientLayer
        segmentWidth = source.segmentWidth
        featherWidth = source.featherWidth
        lastFraction = source.lastFraction
        super.init(layer: layer)
    }

    func update(fraction: Double) {
        let fraction = CGFloat(min(1, max(0, fraction)))
        if (fraction == 0 && lastFraction == 0)
            || (fraction == 1 && lastFraction == 1) {
            return
        }
        lastFraction = fraction
        guard fraction > 0 else {
            isHidden = true
            return
        }
        isHidden = false
        if fraction >= 1 {
            fillLayer.frame = bounds
            gradientLayer.isHidden = true
            return
        }

        let width = segmentWidth * fraction
        fillLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: max(0, width - featherWidth),
            height: bounds.height
        )
        gradientLayer.isHidden = false
        gradientLayer.frame = CGRect(
            x: width - featherWidth,
            y: 0,
            width: featherWidth,
            height: bounds.height
        )
    }
}

private final class TimedGlyphUnitLayer: NoImplicitAnimationLayer {
    private let lift: CGFloat
    private var fragmentLayers: [KaraokeGlyphFragmentLayer] = []
    private var isLifted = false

    init(size: CGSize, lift: CGFloat) {
        self.lift = lift
        super.init()
        bounds = CGRect(origin: .zero, size: size)
        anchorPoint = .zero
        position = .zero
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override init(layer: Any) {
        guard let source = layer as? TimedGlyphUnitLayer else {
            fatalError("Unexpected layer copy")
        }
        lift = source.lift
        fragmentLayers = source.fragmentLayers
        isLifted = source.isLifted
        super.init(layer: layer)
    }

    func addFragment(_ layer: KaraokeGlyphFragmentLayer) {
        fragmentLayers.append(layer)
        addSublayer(layer)
    }

    func prepareForDisplay() {
        fragmentLayers.forEach { $0.prepareForDisplay() }
    }

    func setLifted(_ lifted: Bool, animated: Bool) {
        guard isLifted != lifted else { return }
        isLifted = lifted
        let target = CATransform3DMakeTranslation(0, lifted ? -lift : 0, 0)
        let current = presentation()?.transform ?? transform
        transform = target

        guard animated else {
            removeAnimation(forKey: "syllableLift")
            return
        }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = current
        spring.toValue = target
        spring.mass = 1
        spring.stiffness = 14
        spring.damping = 7
        spring.duration = spring.settlingDuration
        add(spring, forKey: "syllableLift")
    }
}

private final class KaraokeLineLayer: NoImplicitAnimationLayer {
    private struct TimedRange {
        let characterRange: NSRange
        let start: TimeInterval
        let end: TimeInterval
    }

    private struct TimedMask {
        let start: TimeInterval
        let end: TimeInterval
        let layer: ProgressMaskSegmentLayer
    }

    private struct TimedUnit {
        let start: TimeInterval
        let layer: TimedGlyphUnitLayer
    }

    private let upcomingLayer: KaraokeTextLayer
    private let highlightedLayer: KaraokeTextLayer
    private let supplementaryLayer: KaraokeTextLayer?
    private let ranges: [TimedRange]
    private var timedMasks: [TimedMask] = []
    private var timedUnits: [TimedUnit] = []
    private var baseOpacity: Float = 1
    private var isHovered = false

    let textHeight: CGFloat

    init(
        line: LyricLine,
        fallbackEnd: TimeInterval,
        font: NSFont,
        supplementaryText: String?,
        width: CGFloat,
        contentsScale: CGFloat,
        featherWidth: CGFloat
    ) {
        let text = line.words.isEmpty ? line.text : line.words.map(\.text).joined()
        upcomingLayer = KaraokeTextLayer(
            text: text,
            font: font,
            color: NSColor.labelColor.withAlphaComponent(0.30),
            width: width,
            scale: contentsScale
        )
        highlightedLayer = KaraokeTextLayer(
            text: text,
            font: font,
            color: NSColor.labelColor.withAlphaComponent(0.98),
            width: width,
            scale: contentsScale
        )
        if let supplementaryText, !supplementaryText.isEmpty {
            supplementaryLayer = KaraokeTextLayer(
                text: supplementaryText,
                font: NSFont.systemFont(ofSize: max(11, font.pointSize * 0.67), weight: .regular),
                color: NSColor.secondaryLabelColor.withAlphaComponent(0.66),
                width: width,
                scale: contentsScale
            )
        } else {
            supplementaryLayer = nil
        }
        textHeight = upcomingLayer.textHeight
            + (supplementaryLayer.map { 5 + $0.textHeight } ?? 0)

        var location = 0
        var built: [TimedRange] = []
        if line.words.isEmpty {
            let length = (text as NSString).length
            if length > 0 {
                built.append(
                    TimedRange(
                        characterRange: NSRange(location: 0, length: length),
                        start: line.time,
                        end: fallbackEnd
                    )
                )
            }
        } else {
            for word in line.words {
                let length = (word.text as NSString).length
                if length > 0 {
                    built.append(
                        TimedRange(
                            characterRange: NSRange(location: location, length: length),
                            start: word.start,
                            end: word.end
                        )
                    )
                }
                location += length
            }
        }
        ranges = built
        super.init()
        isGeometryFlipped = true
        cornerRadius = 6

        if let supplementaryLayer {
            supplementaryLayer.anchorPoint = .zero
            supplementaryLayer.position = CGPoint(x: 0, y: upcomingLayer.textHeight + 5)
            addSublayer(supplementaryLayer)
        }

        for range in ranges {
            let characterRanges = composedCharacterRanges(
                in: text,
                range: range.characterRange
            )
            let visualRanges = characterRanges.isEmpty
                ? [range.characterRange]
                : characterRanges
            let fragmentPairs = visualRanges.map { characterRange in
                (
                    characterRange,
                    upcomingLayer.fragments(for: characterRange),
                    highlightedLayer.fragments(for: characterRange)
                )
            }
            let totalWidth = fragmentPairs.reduce(CGFloat(0)) { result, pair in
                result + pair.1.reduce(CGFloat(0)) { $0 + $1.rect.width }
            }
            let duration = max(0.01, range.end - range.start)
            var consumedWidth: CGFloat = 0
            for (_, upcomingFragments, highlightedFragments) in fragmentPairs {
                let unitWidth = upcomingFragments.reduce(CGFloat(0)) {
                    $0 + $1.rect.width
                }
                guard unitWidth > 0 else { continue }
                let unitStart = range.start
                    + duration * TimeInterval(consumedWidth / max(1, totalWidth))
                let unitEnd = range.start
                    + duration * TimeInterval(
                        (consumedWidth + unitWidth) / max(1, totalWidth)
                    )
                consumedWidth += unitWidth

                let unit = TimedGlyphUnitLayer(
                    size: CGSize(width: width, height: textHeight),
                    lift: max(1.5, font.pointSize * 0.12)
                )
                var fragmentWidth: CGFloat = 0
                for (upcomingFragment, highlightedFragment) in zip(
                    upcomingFragments,
                    highlightedFragments
                ) where upcomingFragment.rect.width > 0 {
                    let fragmentStart = unitStart
                        + (unitEnd - unitStart)
                            * TimeInterval(fragmentWidth / unitWidth)
                    fragmentWidth += upcomingFragment.rect.width
                    let fragmentEnd = unitStart
                        + (unitEnd - unitStart)
                            * TimeInterval(fragmentWidth / unitWidth)

                    let upcomingSlice = KaraokeGlyphFragmentLayer(
                        source: upcomingLayer,
                        fragment: upcomingFragment
                    )
                    let highlightedSlice = KaraokeGlyphFragmentLayer(
                        source: highlightedLayer,
                        fragment: highlightedFragment
                    )
                    let mask = ProgressMaskSegmentLayer(
                        rect: CGRect(origin: .zero, size: highlightedFragment.rect.size),
                        featherWidth: featherWidth
                    )
                    highlightedSlice.mask = mask
                    unit.addFragment(upcomingSlice)
                    unit.addFragment(highlightedSlice)
                    timedMasks.append(
                        TimedMask(start: fragmentStart, end: fragmentEnd, layer: mask)
                    )
                }
                addSublayer(unit)
                timedUnits.append(TimedUnit(start: unitStart, layer: unit))
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func composedCharacterRanges(in text: String, range: NSRange) -> [NSRange] {
        guard let stringRange = Range(range, in: text) else { return [] }
        var result: [NSRange] = []
        text.enumerateSubstrings(
            in: stringRange,
            options: .byComposedCharacterSequences
        ) { _, substringRange, _, _ in
            result.append(NSRange(substringRange, in: text))
        }
        return result
    }

    override init(layer: Any) {
        guard let source = layer as? KaraokeLineLayer else {
            fatalError("Unexpected layer copy")
        }
        upcomingLayer = source.upcomingLayer
        highlightedLayer = source.highlightedLayer
        supplementaryLayer = source.supplementaryLayer
        ranges = source.ranges
        timedMasks = source.timedMasks
        timedUnits = source.timedUnits
        baseOpacity = source.baseOpacity
        isHovered = source.isHovered
        textHeight = source.textHeight
        super.init(layer: layer)
    }

    override var bounds: CGRect {
        didSet {
            timedUnits.forEach {
                $0.layer.bounds = CGRect(origin: .zero, size: bounds.size)
            }
        }
    }

    func updateProgress(position: TimeInterval, animated: Bool = true) {
        for timedMask in timedMasks {
            let duration = max(0.01, timedMask.end - timedMask.start)
            timedMask.layer.update(
                fraction: (position - timedMask.start) / duration
            )
        }
        for timedUnit in timedUnits {
            timedUnit.layer.setLifted(
                position >= timedUnit.start,
                animated: animated
            )
        }
    }

    func prepareForDisplay() {
        timedUnits.forEach { $0.layer.prepareForDisplay() }
        supplementaryLayer?.prepareForDisplay()
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        animateOpacity(to: effectiveOpacity, duration: hovered ? 0.20 : 0.25)
    }

    private var effectiveOpacity: Float {
        isHovered && !isHidden ? max(baseOpacity, 0.92) : baseOpacity
    }

    private func animateOpacity(to target: Float, duration: CFTimeInterval) {
        let current = presentation()?.opacity ?? opacity
        opacity = target
        removeAnimation(forKey: "lineOpacity")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = current
        animation.toValue = target
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(animation, forKey: "lineOpacity")
    }

    func setVisualState(
        opacity: Float,
        scale: CGFloat,
        hidden: Bool,
        animated: Bool,
        duration: CFTimeInterval
    ) {
        baseOpacity = opacity
        let targetOpacity = isHovered && !hidden ? max(baseOpacity, 0.92) : baseOpacity
        let targetTransform = CATransform3DMakeScale(scale, scale, 1)
        if isHidden == hidden,
           abs(self.opacity - targetOpacity) < 0.001,
           CATransform3DEqualToTransform(transform, targetTransform) {
            return
        }
        isHidden = hidden
        let oldOpacity = presentation()?.opacity ?? self.opacity
        let oldTransform = presentation()?.transform ?? transform
        self.opacity = targetOpacity
        transform = targetTransform
        guard animated else {
            removeAnimation(forKey: "lineOpacity")
            removeAnimation(forKey: "lineScale")
            return
        }

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = oldOpacity
        opacityAnimation.toValue = targetOpacity
        opacityAnimation.duration = duration
        opacityAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(opacityAnimation, forKey: "lineOpacity")

        let scaleAnimation = CABasicAnimation(keyPath: "transform")
        scaleAnimation.fromValue = oldTransform
        scaleAnimation.toValue = transform
        scaleAnimation.duration = duration
        scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(scaleAnimation, forKey: "lineScale")
    }
}
