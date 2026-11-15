import AppKit
import QuartzCore

private enum MenuBarLyricsColorPreference: Int, CaseIterable {
    case active
    case inactive

    var title: String {
        switch self {
        case .active: return "Highlighted Lyrics Color…"
        case .inactive: return "Unhighlighted Lyrics Color…"
        }
    }

    var color: NSColor {
        switch self {
        case .active: return AppPreferences.menuBarLyricsActiveColor
        case .inactive: return AppPreferences.menuBarLyricsInactiveColor
        }
    }

    func save(_ color: NSColor) {
        switch self {
        case .active: AppPreferences.menuBarLyricsActiveColor = color
        case .inactive: AppPreferences.menuBarLyricsInactiveColor = color
        }
    }
}

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let karaokeTitleView = KaraokeStatusTitleView()
    private let playerItem = NSMenuItem()
    private let playerView = MenuPlayerView()
    private let checkForUpdatesItem = NSMenuItem(
        title: "Check for Updates…",
        action: #selector(checkForUpdates),
        keyEquivalent: ""
    )

    private let immersiveItem = NSMenuItem(
        title: "Full Screen Lyrics",
        action: #selector(toggleImmersive),
        keyEquivalent: "f"
    )
    private let floatingItem = NSMenuItem(
        title: "Floating Lyrics",
        action: #selector(toggleFloating),
        keyEquivalent: "l"
    )
    private let lockFloatingItem = NSMenuItem(
        title: "Lock Floating Lyrics",
        action: #selector(toggleFloatingLock),
        keyEquivalent: "k"
    )
    private let clickThroughItem = NSMenuItem(
        title: "Click Through Floating Lyrics",
        action: #selector(toggleFloatingClickThrough),
        keyEquivalent: ""
    )

    private let exportItem = NSMenuItem(title: "Export Lyrics", action: nil, keyEquivalent: "")
    private let exportTranslationItem = NSMenuItem(
        title: "Include Translations",
        action: #selector(toggleExportTranslation),
        keyEquivalent: ""
    )
    private let exportTransliterationItem = NSMenuItem(
        title: "Include Transliterations",
        action: #selector(toggleExportTransliteration),
        keyEquivalent: ""
    )

    private var diagnosticLogWindow: NSWindow?
    private var isCheckingForUpdates = false
    private var exportableLyrics: LyricsDocument?
    private var exportableTrack: TrackInfo?
    private var floatingVisible = false
    private var selectedColorPreference: MenuBarLyricsColorPreference?

    var onRefreshLyrics: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onToggleFloating: (() -> Void)?
    var onToggleImmersive: (() -> Void)?
    var onToggleFloatingLock: (() -> Void)?
    var onToggleFloatingClickThrough: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    var onPreviousTrack: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onNextTrack: (() -> Void)?
    var onOpenMusic: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        immersiveItem.target = self
        immersiveItem.keyEquivalentModifierMask = [.control, .option]
        floatingItem.target = self
        floatingItem.keyEquivalentModifierMask = [.control, .option]
        lockFloatingItem.target = self
        lockFloatingItem.keyEquivalentModifierMask = [.control, .option]
        clickThroughItem.target = self
        checkForUpdatesItem.target = self
        exportTranslationItem.target = self
        exportTransliterationItem.target = self
        playerItem.view = playerView
        playerView.onSeek = { [weak self] position in self?.onSeek?(position) }
        playerView.onPreviousTrack = { [weak self] in self?.onPreviousTrack?() }
        playerView.onTogglePlayPause = { [weak self] in self?.onTogglePlayPause?() }
        playerView.onNextTrack = { [weak self] in self?.onNextTrack?() }
        playerView.onOpenMusic = { [weak self] in self?.onOpenMusic?() }
        configureStatusItem()
        rebuildMenu()
    }

    /// Lightweight update for playback time without rebuilding the lyrics menu.
    func updatePlaybackProgress(track: TrackInfo) {
        playerView.update(track: track)
    }

    /// Repaints the status bar title without rebuilding the menu.
    func updateKaraokeProgress(track: TrackInfo, lyrics: LyricsDocument) {
        updatePlaybackProgress(track: track)
        guard let index = lyrics.lineIndex(at: track.position),
              index < lyrics.lines.count else { return }
        let line: LyricLine
        switch AppPreferences.menuBarLyricsMode {
        case .off:
            setStaticTitle(track.state == .paused ? "⏸" : "♪")
            return
        case .original:
            line = lyrics.lines[index]
        case .english:
            line = Self.englishLine(in: lyrics, at: index)
        }
        if AppPreferences.menuBarLyricsSweep {
            setKaraokeTitle(line: line, track: track)
        } else {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            setStaticTitle(fitted((track.state == .paused ? "⏸ " : "") + (text.isEmpty ? "♪" : text)))
        }
    }

    /// Sets a plain title, touching the status item only when the text
    /// changes, so the menu bar redraws once per lyric line.
    private func setStaticTitle(_ title: String) {
        guard statusItem.button?.title != title || !karaokeTitleView.isHidden else { return }
        setTitle(title)
    }

    /// Shortens text to fit the menu bar width the sweeping title uses.
    private var fittedCache: (input: String, output: String)?

    private func fitted(_ text: String) -> String {
        if let fittedCache, fittedCache.input == text { return fittedCache.output }
        let output = fit(text)
        fittedCache = (text, output)
        return output
    }

    private func fit(_ text: String) -> String {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        var maximumWidth: CGFloat = (screen?.frame.width ?? 1440) <= 1800 ? 180 : 200
        if let rightArea = screen?.auxiliaryTopRightArea, rightArea.width > 0 {
            maximumWidth = min(200, max(160, rightArea.width * 0.25))
        }
        let font = NSFont.menuBarFont(ofSize: 0)
        func width(_ value: String) -> CGFloat { (value as NSString).size(withAttributes: [.font: font]).width }
        guard width(text) > maximumWidth else { return text }
        var characters = Array(text)
        while characters.count > 1, width(String(characters) + "…") > maximumWidth {
            characters.removeLast()
        }
        return String(characters).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The line at `index` with its English translation as the text, timed as
    /// one block from the line's start to the next line, so it still fills in
    /// as the line is sung. Lines without a translation are kept as they are.
    static func englishLine(in lyrics: LyricsDocument, at index: Int) -> LyricLine {
        let line = lyrics.lines[index]
        guard let translation = line.translation?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translation.isEmpty else { return line }
        let start = line.words.first?.start ?? line.time
        var end = line.words.last?.end ?? 0
        if end <= start {
            end = index + 1 < lyrics.lines.count ? lyrics.lines[index + 1].time : start + 4
        }
        return LyricLine(
            time: line.time,
            text: translation,
            words: [LyricWord(text: translation, start: start, end: max(end, start + 0.1))]
        )
    }

    /// The menu bar text for a line in a lyrics document without timing.
    private func menuBarText(for currentLine: String, in lyrics: LyricsDocument) -> String {
        guard AppPreferences.menuBarLyricsMode == .english,
              let translation = lyrics.lines.first(where: { $0.text == currentLine })?.translation,
              !translation.isEmpty else { return currentLine }
        return translation
    }

    func setFloatingVisible(_ visible: Bool) {
        floatingVisible = visible
        floatingItem.state = visible ? .on : .off
    }

    func setFloatingInteraction(locked: Bool, clickThrough: Bool) {
        lockFloatingItem.state = locked ? .on : .off
        clickThroughItem.state = clickThrough ? .on : .off
    }

    func setCheckingForUpdates(_ checking: Bool) {
        checkForUpdatesItem.title = checking ? "Checking for Updates…" : "Check for Updates…"
        checkForUpdatesItem.isEnabled = !checking
        isCheckingForUpdates = checking
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.title = "♪"
            button.toolTip = "Apple Music Lyrics"
            button.font = NSFont.menuBarFont(ofSize: 13)
            button.imagePosition = .imageLeading
            button.wantsLayer = true
            karaokeTitleView.frame = button.bounds
            karaokeTitleView.autoresizingMask = [.width, .height]
            karaokeTitleView.isHidden = true
            button.addSubview(karaokeTitleView)
        }
        statusItem.menu = menu
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        menu.addItem(playerItem)
        menu.addItem(.separator())

        // Full screen
        menu.addItem(Self.sectionHeader("Full Screen"))
        immersiveItem.title = "Show Full-Screen Lyrics"
        menu.addItem(immersiveItem)
        let builtInDisplay = NSMenuItem(
            title: "Open on Mac's Built-in Display",
            action: #selector(toggleImmersiveOnBuiltInDisplay(_:)),
            keyEquivalent: ""
        )
        builtInDisplay.target = self
        builtInDisplay.state = AppPreferences.immersiveOnBuiltInDisplay ? .on : .off
        menu.addItem(builtInDisplay)
        let background = NSMenuItem(title: "Background Brightness", action: nil, keyEquivalent: "")
        let backgroundMenu = NSMenu(title: "Background Brightness")
        for brightness in BackgroundBrightness.allCases {
            let item = NSMenuItem(title: brightness.title, action: #selector(selectBackgroundBrightness(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = brightness.rawValue
            item.state = AppPreferences.backgroundBrightness == brightness ? .on : .off
            backgroundMenu.addItem(item)
        }
        background.submenu = backgroundMenu
        menu.addItem(background)

        // Floating window
        menu.addItem(.separator())
        menu.addItem(Self.sectionHeader("Floating Window"))
        floatingItem.title = "Show Floating Lyrics"
        menu.addItem(floatingItem)
        lockFloatingItem.title = "Lock Position"
        menu.addItem(lockFloatingItem)
        clickThroughItem.title = "Click Through"
        menu.addItem(clickThroughItem)

        // Menu bar
        menu.addItem(.separator())
        menu.addItem(Self.sectionHeader("Menu Bar"))
        let visible = AppPreferences.menuBarLyricsVisible
        let showInMenuBar = NSMenuItem(
            title: "Show Lyrics in Menu Bar",
            action: #selector(toggleMenuBarLyrics(_:)),
            keyEquivalent: ""
        )
        showInMenuBar.target = self
        showInMenuBar.state = visible ? .on : .off
        showInMenuBar.toolTip = "When off, the menu bar shows only the ♪ icon."
        menu.addItem(showInMenuBar)

        let language = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu(title: "Language")
        for mode in [MenuBarLyricsMode.english, .original] {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMenuBarLyricsMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = AppPreferences.menuBarLyricsLanguage == mode ? .on : .off
            languageMenu.addItem(item)
        }
        language.submenu = languageMenu
        language.isHidden = !visible
        menu.addItem(language)

        let sweep = NSMenuItem(title: "Animate Words (Uses More CPU)", action: #selector(toggleMenuBarSweep(_:)), keyEquivalent: "")
        sweep.target = self
        sweep.state = AppPreferences.menuBarLyricsSweep ? .on : .off
        sweep.isHidden = !visible
        menu.addItem(sweep)

        let colors = NSMenuItem(title: "Colors", action: nil, keyEquivalent: "")
        let colorsMenu = NSMenu(title: "Colors")
        for preference in MenuBarLyricsColorPreference.allCases {
            let item = NSMenuItem(
                title: preference.title,
                action: #selector(showLyricsColorPanel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = preference.rawValue
            colorsMenu.addItem(item)
        }
        colorsMenu.addItem(.separator())
        let resetColors = NSMenuItem(
            title: "Reset Colors",
            action: #selector(resetLyricsColors),
            keyEquivalent: ""
        )
        resetColors.target = self
        colorsMenu.addItem(resetColors)
        colors.submenu = colorsMenu
        colors.isHidden = !visible
        menu.addItem(colors)

        // Lyrics
        menu.addItem(.separator())
        let refresh = NSMenuItem(
            title: "Refresh Lyrics",
            action: #selector(refreshLyrics),
            keyEquivalent: "r"
        )
        refresh.target = self
        menu.addItem(refresh)

        exportItem.submenu = makeExportMenu()
        menu.addItem(exportItem)

        menu.addItem(.separator())

        let diagnostic = NSMenuItem(title: "Diagnostic Log", action: nil, keyEquivalent: "")
        let diagnosticMenu = NSMenu(title: "Diagnostic Log")

        let viewLog = NSMenuItem(
            title: "View Log…",
            action: #selector(showDiagnosticLog),
            keyEquivalent: ""
        )
        viewLog.target = self
        diagnosticMenu.addItem(viewLog)

        let copyLog = NSMenuItem(
            title: "Copy Log",
            action: #selector(copyDiagnosticLog),
            keyEquivalent: ""
        )
        copyLog.target = self
        diagnosticMenu.addItem(copyLog)

        let revealLog = NSMenuItem(
            title: "Show in Finder",
            action: #selector(revealDiagnosticLog),
            keyEquivalent: ""
        )
        revealLog.target = self
        diagnosticMenu.addItem(revealLog)

        diagnostic.submenu = diagnosticMenu
        menu.addItem(diagnostic)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Apple Music Lyrics",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    /// A small grey title above a group of menu items.
    private static func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return .sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeExportMenu() -> NSMenu {
        let exportMenu = NSMenu(title: "Export Lyrics")
        for format in LyricsExportFormat.allCases {
            let item = NSMenuItem(
                title: "Export as \(format.title)…",
                action: #selector(exportLyrics(_:)),
                keyEquivalent: format == .lrc ? "e" : ""
            )
            item.target = self
            item.tag = format.rawValue
            exportMenu.addItem(item)
        }
        exportMenu.addItem(.separator())

        let copy = NSMenuItem(
            title: "Copy Lyrics",
            action: #selector(copyLyrics),
            keyEquivalent: ""
        )
        copy.target = self
        exportMenu.addItem(copy)

        exportMenu.addItem(.separator())
        exportTranslationItem.state = AppPreferences.exportIncludeTranslation ? .on : .off
        exportTransliterationItem.state = AppPreferences.exportIncludeTransliteration ? .on : .off
        exportMenu.addItem(exportTranslationItem)
        exportMenu.addItem(exportTransliterationItem)
        return exportMenu
    }

    @objc private func toggleFloatingLock() {
        onToggleFloatingLock?()
    }

    @objc private func toggleFloatingClickThrough() {
        onToggleFloatingClickThrough?()
    }

    // MARK: - Public updates

    private var lastStatus: AppStatus?

    func apply(status: AppStatus) {
        lastStatus = status
        if case .showing(let track, let lyrics, _) = status {
            exportableTrack = track
            exportableLyrics = lyrics
        } else {
            exportableTrack = nil
            exportableLyrics = nil
        }

        switch status {
        case .idle:
            setTitle("♪")
            playerView.update(track: nil, message: "Not Playing")

        case .musicNotRunning:
            setTitle("♪ Music")
            playerView.update(track: nil, message: "Open Music and start playing")

        case .stopped:
            setTitle("♪ Stopped")
            playerView.update(track: nil, message: "Playback stopped")

        case .loadingLyrics(let track):
            setTitle(truncate("… \(track.title)"))
            playerView.update(track: track)

        case .showing(let track, let lyrics, let currentLine):
            playerView.update(track: track, artworkURL: lyrics.artworkURL)
            if AppPreferences.menuBarLyricsMode == .off {
                setTitle(track.state == .paused ? "⏸" : "♪")
            } else if lyrics.isSynced, lyrics.lineIndex(at: track.position) != nil {
                updateKaraokeProgress(track: track, lyrics: lyrics)
            } else {
                let prefix = track.state == .paused ? "⏸ " : ""
                let display = currentLine.isEmpty ? track.displayName : menuBarText(for: currentLine, in: lyrics)
                setTitle(truncate(prefix + display))
            }

        case .noLyrics(let track):
            let prefix = track.state == .paused ? "⏸ " : "♪ "
            setTitle(truncate(prefix + track.displayName))
            playerView.update(track: track)

        case .error(let message):
            setTitle("♪ Error")
            playerView.update(track: nil, message: message)
        }
    }

    // MARK: - Helpers

    private func setTitle(_ title: String) {
        karaokeTitleView.deactivate()
        karaokeTitleView.isHidden = true
        statusItem.length = NSStatusItem.variableLength
        statusItem.button?.title = title
    }

    private func setKaraokeTitle(line: LyricLine, track: TrackInfo) {
        guard let button = statusItem.button else { return }

        let displayText = karaokeTitleView.update(line: line, track: track, limit: 120)
        let screen = button.window?.screen ?? NSScreen.main
        let screenWidth = screen?.frame.width ?? 1440
        let maximumWidth: CGFloat
        if let rightArea = screen?.auxiliaryTopRightArea, rightArea.width > 0 {
            // On notched MacBooks, status items share only the area to the
            // right of the camera housing. Keep lyrics to a small fraction of it.
            maximumWidth = min(200, max(160, rightArea.width * 0.25))
        } else if screenWidth <= 1800 {
            maximumWidth = 180
        } else {
            maximumWidth = 200
        }
        // Keep the width stable between lines without reserving excessive
        // menu bar space for short lyrics. Longer lines scroll within the view.
        statusItem.length = maximumWidth
        if button.attributedTitle.string != displayText {
            button.attributedTitle = NSAttributedString(
                string: displayText,
                attributes: [
                    .font: NSFont.menuBarFont(ofSize: 13),
                    .foregroundColor: NSColor.clear
                ]
            )
        }
        karaokeTitleView.isHidden = false
        karaokeTitleView.needsDisplay = true
    }

    private func truncate(_ text: String, limit: Int = 48) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: limit - 1)
        return String(trimmed[..<end]) + "…"
    }

    // MARK: - Actions

    @objc private func refreshLyrics() {
        onRefreshLyrics?()
    }

    @objc private func showLyricsColorPanel(_ sender: NSMenuItem) {
        guard let preference = MenuBarLyricsColorPreference(rawValue: sender.tag) else { return }
        selectedColorPreference = preference
        let colorPanel = NSColorPanel.shared
        colorPanel.showsAlpha = true
        colorPanel.isContinuous = true
        colorPanel.color = preference.color
        colorPanel.setTarget(self)
        colorPanel.setAction(#selector(changeLyricsColor(_:)))
        NSApp.activate(ignoringOtherApps: true)
        colorPanel.makeKeyAndOrderFront(nil)
    }

    @objc private func changeLyricsColor(_ sender: NSColorPanel) {
        guard let selectedColorPreference else { return }
        selectedColorPreference.save(sender.color)
        karaokeTitleView.reloadColors()
    }

    @objc private func resetLyricsColors() {
        AppPreferences.resetMenuBarLyricsColors()
        karaokeTitleView.reloadColors()
        if let selectedColorPreference {
            NSColorPanel.shared.color = selectedColorPreference.color
        }
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    // MARK: - Lyrics export

    @objc private func exportLyrics(_ sender: NSMenuItem) {
        guard let format = LyricsExportFormat(rawValue: sender.tag),
              let lyrics = exportableLyrics,
              format.isAvailable(for: lyrics) else { return }
        let track = exportableTrack
        let text = LyricsExporter.export(
            lyrics,
            track: track,
            format: format,
            options: AppPreferences.lyricsExportOptions
        )

        let panel = NSSavePanel()
        panel.title = "Export Lyrics"
        panel.nameFieldStringValue = LyricsExporter.suggestedFilename(track: track, format: format)
        panel.allowedContentTypes = [format.contentType]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                DiagnosticLogger.shared.info("Lyrics exported as \(format.fileExtension): \(url.path)")
            } catch {
                DiagnosticLogger.shared.warning("Lyrics export failed: \(error.localizedDescription)")
                let alert = NSAlert(error: error)
                alert.messageText = "Couldn’t Export Lyrics"
                alert.runModal()
            }
        }
    }

    @objc private func copyLyrics() {
        guard let lyrics = exportableLyrics,
              LyricsExportFormat.plainText.isAvailable(for: lyrics) else { return }
        let text = LyricsExporter.export(
            lyrics,
            track: exportableTrack,
            format: .plainText,
            options: AppPreferences.lyricsExportOptions
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        DiagnosticLogger.shared.info("Lyrics copied to pasteboard")
    }

    @objc private func toggleImmersiveOnBuiltInDisplay(_ sender: NSMenuItem) {
        AppPreferences.immersiveOnBuiltInDisplay.toggle()
        sender.state = AppPreferences.immersiveOnBuiltInDisplay ? .on : .off
    }

    @objc private func toggleMenuBarSweep(_ sender: NSMenuItem) {
        AppPreferences.menuBarLyricsSweep.toggle()
        sender.state = AppPreferences.menuBarLyricsSweep ? .on : .off
        if let lastStatus { apply(status: lastStatus) }
    }

    @objc private func selectBackgroundBrightness(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let brightness = BackgroundBrightness(rawValue: raw) else { return }
        AppPreferences.backgroundBrightness = brightness
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? String) == raw ? .on : .off }
    }

    @objc private func toggleMenuBarLyrics(_ sender: NSMenuItem) {
        AppPreferences.menuBarLyricsVisible.toggle()
        // Show or hide the options that only apply while lyrics are shown.
        rebuildMenu()
        if let lastStatus { apply(status: lastStatus) }
    }

    @objc private func selectMenuBarLyricsMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = MenuBarLyricsMode(rawValue: raw) else { return }
        AppPreferences.menuBarLyricsLanguage = mode
        sender.menu?.items.filter { $0.representedObject is String }
            .forEach { $0.state = ($0.representedObject as? String) == raw ? .on : .off }
        if let lastStatus { apply(status: lastStatus) }
    }

    @objc private func toggleExportTranslation() {
        AppPreferences.exportIncludeTranslation.toggle()
        exportTranslationItem.state = AppPreferences.exportIncludeTranslation ? .on : .off
    }

    @objc private func toggleExportTransliteration() {
        AppPreferences.exportIncludeTransliteration.toggle()
        exportTransliterationItem.state = AppPreferences.exportIncludeTransliteration ? .on : .off
    }

    @objc private func toggleFloating() {
        onToggleFloating?()
    }

    @objc private func toggleImmersive() {
        onToggleImmersive?()
    }

    @objc private func quit() {
        onQuit?()
    }

    @objc private func showDiagnosticLog() {
        let text = DiagnosticLogger.shared.contents()
        if diagnosticLogWindow == nil {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 680, height: 520))
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder

            let textView = NSTextView(frame: scroll.bounds)
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.textContainerInset = NSSize(width: 10, height: 10)
            textView.string = text
            textView.autoresizingMask = [.width, .height]
            scroll.documentView = textView
            textView.scrollToEndOfDocument(nil)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Apple Music Lyrics Diagnostic Log"
            window.contentView = scroll
            window.center()
            window.isReleasedWhenClosed = false
            diagnosticLogWindow = window
        } else if let scroll = diagnosticLogWindow?.contentView as? NSScrollView,
                  let textView = scroll.documentView as? NSTextView {
            textView.string = text
            textView.scrollToEndOfDocument(nil)
        }

        diagnosticLogWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func copyDiagnosticLog() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(DiagnosticLogger.shared.contents(), forType: .string)
        DiagnosticLogger.shared.info("Diagnostic log copied to pasteboard")
    }

    @objc private func revealDiagnosticLog() {
        DiagnosticLogger.shared.prepareFile()
        NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLogger.shared.logFileURL])
    }

}

extension MenuBarController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(exportLyrics(_:)):
            guard let lyrics = exportableLyrics,
                  let format = LyricsExportFormat(rawValue: menuItem.tag) else { return false }
            return format.isAvailable(for: lyrics)
        case #selector(copyLyrics):
            guard let lyrics = exportableLyrics else { return false }
            return LyricsExportFormat.plainText.isAvailable(for: lyrics)
        case #selector(checkForUpdates):
            return !isCheckingForUpdates
        default:
            return true
        }
    }
}

// MARK: - Menu player

private final class CompactSliderCell: NSSliderCell {
    override var knobThickness: CGFloat { 10 }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 1.5, width: rect.width, height: 3)
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()

        let range = maxValue - minValue
        let fraction = range > 0 ? CGFloat((doubleValue - minValue) / range) : 0
        guard fraction > 0 else { return }
        var filled = track
        filled.size.width = max(track.height, track.width * min(1, max(0, fraction)))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let diameter: CGFloat = 10
        let compactRect = NSRect(
            x: knobRect.midX - diameter / 2,
            y: knobRect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: compactRect).fill()
    }
}

private final class MenuPlayerView: NSView {
    private let artworkView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Apple Music Lyrics")
    private let subtitleLabel = NSTextField(labelWithString: "Not Playing")
    private let previousButton = NSButton()
    private let playPauseButton = NSButton()
    private let nextButton = NSButton()
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "-0:00")

    private var displayedTrackKey: String?
    private var displayedArtworkURL: URL?
    private var artworkTask: URLSessionDataTask?

    var onSeek: ((TimeInterval) -> Void)?
    var onPreviousTrack: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onNextTrack: (() -> Void)?
    var onOpenMusic: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: 410, height: 126)
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 410, height: 126))
        configure()
        update(track: nil, message: "Not Playing")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for view in [artworkView, titleLabel, subtitleLabel] {
            addCursorRect(convert(view.bounds, from: view), cursor: .pointingHand)
        }
    }

    deinit {
        artworkTask?.cancel()
    }

    private func configure() {
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 8
        artworkView.layer?.masksToBounds = true
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        setArtworkPlaceholder()

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        for view in [artworkView, titleLabel, subtitleLabel] {
            view.addGestureRecognizer(
                NSClickGestureRecognizer(target: self, action: #selector(openMusic))
            )
            view.toolTip = "Open Apple Music"
            view.setAccessibilityRole(.button)
            view.setAccessibilityLabel("Open Apple Music")
        }

        configureButton(
            previousButton,
            symbol: "backward.fill",
            toolTip: "Previous",
            action: #selector(previousTrack),
            pointSize: 16
        )
        configureButton(
            playPauseButton,
            symbol: "play.fill",
            toolTip: "Play",
            action: #selector(togglePlayPause),
            pointSize: 19
        )
        configureButton(
            nextButton,
            symbol: "forward.fill",
            toolTip: "Next",
            action: #selector(nextTrack),
            pointSize: 16
        )

        let controls = NSStackView(views: [previousButton, playPauseButton, nextButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.distribution = .equalSpacing
        controls.spacing = 16
        controls.translatesAutoresizingMaskIntoConstraints = false

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.cell = CompactSliderCell()
        slider.minValue = 0
        slider.maxValue = 1
        slider.sliderType = .linear
        slider.controlSize = .small
        slider.isContinuous = false
        slider.target = self
        slider.action = #selector(seek(_:))
        slider.toolTip = "Playback Position"

        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        remainingLabel.alignment = .right

        addSubview(artworkView)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        addSubview(controls)
        addSubview(slider)
        addSubview(elapsedLabel)
        addSubview(remainingLabel)

        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            artworkView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            artworkView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            artworkView.widthAnchor.constraint(equalTo: artworkView.heightAnchor),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            controls.centerXAnchor.constraint(equalTo: slider.centerXAnchor),
            controls.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 1),
            controls.heightAnchor.constraint(equalToConstant: 30),

            slider.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),

            elapsedLabel.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            elapsedLabel.topAnchor.constraint(equalTo: slider.bottomAnchor),
            remainingLabel.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            remainingLabel.topAnchor.constraint(equalTo: slider.bottomAnchor)
        ])
    }

    private func configureButton(
        _ button: NSButton,
        symbol: String,
        toolTip: String,
        action: Selector,
        pointSize: CGFloat = 18
    ) {
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: toolTip
        )?.withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.contentTintColor = NSColor.labelColor.withAlphaComponent(0.84)
        button.toolTip = toolTip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: button === playPauseButton ? 40 : 34),
            button.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    func update(track: TrackInfo?, artworkURL: URL? = nil, message: String? = nil) {
        guard let track else {
            displayedTrackKey = nil
            displayedArtworkURL = nil
            artworkTask?.cancel()
            artworkTask = nil
            titleLabel.stringValue = "Apple Music Lyrics"
            subtitleLabel.stringValue = message ?? "Not Playing"
            setArtworkPlaceholder()
            for button in [previousButton, playPauseButton, nextButton] {
                button.isEnabled = false
            }
            slider.isEnabled = false
            slider.doubleValue = 0
            elapsedLabel.stringValue = "0:00"
            remainingLabel.stringValue = "-0:00"
            return
        }

        let trackChanged = displayedTrackKey != track.identityKey
        displayedTrackKey = track.identityKey
        titleLabel.stringValue = track.title
        if track.artist.isEmpty {
            subtitleLabel.stringValue = track.album
        } else if track.album.isEmpty {
            subtitleLabel.stringValue = track.artist
        } else {
            subtitleLabel.stringValue = "\(track.artist) · \(track.album)"
        }

        for button in [previousButton, playPauseButton, nextButton] {
            button.isEnabled = true
        }
        let isPlaying = track.state == .playing
        let playPauseToolTip = isPlaying ? "Pause" : "Play"
        playPauseButton.image = NSImage(
            systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: playPauseToolTip
        )?.withSymbolConfiguration(.init(pointSize: 19, weight: .semibold))
        playPauseButton.toolTip = playPauseToolTip

        let duration = max(0, track.duration)
        let position = min(duration, max(0, track.position))
        slider.isEnabled = duration > 0
        slider.maxValue = max(1, duration)
        slider.doubleValue = position
        elapsedLabel.stringValue = formatTime(position)
        remainingLabel.stringValue = "-" + formatTime(max(0, duration - position))

        if trackChanged {
            displayedArtworkURL = nil
            artworkTask?.cancel()
            artworkTask = nil
            setArtworkPlaceholder()
        }
        if let artworkURL, displayedArtworkURL != artworkURL {
            loadArtwork(from: artworkURL)
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func setArtworkPlaceholder() {
        artworkView.image = NSImage(
            systemSymbolName: "music.note",
            accessibilityDescription: "Album Artwork"
        )?.withSymbolConfiguration(.init(pointSize: 26, weight: .medium))
        artworkView.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.62)
        artworkView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
    }

    private func loadArtwork(from url: URL) {
        displayedArtworkURL = url
        artworkTask?.cancel()
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 10
        artworkTask = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard self?.displayedArtworkURL == url else { return }
                self?.artworkView.image = image
                self?.artworkView.contentTintColor = nil
                self?.artworkView.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
        artworkTask?.resume()
    }

    @objc private func previousTrack(_ sender: Any?) {
        onPreviousTrack?()
    }

    @objc private func openMusic(_ sender: Any?) {
        onOpenMusic?()
    }

    @objc private func togglePlayPause(_ sender: Any?) {
        onTogglePlayPause?()
    }

    @objc private func nextTrack(_ sender: Any?) {
        onNextTrack?()
    }

    @objc private func seek(_ sender: NSSlider) {
        onSeek?(sender.doubleValue)
    }
}

// MARK: - Smooth menu bar karaoke

private final class KaraokeStatusTitleView: NSView {
    private struct TimedGlyph {
        let start: TimeInterval
        let end: TimeInterval
        let offset: CGFloat
        let width: CGFloat
    }

    private struct Segment {
        let range: NSRange
        let start: TimeInterval
        let end: TimeInterval
        let offset: CGFloat
        let width: CGFloat
        let glyphs: [TimedGlyph]
    }

    private struct PreviousLine {
        let text: String
        let segments: [Segment]
        let prefixLength: Int
        let prefixWidth: CGFloat
        let originX: CGFloat
        let startedAt: CFTimeInterval
    }

    private static let lineTransitionDuration: CFTimeInterval = 0.33
    private let font = NSFont.menuBarFont(ofSize: 13)
    private var displayText = ""
    private var segments: [Segment] = []
    private var prefixLength = 0
    private var basePosition: TimeInterval = 0
    private var sampledAt: CFTimeInterval = 0
    private var isPlaying = false
    private var displayTimer: Timer?
    private var currentLineID: String?
    private var renderedOriginX: CGFloat?
    private var lastDrawTime: CFTimeInterval = 0
    private var prefixWidth: CGFloat = 0
    private var previousLine: PreviousLine?
    private var activeColor = AppPreferences.menuBarLyricsActiveColor
    private var inactiveColor = AppPreferences.menuBarLyricsInactiveColor

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        displayTimer?.invalidate()
    }

    func update(line: LyricLine, track: TrackInfo, limit: Int) -> String {
        let now = CACurrentMediaTime()
        let estimated = interpolatedPosition(at: now)
        if currentLineID != line.id {
            if currentLineID != nil,
               !displayText.isEmpty,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let textWidth = measuredWidth(of: displayText)
                previousLine = PreviousLine(
                    text: displayText,
                    segments: segments,
                    prefixLength: prefixLength,
                    prefixWidth: prefixWidth,
                    originX: renderedOriginX ?? horizontalOrigin(
                        textWidth: textWidth,
                        position: estimated,
                        segments: segments,
                        prefixWidth: prefixWidth
                    ),
                    startedAt: now
                )
            } else {
                previousLine = nil
            }
            currentLineID = line.id
            renderedOriginX = nil
            lastDrawTime = now
        }
        let error = track.position - estimated
        if isPlaying, abs(error) < 0.75 {
            // Small sample corrections should not become visible motion.
            basePosition = estimated + error * 0.06
        } else {
            basePosition = track.position
        }
        sampledAt = now
        isPlaying = track.state == .playing

        rebuildDisplay(line: line, paused: track.state == .paused, limit: limit)
        if isPlaying || previousLine != nil {
            activateTimer()
        } else {
            stopTimer()
        }
        needsDisplay = true
        return displayText
    }

    func deactivate() {
        stopTimer()
        displayText = ""
        segments = []
        currentLineID = nil
        renderedOriginX = nil
        previousLine = nil
    }

    func reloadColors() {
        activeColor = AppPreferences.menuBarLyricsActiveColor
        inactiveColor = AppPreferences.menuBarLyricsInactiveColor
        attributedCache.removeAll()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !displayText.isEmpty else { return }

        let textSize = NSSize(
            width: measuredWidth(of: displayText),
            height: measuredHeight(of: displayText)
        )
        let now = CACurrentMediaTime()
        let position = interpolatedPosition(at: now)
        let targetOriginX = horizontalOrigin(
            textWidth: textSize.width,
            position: position,
            segments: segments,
            prefixWidth: prefixWidth
        )
        let origin = NSPoint(
            x: smoothedOrigin(target: targetOriginX, at: now),
            y: floor((bounds.height - textSize.height) / 2)
        )

        if let previousLine {
            let elapsed = now - previousLine.startedAt
            let linearProgress = min(1, max(0, elapsed / Self.lineTransitionDuration))
            let progress = linearProgress * linearProgress * (3 - 2 * linearProgress)
            drawLine(
                text: previousLine.text,
                segments: previousLine.segments,
                prefixLength: previousLine.prefixLength,
                prefixWidth: previousLine.prefixWidth,
                position: position,
                origin: NSPoint(
                    x: previousLine.originX,
                    y: floor((bounds.height - measuredHeight(of: previousLine.text)) / 2)
                ),
                alpha: 1 - progress
            )
            drawLine(
                text: displayText,
                segments: segments,
                prefixLength: prefixLength,
                prefixWidth: prefixWidth,
                position: position,
                origin: origin,
                alpha: progress
            )
            if linearProgress >= 1 {
                self.previousLine = nil
                if !isPlaying {
                    stopTimer()
                }
            }
        } else {
            drawLine(
                text: displayText,
                segments: segments,
                prefixLength: prefixLength,
                prefixWidth: prefixWidth,
                position: position,
                origin: origin,
                alpha: 1
            )
        }
        lastDrawnSungWidth = Self.sungWidth(
            segments: segments, prefixLength: prefixLength, prefixWidth: prefixWidth, position: position
        )
        lastDrawnOriginX = origin.x
    }

    private func drawLine(
        text: String,
        segments: [Segment],
        prefixLength: Int,
        prefixWidth: CGFloat,
        position: TimeInterval,
        origin: NSPoint,
        alpha: CGFloat
    ) {
        guard alpha > 0 else { return }
        let strings = attributedStrings(for: text)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        // Sung text always runs left to right, so the whole highlight is one
        // clip rectangle: two string draws per frame instead of two per letter.
        strings.upcoming.draw(at: origin)
        let sung = Self.sungWidth(
            segments: segments,
            prefixLength: prefixLength,
            prefixWidth: prefixWidth,
            position: position
        )
        if sung > 0 {
            NSBezierPath(rect: NSRect(x: origin.x, y: origin.y, width: sung, height: bounds.height)).addClip()
            strings.sung.draw(at: origin)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Width of the already-sung part of a line at `position`.
    private static func sungWidth(
        segments: [Segment],
        prefixLength: Int,
        prefixWidth: CGFloat,
        position: TimeInterval
    ) -> CGFloat {
        var width: CGFloat = prefixLength > 0 ? prefixWidth : 0
        for segment in segments {
            guard position > segment.start else { break }
            if segment.glyphs.isEmpty {
                let fraction = min(1, (position - segment.start) / max(0.01, segment.end - segment.start))
                width = max(width, segment.offset + segment.width * CGFloat(fraction))
                continue
            }
            for glyph in segment.glyphs {
                guard position > glyph.start else { break }
                let fraction = min(1, (position - glyph.start) / max(0.01, glyph.end - glyph.start))
                width = max(width, glyph.offset + glyph.width * CGFloat(fraction))
            }
        }
        return width
    }

    private var attributedCache: [String: (upcoming: NSAttributedString, sung: NSAttributedString)] = [:]

    private func attributedStrings(for text: String) -> (upcoming: NSAttributedString, sung: NSAttributedString) {
        if let cached = attributedCache[text] { return cached }
        if attributedCache.count > 4 { attributedCache.removeAll(keepingCapacity: true) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let make = { (color: NSColor) in
            NSAttributedString(string: text, attributes: [.font: self.font, .foregroundColor: color, .paragraphStyle: paragraph])
        }
        let value = (upcoming: make(inactiveColor), sung: make(activeColor))
        attributedCache[text] = value
        return value
    }

    /// What the last frame showed; the display timer skips frames that would
    /// look identical (between words, after the line is fully sung).
    private var lastDrawnSungWidth: CGFloat = -1
    private var lastDrawnOriginX: CGFloat = .nan

    private func frameWouldChange() -> Bool {
        guard previousLine == nil, !displayText.isEmpty else { return true }
        let position = interpolatedPosition(at: CACurrentMediaTime())
        let sung = Self.sungWidth(segments: segments, prefixLength: prefixLength, prefixWidth: prefixWidth, position: position)
        if abs(sung - lastDrawnSungWidth) >= 0.25 { return true }
        let target = horizontalOrigin(
            textWidth: measuredWidth(of: displayText),
            position: position,
            segments: segments,
            prefixWidth: prefixWidth
        )
        guard let rendered = renderedOriginX, !lastDrawnOriginX.isNaN else { return true }
        return abs(target - rendered) >= 0.25 || abs(rendered - lastDrawnOriginX) >= 0.25
    }

    private func horizontalOrigin(
        textWidth: CGFloat,
        position: TimeInterval,
        segments: [Segment],
        prefixWidth: CGFloat
    ) -> CGFloat {
        let padding: CGFloat = 7
        guard textWidth > bounds.width - padding * 2 else {
            return floor((bounds.width - textWidth) / 2)
        }

        var cursor = prefixWidth
        for segment in segments {
            if position < segment.start {
                cursor = segment.offset
                break
            }
            if position < segment.end {
                let fraction = (position - segment.start) / max(0.01, segment.end - segment.start)
                cursor = segment.offset + segment.width * fraction
                break
            }
            cursor = segment.offset + segment.width
        }

        let desired = bounds.width * 0.56 - cursor
        let minimum = bounds.width - padding - textWidth
        return floor(min(padding, max(minimum, desired)))
    }

    private func measuredWidth(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func measuredHeight(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).height
    }

    private func smoothedOrigin(target: CGFloat, at now: CFTimeInterval) -> CGFloat {
        guard let renderedOriginX else {
            self.renderedOriginX = target
            lastDrawTime = now
            return target
        }
        let elapsed = min(0.05, max(1.0 / 240.0, now - lastDrawTime))
        let blend = 1 - exp(-elapsed / 0.09)
        let next = renderedOriginX + (target - renderedOriginX) * blend
        self.renderedOriginX = next
        lastDrawTime = now
        return next
    }

    private func rebuildDisplay(line: LyricLine, paused: Bool, limit: Int) {
        let prefix = paused ? "⏸ " : ""
        let result = NSMutableString(string: prefix)
        var rebuilt: [Segment] = []
        var remaining = max(1, limit - prefix.count)
        var truncated = false

        for word in line.words {
            guard remaining > 0 else {
                truncated = true
                break
            }
            let characters = Array(word.text)
            let take = min(remaining, characters.count)
            let text = String(characters.prefix(take))
            let location = result.length
            result.append(text)
            let consumedFraction = characters.isEmpty ? 1 : Double(take) / Double(characters.count)
            rebuilt.append(
                Segment(
                    range: NSRange(location: location, length: (text as NSString).length),
                    start: word.start,
                    end: word.start + (word.end - word.start) * consumedFraction,
                    offset: 0,
                    width: 0,
                    glyphs: []
                )
            )
            remaining -= take
            if take < characters.count {
                truncated = true
                break
            }
        }

        if line.words.isEmpty {
            let characters = Array(line.text)
            let take = min(remaining, characters.count)
            result.append(String(characters.prefix(take)))
            truncated = take < characters.count
        }
        if truncated, result.length > 0 {
            let lastRange = result.rangeOfComposedCharacterSequence(at: result.length - 1)
            result.replaceCharacters(in: lastRange, with: "…")
            rebuilt = rebuilt.compactMap { segment in
                guard NSMaxRange(segment.range) <= result.length else { return nil }
                return segment
            }
        }

        displayText = result as String
        let metrics = NSAttributedString(
            string: displayText,
            attributes: [.font: font]
        )
        segments = rebuilt.map { segment in
            let prefixRange = NSRange(location: 0, length: segment.range.location)
            let offset = metrics.attributedSubstring(from: prefixRange).size().width
            let width = metrics.attributedSubstring(from: segment.range).size().width
            return Segment(
                range: segment.range,
                start: segment.start,
                end: segment.end,
                offset: offset,
                width: width,
                glyphs: timedGlyphs(
                    in: segment.range,
                    metrics: metrics,
                    start: segment.start,
                    end: segment.end,
                    totalWidth: width
                )
            )
        }
        prefixLength = (prefix as NSString).length
        prefixWidth = prefixLength > 0
            ? metrics.attributedSubstring(
                from: NSRange(location: 0, length: prefixLength)
            ).size().width
            : 0
    }

    private func timedGlyphs(
        in range: NSRange,
        metrics: NSAttributedString,
        start: TimeInterval,
        end: TimeInterval,
        totalWidth: CGFloat
    ) -> [TimedGlyph] {
        guard totalWidth > 0,
              let stringRange = Range(range, in: displayText) else { return [] }

        var ranges: [NSRange] = []
        displayText.enumerateSubstrings(
            in: stringRange,
            options: .byComposedCharacterSequences
        ) { _, substringRange, _, _ in
            ranges.append(NSRange(substringRange, in: self.displayText))
        }

        let duration = max(0.01, end - start)
        var consumedWidth: CGFloat = 0
        return ranges.compactMap { glyphRange in
            let width = metrics.attributedSubstring(from: glyphRange).size().width
            guard width > 0 else { return nil }
            let prefixRange = NSRange(location: 0, length: glyphRange.location)
            let offset = metrics.attributedSubstring(from: prefixRange).size().width
            let glyphStart = start + duration * TimeInterval(consumedWidth / totalWidth)
            consumedWidth += width
            let glyphEnd = start + duration * TimeInterval(consumedWidth / totalWidth)
            return TimedGlyph(
                start: glyphStart,
                end: glyphEnd,
                offset: offset,
                width: width
            )
        }
    }

    private func activateTimer() {
        guard displayTimer == nil, isPlaying || previousLine != nil else { return }
        // 30 fps is smooth for a sweep this small, and every menu bar redraw
        // also makes macOS re-snapshot the item for each display.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, self.frameWouldChange() else { return }
            self.needsDisplay = true
        }
        timer.tolerance = 0.008
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func interpolatedPosition(at now: CFTimeInterval) -> TimeInterval {
        basePosition + (isPlaying ? max(0, now - sampledAt) : 0)
    }
}
