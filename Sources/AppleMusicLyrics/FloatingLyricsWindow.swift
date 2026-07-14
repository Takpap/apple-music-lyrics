import AppKit
import QuartzCore

/// Floating Apple Music-style lyrics panel with a custom, continuously animated canvas.
final class FloatingLyricsController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "No track")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let canvas = LyricsCanvasView()

    var onVisibilityChanged: ((Bool) -> Void)?

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
    }

    private func configureContent() {
        let effect = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor.withAlphaComponent(0.88)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.72)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        canvas.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(titleLabel)
        effect.addSubview(subtitleLabel)
        effect.addSubview(canvas)
        panel.contentView = effect

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: effect.topAnchor, constant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            canvas.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 5),
            canvas.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6)
        ])
    }

    func show() {
        panel.orderFrontRegardless()
        onVisibilityChanged?(true)
        saveFrame()
    }

    func hide() {
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
            panel.setFrameOrigin(
                NSPoint(
                    x: screen.visibleFrame.midX - size.width / 2,
                    y: screen.visibleFrame.minY + 80
                )
            )
        }
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChanged?(false)
        saveFrame()
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame()
        canvas.invalidateGeometry()
    }
}

// MARK: - Lyrics canvas

private final class LyricsCanvasView: NSView {
    private let horizontalInset: CGFloat = 24
    private let activeFont = NSFont.systemFont(ofSize: 19, weight: .semibold)

    private var lines: [LyricLine] = []
    private var timing: WordTimingQuality = .none
    private var activeIndex: Int?
    private var message: String?
    private var plainText: String?

    private var lineCenters: [CGFloat] = []
    private var lineHeights: [CGFloat] = []
    private var geometryWidth: CGFloat = 0
    private var geometryLinesID: [String] = []

    private var displayedOffset: CGFloat?
    private var displayedFocus: CGFloat?
    private var lastFrameTime = CACurrentMediaTime()
    private var displayTimer: Timer?

    private var basePosition: TimeInterval = 0
    private var sampledAt = CACurrentMediaTime()
    private var isPlaying = false

    private var activeLayout: KaraokeLineLayout?
    private var activeLayoutKey = ""

    private let edgeMask = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        displayTimer?.invalidate()
    }

    override var isFlipped: Bool { true }

    private func setup() {
        wantsLayer = true
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
    }

    override func layout() {
        super.layout()
        edgeMask.frame = bounds
        if abs(geometryWidth - bounds.width) > 0.5 {
            invalidateGeometry()
        }
    }

    func setLyrics(_ document: LyricsDocument, track: TrackInfo) {
        let changed = document.lines != lines
        lines = document.lines
        timing = document.wordTiming
        message = nil
        plainText = nil
        updateClock(track)
        activeIndex = document.lineIndex(at: track.position)
        if changed {
            invalidateGeometry()
            displayedOffset = nil
            displayedFocus = activeIndex.map(CGFloat.init)
        }
        activateTimer()
        needsDisplay = true
    }

    func update(track: TrackInfo, lyrics: LyricsDocument) {
        if lyrics.lines != lines {
            setLyrics(lyrics, track: track)
            return
        }
        updateClock(track)
        activeIndex = lyrics.lineIndex(at: track.position)
        activateTimer()
        needsDisplay = true
    }

    func clear() {
        lines = []
        message = nil
        plainText = nil
        stopTimer()
        needsDisplay = true
    }

    func showMessage(_ text: String) {
        lines = []
        plainText = nil
        message = text
        stopTimer()
        needsDisplay = true
    }

    func showPlainText(_ text: String) {
        lines = []
        message = nil
        plainText = text
        stopTimer()
        needsDisplay = true
    }

    func invalidateGeometry() {
        geometryWidth = 0
        geometryLinesID = []
        activeLayout = nil
        activeLayoutKey = ""
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let message {
            drawMessage(message)
            return
        }
        if let plainText {
            drawPlainText(plainText)
            return
        }
        guard !lines.isEmpty else { return }

        rebuildGeometryIfNeeded()
        guard let activeIndex, activeIndex < lineCenters.count else { return }

        let now = CACurrentMediaTime()
        let delta = min(0.05, max(1.0 / 240.0, now - lastFrameTime))
        lastFrameTime = now
        let targetFocus = CGFloat(activeIndex)
        let targetOffset = lineCenters[activeIndex] - bounds.height * 0.44

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            displayedFocus = targetFocus
            displayedOffset = targetOffset
        } else {
            displayedFocus = damp(displayedFocus, toward: targetFocus, delta: delta, response: 0.12)
            displayedOffset = damp(displayedOffset, toward: targetOffset, delta: delta, response: 0.14)
        }

        let offset = displayedOffset ?? targetOffset
        let visualFocus = displayedFocus ?? targetFocus
        let position = interpolatedPosition(at: now)
        let contentWidth = max(80, bounds.width - horizontalInset * 2)

        for index in lines.indices {
            let centerY = lineCenters[index] - offset
            let height = lineHeights[index]
            if centerY + height < -20 || centerY - height > bounds.height + 20 { continue }

            if index == activeIndex {
                drawActiveLine(
                    lines[index],
                    centerY: centerY,
                    width: contentWidth,
                    position: position,
                    prominence: max(0.55, 1 - abs(CGFloat(index) - visualFocus) * 0.45)
                )
            } else {
                drawNeighbor(
                    lines[index],
                    index: index,
                    centerY: centerY,
                    width: contentWidth,
                    visualFocus: visualFocus
                )
            }
        }
    }

    private func rebuildGeometryIfNeeded() {
        let ids = lines.map(\.id)
        guard abs(geometryWidth - bounds.width) > 0.5 || geometryLinesID != ids else { return }

        geometryWidth = bounds.width
        geometryLinesID = ids
        let width = max(80, bounds.width - horizontalInset * 2)
        var cursor: CGFloat = 0
        lineCenters = []
        lineHeights = []

        for line in lines {
            let height = max(34, measuredHeight(text: line.text, font: activeFont, width: width) + 12)
            lineHeights.append(height)
            lineCenters.append(cursor + height / 2)
            cursor += height + 5
        }
        activeLayout = nil
        activeLayoutKey = ""
    }

    private func drawActiveLine(
        _ line: LyricLine,
        centerY: CGFloat,
        width: CGFloat,
        position: TimeInterval,
        prominence: CGFloat
    ) {
        let key = "\(line.id)|\(Int(width.rounded()))"
        if activeLayoutKey != key {
            activeLayout = KaraokeLineLayout(line: line, font: activeFont, width: width)
            activeLayoutKey = key
        }
        guard let layout = activeLayout else { return }

        let origin = NSPoint(
            x: horizontalInset,
            y: centerY - layout.height / 2
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(prominence)
        if timing == .exact {
            layout.drawKaraoke(at: origin, position: position)
        } else {
            layout.drawSolid(at: origin)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawNeighbor(
        _ line: LyricLine,
        index: Int,
        centerY: CGFloat,
        width: CGFloat,
        visualFocus: CGFloat
    ) {
        let distance = abs(CGFloat(index) - visualFocus)
        let proximity = max(0, 1 - min(1, distance - 0.15))
        let fontSize = 14.5 + proximity * 1.5
        let alpha = max(0.18, 0.66 - distance * 0.14)
        let font = NSFont.systemFont(ofSize: fontSize, weight: proximity > 0.55 ? .medium : .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: line.text.isEmpty ? "·" : line.text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha),
                .paragraphStyle: paragraph
            ]
        )
        let height = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        attributed.draw(
            with: NSRect(x: horizontalInset, y: centerY - height / 2, width: width, height: height),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    private func drawMessage(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.72),
                .paragraphStyle: paragraph
            ]
        )
        let width = max(80, bounds.width - 48)
        let height = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        attributed.draw(
            with: NSRect(
                x: 24,
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
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.72),
                .paragraphStyle: paragraph
            ]
        )
        attributed.draw(
            with: bounds.insetBy(dx: 24, dy: 20),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    private func measuredHeight(text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(
            string: text.isEmpty ? "·" : text,
            attributes: [.font: font, .paragraphStyle: paragraph]
        ).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
    }

    private func updateClock(_ track: TrackInfo) {
        let now = CACurrentMediaTime()
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
        basePosition + (isPlaying ? max(0, now - sampledAt) : 0)
    }

    private func damp(
        _ current: CGFloat?,
        toward target: CGFloat,
        delta: CFTimeInterval,
        response: Double
    ) -> CGFloat {
        guard let current else { return target }
        let blend = 1 - exp(-delta / response)
        return current + (target - current) * blend
    }

    private func activateTimer() {
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }
}

// MARK: - TextKit karaoke line

private final class KaraokeLineLayout {
    private struct TimedRange {
        let characterRange: NSRange
        let start: TimeInterval
        let end: TimeInterval
    }

    private let upcomingStorage: NSTextStorage
    private let upcomingLayout = NSLayoutManager()
    private let upcomingContainer: NSTextContainer
    private let sungStorage: NSTextStorage
    private let sungLayout = NSLayoutManager()
    private let sungContainer: NSTextContainer
    private let ranges: [TimedRange]
    private let fullGlyphRange: NSRange

    let height: CGFloat

    init(line: LyricLine, font: NSFont, width: CGFloat) {
        let text = line.words.isEmpty ? line.text : line.words.map(\.text).joined()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1

        upcomingStorage = NSTextStorage(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.30),
                .paragraphStyle: paragraph
            ]
        )
        sungStorage = NSTextStorage(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.97),
                .paragraphStyle: paragraph
            ]
        )

        upcomingContainer = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        sungContainer = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        upcomingContainer.lineFragmentPadding = 0
        sungContainer.lineFragmentPadding = 0
        upcomingContainer.maximumNumberOfLines = 0
        sungContainer.maximumNumberOfLines = 0

        upcomingLayout.addTextContainer(upcomingContainer)
        sungLayout.addTextContainer(sungContainer)
        upcomingStorage.addLayoutManager(upcomingLayout)
        sungStorage.addLayoutManager(sungLayout)
        upcomingLayout.ensureLayout(for: upcomingContainer)
        sungLayout.ensureLayout(for: sungContainer)

        fullGlyphRange = upcomingLayout.glyphRange(for: upcomingContainer)
        height = ceil(max(1, upcomingLayout.usedRect(for: upcomingContainer).height))

        var location = 0
        var built: [TimedRange] = []
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
                location += length
            }
        }
        ranges = built
    }

    func drawSolid(at origin: NSPoint) {
        sungLayout.drawGlyphs(forGlyphRange: fullGlyphRange, at: origin)
    }

    func drawKaraoke(at origin: NSPoint, position: TimeInterval) {
        upcomingLayout.drawGlyphs(forGlyphRange: fullGlyphRange, at: origin)
        let sungClip = NSBezierPath()

        for range in ranges {
            let duration = max(0.01, range.end - range.start)
            let fraction = min(1, max(0, (position - range.start) / duration))
            guard fraction > 0 else { continue }

            let glyphRange = sungLayout.glyphRange(
                forCharacterRange: range.characterRange,
                actualCharacterRange: nil
            )
            let rects = lineRects(for: glyphRange)
            let totalWidth = rects.reduce(CGFloat(0)) { $0 + $1.width }
            var remaining = totalWidth * fraction

            for rect in rects where remaining > 0 {
                let width = min(rect.width, remaining)
                sungClip.appendRect(
                    NSRect(
                        x: origin.x + rect.minX,
                        y: origin.y + rect.minY,
                        width: width,
                        height: rect.height
                    )
                )
                remaining -= width
            }
        }

        guard sungClip.elementCount > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        sungClip.addClip()
        sungLayout.drawGlyphs(forGlyphRange: fullGlyphRange, at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func lineRects(for glyphRange: NSRange) -> [NSRect] {
        var rects: [NSRect] = []
        var glyphIndex = glyphRange.location
        let end = NSMaxRange(glyphRange)

        while glyphIndex < end {
            var lineRange = NSRange()
            _ = sungLayout.lineFragmentUsedRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineRange
            )
            let intersection = NSIntersectionRange(lineRange, glyphRange)
            if intersection.length > 0 {
                rects.append(sungLayout.boundingRect(forGlyphRange: intersection, in: sungContainer))
            }
            let next = NSMaxRange(lineRange)
            if next <= glyphIndex { break }
            glyphIndex = next
        }
        return rects
    }
}
