import AppKit
import QuartzCore

/// Desktop floating panel that shows synced lyrics with animated line transitions
/// and per-character karaoke highlighting.
final class FloatingLyricsController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "No track")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let tableView = LyricTableView()

    private var lines: [LyricLine] = []
    private var highlightIndex: Int?
    private var plainText: String?
    private var lastTrackKey: String?
    private var playbackPosition: TimeInterval = 0
    private var wordTiming: WordTimingQuality = .none
    private var scrollAnimationTimer: Timer?

    private let scrollDuration: TimeInterval = 0.46

    private var shouldReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var onVisibilityChanged: ((Bool) -> Void)?

    var isVisible: Bool {
        panel.isVisible
    }

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
    }

    deinit {
        scrollAnimationTimer?.invalidate()
    }

    // MARK: - Setup

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
        panel.minSize = NSSize(width: 280, height: 200)
        panel.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.88)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
    }

    private func configureContent() {
        let root = NSView(frame: panel.contentView?.bounds ?? .zero)
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]

        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.95)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("lyric"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.rowHeight = 36
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.wantsLayer = true
        if #available(macOS 11.0, *) {
            tableView.style = .plain
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.scrollerStyle = .overlay
        scrollView.wantsLayer = true
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        applyEdgeMask(to: scrollView)

        root.addSubview(titleLabel)
        root.addSubview(subtitleLabel)
        root.addSubview(scrollView)
        panel.contentView = root

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)
        ])
    }

    private func applyEdgeMask(to scrollView: NSScrollView) {
        let mask = CAGradientLayer()
        mask.colors = [
            NSColor.clear.cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.clear.cgColor
        ]
        mask.locations = [0, 0.08, 0.92, 1] as [NSNumber]
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        scrollView.wantsLayer = true
        scrollView.layer?.mask = mask
        DispatchQueue.main.async { [weak scrollView] in
            mask.frame = scrollView?.bounds ?? .zero
        }
    }

    private func updateEdgeMaskFrame() {
        scrollView.layer?.mask?.frame = scrollView.bounds
    }

    // MARK: - Visibility

    func show() {
        if !panel.isVisible {
            if panel.frame.origin == .zero {
                panel.center()
            }
            panel.orderFrontRegardless()
        } else {
            panel.orderFrontRegardless()
        }
        onVisibilityChanged?(true)
        saveFrame()
        updateEdgeMaskFrame()
    }

    func hide() {
        panel.orderOut(nil)
        onVisibilityChanged?(false)
        saveFrame()
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func setVisible(_ visible: Bool) {
        if visible {
            show()
        } else {
            hide()
        }
    }

    // MARK: - Content updates

    func apply(status: AppStatus) {
        switch status {
        case .idle:
            updateHeader(title: "No track", subtitle: "")
            setContent(lines: [], highlight: nil, plain: nil, trackKey: nil, position: 0, timing: .none, animate: false)

        case .musicNotRunning:
            updateHeader(title: "Music is not running", subtitle: "Start Music to show lyrics")
            setContent(lines: [], highlight: nil, plain: nil, trackKey: nil, position: 0, timing: .none, animate: false)

        case .stopped:
            updateHeader(title: "Playback stopped", subtitle: "")
            setContent(lines: [], highlight: nil, plain: nil, trackKey: nil, position: 0, timing: .none, animate: false)

        case .loadingLyrics(let track):
            updateHeader(title: track.title, subtitle: "\(track.artist) · loading…")
            setContent(lines: [], highlight: nil, plain: nil, trackKey: track.identityKey, position: 0, timing: .none, animate: false)

        case .showing(let track, let lyrics, _):
            let state = track.state == .paused ? "Paused" : "Playing"
            let karaokeTag: String
            switch lyrics.wordTiming {
            case .exact: karaokeTag = " · 逐字"
            case .estimated: karaokeTag = " · 逐字≈"
            case .none: karaokeTag = ""
            }
            updateHeader(
                title: track.title,
                subtitle: "\(track.artist) · \(state) · \(lyrics.source)\(karaokeTag)"
            )
            let highlight = lyrics.lineIndex(at: track.position)
            if lyrics.isSynced {
                setContent(
                    lines: lyrics.lines,
                    highlight: highlight,
                    plain: nil,
                    trackKey: track.identityKey,
                    position: track.position,
                    timing: lyrics.wordTiming,
                    animate: true
                )
            } else {
                setContent(
                    lines: [],
                    highlight: nil,
                    plain: lyrics.plainText,
                    trackKey: track.identityKey,
                    position: track.position,
                    timing: .none,
                    animate: false
                )
            }

        case .noLyrics(let track):
            updateHeader(title: track.title, subtitle: "\(track.artist) · no lyrics")
            setContent(
                lines: [],
                highlight: nil,
                plain: "No lyrics found for this track.",
                trackKey: track.identityKey,
                position: track.position,
                timing: .none,
                animate: false
            )

        case .error(let message):
            updateHeader(title: "Error", subtitle: message)
            setContent(lines: [], highlight: nil, plain: message, trackKey: nil, position: 0, timing: .none, animate: false)
        }
    }

    /// Called on every poll tick — updates line focus and karaoke progress.
    func updateHighlight(for track: TrackInfo, lyrics: LyricsDocument) {
        guard lyrics.isSynced else { return }
        playbackPosition = track.position
        wordTiming = lyrics.wordTiming

        let highlight = lyrics.lineIndex(at: track.position)
        if highlight != highlightIndex {
            transitionHighlight(to: highlight, animate: true)
        } else {
            paintKaraoke(at: track.position)
        }
    }

    private func updateHeader(title: String, subtitle: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        panel.title = title
    }

    private func setContent(
        lines: [LyricLine],
        highlight: Int?,
        plain: String?,
        trackKey: String?,
        position: TimeInterval,
        timing: WordTimingQuality,
        animate: Bool
    ) {
        let trackChanged = trackKey != lastTrackKey
        let linesChanged = lines != self.lines || plain != plainText
        let previousHighlight = highlightIndex

        self.lines = lines
        self.plainText = plain
        self.lastTrackKey = trackKey
        self.playbackPosition = position
        self.wordTiming = timing

        if linesChanged || trackChanged {
            highlightIndex = highlight
            tableView.reloadData()
            tableView.layoutSubtreeIfNeeded()
            scrollToHighlight(animated: false)
            if animate, let highlight {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let useAnimation = !self.shouldReduceMotion
                    self.animateVisibleProximity(animated: useAnimation)
                    self.paintCell(at: highlight, role: .active, animated: useAnimation, entranceOffset: useAnimation ? 6 : 0)
                }
            } else {
                animateVisibleProximity(animated: false)
            }
            return
        }

        if highlight != previousHighlight {
            transitionHighlight(to: highlight, animate: animate)
        } else {
            paintKaraoke(at: position)
        }
    }

    private func transitionHighlight(to newIndex: Int?, animate: Bool) {
        let previous = highlightIndex
        highlightIndex = newIndex

        let useAnimation = animate && !shouldReduceMotion
        let direction: CGFloat
        if let previous, let newIndex, previous != newIndex {
            direction = newIndex > previous ? 1 : -1
        } else {
            direction = 0
        }

        if let previous {
            paintCell(at: previous, role: role(for: previous), animated: useAnimation, entranceOffset: 0)
        }
        if let newIndex {
            paintCell(at: newIndex, role: .active, animated: useAnimation, entranceOffset: direction * 6)
        }

        animateVisibleProximity(animated: useAnimation)
        scrollToHighlight(animated: useAnimation)
    }

    private func animateVisibleProximity(animated: Bool) {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            paintCell(at: row, role: role(for: row), animated: animated, entranceOffset: 0)
        }
    }

    private func paintKaraoke(at position: TimeInterval) {
        guard let highlightIndex else { return }
        paintCell(at: highlightIndex, role: .active, animated: false, entranceOffset: 0)
        // Neighbors stay dim solid text — only active line needs position.
        _ = position
    }

    private func paintCell(at row: Int, role: LyricLineCell.Role, animated: Bool, entranceOffset: CGFloat) {
        guard let cell = cell(at: row) else { return }
        if !lines.isEmpty, row < lines.count {
            cell.apply(
                line: lines[row],
                role: role,
                position: playbackPosition,
                karaokeEnabled: wordTiming != .none,
                animated: animated,
                entranceOffset: entranceOffset
            )
        }
    }

    private func role(for row: Int) -> LyricLineCell.Role {
        guard let highlightIndex else { return .distant }
        let distance = abs(row - highlightIndex)
        switch distance {
        case 0: return .active
        case 1: return .near
        case 2: return .mid
        default: return .distant
        }
    }

    private func cell(at row: Int) -> LyricLineCell? {
        guard row >= 0, row < tableView.numberOfRows else { return nil }
        return tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? LyricLineCell
    }

    private func scrollToHighlight(animated: Bool) {
        guard let highlightIndex, highlightIndex >= 0, highlightIndex < tableView.numberOfRows else { return }

        let clipView = scrollView.contentView
        let rowRect = tableView.rect(ofRow: highlightIndex)
        let visibleHeight = clipView.bounds.height
        let documentHeight = tableView.bounds.height

        var targetY = rowRect.midY - visibleHeight * 0.42
        let maxY = max(0, documentHeight - visibleHeight)
        targetY = min(max(0, targetY), maxY)

        let current = clipView.bounds.origin
        let destination = NSPoint(x: current.x, y: targetY)
        guard abs(destination.y - current.y) > 0.5 else { return }

        scrollAnimationTimer?.invalidate()
        scrollAnimationTimer = nil

        guard animated && !shouldReduceMotion else {
            clipView.setBoundsOrigin(destination)
            scrollView.reflectScrolledClipView(clipView)
            updateEdgeMaskFrame()
            return
        }

        let startY = current.y
        let distance = destination.y - startY
        let startedAt = CACurrentMediaTime()
        let duration = scrollDuration
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak clipView] timer in
            guard let self, let clipView else {
                timer.invalidate()
                return
            }

            let elapsed = CACurrentMediaTime() - startedAt
            let progress = min(1, elapsed / duration)
            let eased = 1 - pow(1 - progress, 3)
            clipView.setBoundsOrigin(NSPoint(x: current.x, y: startY + distance * eased))
            self.scrollView.reflectScrolledClipView(clipView)

            if progress >= 1 {
                timer.invalidate()
                self.scrollAnimationTimer = nil
                self.updateEdgeMaskFrame()
            }
        }
        scrollAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - Frame persistence

    private var frameDefaultsKey: String { "floatingLyrics.frame" }

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: frameDefaultsKey)
    }

    private func restoreFrame() {
        if let raw = UserDefaults.standard.string(forKey: frameDefaultsKey) {
            let frame = NSRectFromString(raw)
            if frame.width > 100, frame.height > 100 {
                panel.setFrame(frame, display: false)
                return
            }
        }
        if let screen = NSScreen.main {
            let size = panel.frame.size
            let x = screen.visibleFrame.midX - size.width / 2
            let y = screen.visibleFrame.minY + 80
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onVisibilityChanged?(false)
        saveFrame()
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame()
        if let column = tableView.tableColumns.first {
            column.width = max(100, tableView.bounds.width - 4)
        }
        updateEdgeMaskFrame()
        scrollToHighlight(animated: false)
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int {
        if !lines.isEmpty { return lines.count }
        if plainText != nil { return 1 }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("LyricLineCell")
        let cell: LyricLineCell
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? LyricLineCell {
            cell = reused
        } else {
            cell = LyricLineCell()
            cell.identifier = id
        }

        if !lines.isEmpty {
            cell.configure(
                line: lines[row],
                role: role(for: row),
                position: playbackPosition,
                karaokeEnabled: wordTiming != .none
            )
        } else if let plainText {
            cell.configurePlain(plainText)
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if lines.isEmpty, plainText != nil { return 140 }
        return 36
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        rowView.wantsLayer = true
        rowView.backgroundColor = .clear
    }
}

// MARK: - Table view

private final class LyricTableView: NSTableView {
    override func drawGrid(inClipRect clipRect: NSRect) {}
    override func drawBackground(inClipRect clipRect: NSRect) {}
}

// MARK: - Lyric cell

private final class LyricLineCell: NSTableCellView {
    enum Role: Equatable {
        case active, near, mid, distant, plain
    }

    private let label = NSTextField(labelWithString: "")
    private var currentRole: Role = .distant

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.alignment = .center
        label.wantsLayer = true
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -2)
        ])
    }

    func configurePlain(_ text: String) {
        currentRole = .plain
        label.maximumNumberOfLines = 0
        label.alignment = .left
        label.font = Style.style(for: .plain).font
        label.textColor = Style.style(for: .plain).color
        label.stringValue = text
        label.alphaValue = 1
        layer?.sublayerTransform = CATransform3DIdentity
    }

    func configure(line: LyricLine, role: Role, position: TimeInterval, karaokeEnabled: Bool) {
        label.maximumNumberOfLines = 3
        label.alignment = .center
        apply(
            line: line,
            role: role,
            position: position,
            karaokeEnabled: karaokeEnabled,
            animated: false,
            entranceOffset: 0
        )
    }

    func apply(
        line: LyricLine,
        role: Role,
        position: TimeInterval,
        karaokeEnabled: Bool,
        animated: Bool,
        entranceOffset: CGFloat
    ) {
        let style = Style.style(for: role)
        currentRole = role

        let paintText = {
            if karaokeEnabled, role == .active, !line.words.isEmpty {
                self.label.attributedStringValue = KaraokeRenderer.attributed(
                    line: line,
                    position: position,
                    font: style.font,
                    sungColor: NSColor.systemPink.withAlphaComponent(0.95),
                    activeColor: NSColor.white,
                    upcomingColor: NSColor.white.withAlphaComponent(0.28)
                )
            } else if karaokeEnabled, role != .active, role != .plain, !line.words.isEmpty {
                // Past lines fully "sung"; future lines fully upcoming.
                let isPast: Bool
                if let last = line.words.last {
                    isPast = position >= last.end
                } else {
                    isPast = position >= line.time
                }
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: style.font,
                    .foregroundColor: isPast
                        ? style.color.withAlphaComponent(min(1, style.alpha))
                        : style.color
                ]
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                attrs[.paragraphStyle] = paragraph
                self.label.attributedStringValue = NSAttributedString(string: line.text, attributes: attrs)
            } else {
                self.label.font = style.font
                self.label.textColor = style.color
                self.label.stringValue = line.text.isEmpty ? "·" : line.text
            }
            self.label.alphaValue = style.alpha
            self.layer?.sublayerTransform = CATransform3DMakeScale(style.scale, style.scale, 1)
        }

        guard animated else {
            label.layer?.removeAllAnimations()
            paintText()
            return
        }

        if entranceOffset != 0, role == .active {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = entranceOffset
            move.toValue = 0
            move.duration = 0.32
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1.0)
            label.layer?.add(move, forKey: "lyric.move")
        }

        paintText()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.28, 1.0)
            context.allowsImplicitAnimation = true
            label.animator().alphaValue = style.alpha
            layer?.sublayerTransform = CATransform3DMakeScale(style.scale, style.scale, 1)
        }
    }

    private struct Style {
        let font: NSFont
        let color: NSColor
        let alpha: CGFloat
        let scale: CGFloat

        static func style(for role: Role) -> Style {
            switch role {
            case .active:
                return Style(
                    font: .systemFont(ofSize: 17, weight: .semibold),
                    color: NSColor.white,
                    alpha: 1.0,
                    scale: 1.08
                )
            case .near:
                return Style(
                    font: .systemFont(ofSize: 16, weight: .medium),
                    color: NSColor.white.withAlphaComponent(0.72),
                    alpha: 0.92,
                    scale: 0.98
                )
            case .mid:
                return Style(
                    font: .systemFont(ofSize: 16, weight: .medium),
                    color: NSColor.white.withAlphaComponent(0.48),
                    alpha: 0.85,
                    scale: 0.95
                )
            case .distant:
                return Style(
                    font: .systemFont(ofSize: 16, weight: .medium),
                    color: NSColor.white.withAlphaComponent(0.28),
                    alpha: 0.75,
                    scale: 0.92
                )
            case .plain:
                return Style(
                    font: .systemFont(ofSize: 14, weight: .regular),
                    color: NSColor.white.withAlphaComponent(0.8),
                    alpha: 1.0,
                    scale: 1.0
                )
            }
        }
    }
}
