import AppKit
import QuartzCore

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let karaokeTitleView = KaraokeStatusTitleView()

    private let trackItem = NSMenuItem(title: "No track", action: nil, keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
    private let sourceItem = NSMenuItem(title: "Source: —", action: nil, keyEquivalent: "")
    private let lyricsHeader = NSMenuItem(title: "Lyrics", action: nil, keyEquivalent: "")
    private let floatingItem = NSMenuItem(
        title: "Show Floating Lyrics",
        action: #selector(toggleFloating),
        keyEquivalent: "l"
    )

    private var lyricMenuItems: [NSMenuItem] = []
    private var plainLyricsWindow: NSWindow?
    private var floatingVisible = false
    private var karaokeLineID: String?
    private var karaokeLineIndex: Int?

    var onRefreshLyrics: (() -> Void)?
    var onToggleFloating: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        floatingItem.target = self
        configureStatusItem()
        rebuildMenu()
    }

    /// Lightweight update for playback time without rebuilding the lyrics menu.
    func updatePlaybackProgress(track: TrackInfo) {
        stateItem.title =
            "Status: \(track.state.rawValue.capitalized) · \(formatTime(track.position)) / \(formatTime(track.duration))"
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
        floatingItem.title = visible ? "Hide Floating Lyrics" : "Show Floating Lyrics"
        floatingItem.state = visible ? .on : .off
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

        trackItem.isEnabled = false
        stateItem.isEnabled = false
        sourceItem.isEnabled = false
        lyricsHeader.isEnabled = false

        menu.addItem(trackItem)
        menu.addItem(stateItem)
        menu.addItem(sourceItem)
        menu.addItem(.separator())

        menu.addItem(lyricsHeader)
        for item in lyricMenuItems {
            menu.addItem(item)
        }

        menu.addItem(.separator())

        menu.addItem(floatingItem)

        let refresh = NSMenuItem(
            title: "Refresh Lyrics",
            action: #selector(refreshLyrics),
            keyEquivalent: "r"
        )
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Apple Music Lyrics",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Public updates

    func apply(status: AppStatus) {
        switch status {
        case .idle:
            setTitle("♪")
            trackItem.title = "No track"
            stateItem.title = "Status: Idle"
            sourceItem.title = "Source: —"
            setLyricPreview(lines: [], highlightIndex: nil, plainFallback: nil)

        case .musicNotRunning:
            setTitle("♪ Music")
            trackItem.title = "Music is not running"
            stateItem.title = "Status: Waiting for Music.app"
            sourceItem.title = "Source: —"
            setLyricPreview(lines: [], highlightIndex: nil, plainFallback: nil)

        case .stopped:
            setTitle("♪ Stopped")
            trackItem.title = "Playback stopped"
            stateItem.title = "Status: Stopped"
            sourceItem.title = "Source: —"
            setLyricPreview(lines: [], highlightIndex: nil, plainFallback: nil)

        case .loadingLyrics(let track):
            setTitle(truncate("… \(track.title)"))
            trackItem.title = track.displayName
            stateItem.title = "Status: Loading lyrics…"
            sourceItem.title = "Source: Apple Music cache"
            setLyricPreview(lines: [], highlightIndex: nil, plainFallback: nil)

        case .showing(let track, let lyrics, let currentLine):
            if lyrics.isSynced, lyrics.lineIndex(at: track.position) != nil {
                updateKaraokeProgress(track: track, lyrics: lyrics)
            } else {
                let prefix = track.state == .paused ? "⏸ " : ""
                let display = currentLine.isEmpty ? track.displayName : currentLine
                setTitle(truncate(prefix + display))
            }
            trackItem.title = track.displayName
            stateItem.title = "Status: \(track.state.rawValue.capitalized) · \(formatTime(track.position)) / \(formatTime(track.duration))"
            let karaoke: String
            switch lyrics.wordTiming {
            case .exact: karaoke = " · 逐字"
            case .estimated: karaoke = " · 逐字≈"
            case .none: karaoke = ""
            }
            sourceItem.title = "Source: \(lyrics.source)"
                + (lyrics.isSynced ? " (synced)" : " (plain)")
                + karaoke
            let highlight = lyrics.lineIndex(at: track.position)
            setLyricPreview(lines: lyrics.lines, highlightIndex: highlight, plainFallback: lyrics.plainText)

        case .noLyrics(let track):
            let prefix = track.state == .paused ? "⏸ " : "♪ "
            setTitle(truncate(prefix + track.displayName))
            trackItem.title = track.displayName
            stateItem.title = "Status: \(track.state.rawValue.capitalized) · no lyrics"
            sourceItem.title = "Source: —"
            setLyricPreview(lines: [], highlightIndex: nil, plainFallback: "No lyrics found for this track.")

        case .error(let message):
            setTitle("♪ Error")
            trackItem.title = "Error"
            stateItem.title = message
            sourceItem.title = "Source: —"
            setLyricPreview(lines: [], highlightIndex: nil, plainFallback: message)
        }
    }

    // MARK: - Menu lyrics preview

    private func setLyricPreview(lines: [LyricLine], highlightIndex: Int?, plainFallback: String?) {
        lyricMenuItems.removeAll()

        if lines.isEmpty {
            if let plainFallback, !plainFallback.isEmpty {
                let preview = plainFallback
                    .components(separatedBy: .newlines)
                    .prefix(12)
                    .joined(separator: "\n")
                let item = NSMenuItem(
                    title: truncate(preview.replacingOccurrences(of: "\n", with: " / "), limit: 80),
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                lyricMenuItems.append(item)

                let open = NSMenuItem(
                    title: "Show Full Plain Lyrics…",
                    action: #selector(showPlainLyrics),
                    keyEquivalent: ""
                )
                open.target = self
                open.representedObject = plainFallback
                lyricMenuItems.append(open)
            } else {
                let item = NSMenuItem(title: "(no lyrics)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                lyricMenuItems.append(item)
            }
        } else {
            let window = 7
            let center = highlightIndex ?? 0
            let start = max(0, center - window / 2)
            let end = min(lines.count, start + window)
            let adjustedStart = max(0, end - window)

            for index in adjustedStart..<end {
                let line = lines[index]
                let mark = (index == highlightIndex) ? "▶ " : "   "
                let text = line.text.isEmpty ? "·" : line.text
                let title = "\(mark)\(formatTime(line.time))  \(text)"
                let item = NSMenuItem(title: truncate(title, limit: 90), action: nil, keyEquivalent: "")
                item.isEnabled = false
                if index == highlightIndex {
                    item.attributedTitle = NSAttributedString(
                        string: truncate(title, limit: 90),
                        attributes: [
                            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                            .foregroundColor: NSColor.labelColor
                        ]
                    )
                }
                lyricMenuItems.append(item)
            }

            if lines.count > window {
                let more = NSMenuItem(
                    title: "… \(lines.count) lines total",
                    action: nil,
                    keyEquivalent: ""
                )
                more.isEnabled = false
                lyricMenuItems.append(more)
            }
        }

        rebuildMenu()
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

    private func formatTime(_ time: TimeInterval) -> String {
        let total = max(0, Int(time.rounded(.down)))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
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

    @objc private func showPlainLyrics(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }

        if plainLyricsWindow == nil {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 520))
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder
            scroll.drawsBackground = true

            let textView = NSTextView(frame: scroll.bounds)
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = NSFont.systemFont(ofSize: 14)
            textView.string = text
            textView.autoresizingMask = [.width, .height]
            scroll.documentView = textView

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Lyrics"
            window.contentView = scroll
            window.center()
            window.isReleasedWhenClosed = false
            plainLyricsWindow = window
        } else if let scroll = plainLyricsWindow?.contentView as? NSScrollView,
                  let textView = scroll.documentView as? NSTextView {
            textView.string = text
        }

        plainLyricsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        activateTimer()
        return displayText
    }

    func deactivate() {
        displayTimer?.invalidate()
        displayTimer = nil
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
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func interpolatedPosition(at now: CFTimeInterval) -> TimeInterval {
        basePosition + (isPlaying ? max(0, now - sampledAt) : 0)
    }
}
