import AppKit
import QuartzCore

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let karaokeTitleView = KaraokeStatusTitleView()
    private let playerItem = NSMenuItem()
    private let playerView = MenuPlayerView()

    private let floatingItem = NSMenuItem(
        title: "浮动歌词",
        action: #selector(toggleFloating),
        keyEquivalent: "l"
    )
    private let lockFloatingItem = NSMenuItem(
        title: "锁定浮动歌词",
        action: #selector(toggleFloatingLock),
        keyEquivalent: "k"
    )
    private let clickThroughItem = NSMenuItem(
        title: "鼠标穿透浮动歌词",
        action: #selector(toggleFloatingClickThrough),
        keyEquivalent: ""
    )

    private var diagnosticLogWindow: NSWindow?
    private var floatingVisible = false
    private var karaokeLineID: String?
    private var karaokeLineIndex: Int?

    var onRefreshLyrics: (() -> Void)?
    var onToggleFloating: (() -> Void)?
    var onToggleFloatingLock: (() -> Void)?
    var onToggleFloatingClickThrough: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    var onPreviousTrack: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onNextTrack: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        floatingItem.target = self
        floatingItem.keyEquivalentModifierMask = [.control, .option]
        lockFloatingItem.target = self
        lockFloatingItem.keyEquivalentModifierMask = [.control, .option]
        clickThroughItem.target = self
        playerItem.view = playerView
        playerView.onSeek = { [weak self] position in self?.onSeek?(position) }
        playerView.onPreviousTrack = { [weak self] in self?.onPreviousTrack?() }
        playerView.onTogglePlayPause = { [weak self] in self?.onTogglePlayPause?() }
        playerView.onNextTrack = { [weak self] in self?.onNextTrack?() }
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
        setKaraokeTitle(line: lyrics.lines[index], index: index, track: track)
    }

    func setFloatingVisible(_ visible: Bool) {
        floatingVisible = visible
        floatingItem.state = visible ? .on : .off
    }

    func setFloatingInteraction(locked: Bool, clickThrough: Bool) {
        lockFloatingItem.state = locked ? .on : .off
        clickThroughItem.state = clickThrough ? .on : .off
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

        menu.addItem(floatingItem)
        menu.addItem(lockFloatingItem)
        menu.addItem(clickThroughItem)

        let refresh = NSMenuItem(
            title: "刷新歌词",
            action: #selector(refreshLyrics),
            keyEquivalent: "r"
        )
        refresh.target = self
        menu.addItem(refresh)

        let diagnostic = NSMenuItem(title: "诊断日志", action: nil, keyEquivalent: "")
        let diagnosticMenu = NSMenu(title: "诊断日志")

        let viewLog = NSMenuItem(
            title: "查看日志…",
            action: #selector(showDiagnosticLog),
            keyEquivalent: ""
        )
        viewLog.target = self
        diagnosticMenu.addItem(viewLog)

        let copyLog = NSMenuItem(
            title: "复制日志",
            action: #selector(copyDiagnosticLog),
            keyEquivalent: ""
        )
        copyLog.target = self
        diagnosticMenu.addItem(copyLog)

        let revealLog = NSMenuItem(
            title: "在访达中显示",
            action: #selector(revealDiagnosticLog),
            keyEquivalent: ""
        )
        revealLog.target = self
        diagnosticMenu.addItem(revealLog)

        diagnostic.submenu = diagnosticMenu
        menu.addItem(diagnostic)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出 Apple Music Lyrics",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleFloatingLock() {
        onToggleFloatingLock?()
    }

    @objc private func toggleFloatingClickThrough() {
        onToggleFloatingClickThrough?()
    }

    // MARK: - Public updates

    func apply(status: AppStatus) {
        switch status {
        case .idle:
            setTitle("♪")
            playerView.update(track: nil, message: "未播放歌曲")

        case .musicNotRunning:
            setTitle("♪ Music")
            playerView.update(track: nil, message: "打开“音乐”并开始播放")

        case .stopped:
            setTitle("♪ 已停止")
            playerView.update(track: nil, message: "播放已停止")

        case .loadingLyrics(let track):
            setTitle(truncate("… \(track.title)"))
            playerView.update(track: track)

        case .showing(let track, let lyrics, let currentLine):
            playerView.update(track: track, artworkURL: lyrics.artworkURL)
            if lyrics.isSynced, lyrics.lineIndex(at: track.position) != nil {
                updateKaraokeProgress(track: track, lyrics: lyrics)
            } else {
                let prefix = track.state == .paused ? "⏸ " : ""
                let display = currentLine.isEmpty ? track.displayName : currentLine
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
        karaokeLineID = nil
        karaokeLineIndex = nil
        karaokeTitleView.deactivate()
        karaokeTitleView.isHidden = true
        statusItem.length = NSStatusItem.variableLength
        statusItem.button?.title = title
    }

    private func setKaraokeTitle(line: LyricLine, index: Int, track: TrackInfo) {
        guard let button = statusItem.button else { return }

        let lineChanged = karaokeLineID != nil && karaokeLineID != line.id
        if lineChanged, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let transition = CATransition()
            transition.type = .push
            if let previous = karaokeLineIndex {
                transition.subtype = index >= previous ? .fromBottom : .fromTop
            }
            transition.duration = 0.24
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            button.layer?.add(transition, forKey: "lyrics.lineTransition")
        }

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
            maximumWidth = 260
        }
        statusItem.length = karaokeTitleView.preferredWidth(maximum: maximumWidth)
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
        karaokeLineID = line.id
        karaokeLineIndex = index
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

    @objc private func toggleFloating() {
        onToggleFloating?()
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
            window.title = "Apple Music Lyrics 诊断日志"
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
    private let subtitleLabel = NSTextField(labelWithString: "未播放歌曲")
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

    override var intrinsicContentSize: NSSize {
        NSSize(width: 410, height: 150)
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 410, height: 150))
        configure()
        update(track: nil, message: "未播放歌曲")
    }

    required init?(coder: NSCoder) {
        nil
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

        configureButton(
            previousButton,
            symbol: "backward.fill",
            toolTip: "上一首",
            action: #selector(previousTrack),
            pointSize: 16
        )
        configureButton(
            playPauseButton,
            symbol: "play.fill",
            toolTip: "播放",
            action: #selector(togglePlayPause),
            pointSize: 19
        )
        configureButton(
            nextButton,
            symbol: "forward.fill",
            toolTip: "下一首",
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
        slider.toolTip = "播放进度"

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
            artworkView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            artworkView.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            artworkView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            artworkView.widthAnchor.constraint(equalTo: artworkView.heightAnchor),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            controls.centerXAnchor.constraint(equalTo: slider.centerXAnchor),
            controls.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 5),
            controls.heightAnchor.constraint(equalToConstant: 32),

            slider.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 16),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),

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
            subtitleLabel.stringValue = message ?? "未播放歌曲"
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
        let playPauseToolTip = isPlaying ? "暂停" : "播放"
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
            accessibilityDescription: "专辑封面"
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
    private struct Segment {
        let range: NSRange
        let start: TimeInterval
        let end: TimeInterval
        let offset: CGFloat
        let width: CGFloat
    }

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

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        displayTimer?.invalidate()
    }

    func update(line: LyricLine, track: TrackInfo, limit: Int) -> String {
        let now = CACurrentMediaTime()
        if currentLineID != line.id {
            currentLineID = line.id
            renderedOriginX = nil
            lastDrawTime = now
        }
        let estimated = interpolatedPosition(at: now)
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
        if isPlaying {
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
    }

    func preferredWidth(maximum: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textWidth = ceil((displayText as NSString).size(withAttributes: attributes).width)
        return min(maximum, max(28, textWidth + 16))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !displayText.isEmpty else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let upcomingAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.42),
            .paragraphStyle: paragraph
        ]
        let sungAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.96),
            .paragraphStyle: paragraph
        ]
        let upcoming = NSAttributedString(string: displayText, attributes: upcomingAttributes)
        let sung = NSAttributedString(string: displayText, attributes: sungAttributes)
        let textSize = upcoming.size()
        let now = CACurrentMediaTime()
        let position = interpolatedPosition(at: now)
        let targetOriginX = horizontalOrigin(
            textWidth: textSize.width,
            position: position
        )
        let origin = NSPoint(
            x: smoothedOrigin(target: targetOriginX, at: now),
            y: floor((bounds.height - textSize.height) / 2)
        )
        upcoming.draw(at: origin)

        if prefixLength > 0 {
            draw(
                attributed: sung,
                offset: 0,
                width: prefixWidth,
                fraction: 1,
                at: origin
            )
        }
        for segment in segments {
            let duration = max(0.01, segment.end - segment.start)
            let fraction = min(1, max(0, (position - segment.start) / duration))
            guard fraction > 0 else { continue }
            draw(
                attributed: sung,
                offset: segment.offset,
                width: segment.width,
                fraction: fraction,
                at: origin
            )
        }
    }

    private func draw(
        attributed: NSAttributedString,
        offset: CGFloat,
        width: CGFloat,
        fraction: Double,
        at origin: NSPoint
    ) {
        guard width > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(
            rect: NSRect(
                x: origin.x + offset,
                y: origin.y,
                width: width * fraction,
                height: bounds.height
            )
        ).addClip()
        attributed.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func horizontalOrigin(
        textWidth: CGFloat,
        position: TimeInterval
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
                    width: 0
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
            return Segment(
                range: segment.range,
                start: segment.start,
                end: segment.end,
                offset: metrics.attributedSubstring(from: prefixRange).size().width,
                width: metrics.attributedSubstring(from: segment.range).size().width
            )
        }
        prefixLength = (prefix as NSString).length
        prefixWidth = prefixLength > 0
            ? metrics.attributedSubstring(
                from: NSRange(location: 0, length: prefixLength)
            ).size().width
            : 0
    }

    private func activateTimer() {
        guard displayTimer == nil, isPlaying else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    private func stopTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func interpolatedPosition(at now: CFTimeInterval) -> TimeInterval {
        basePosition + (isPlaying ? max(0, now - sampledAt) : 0)
    }
}
