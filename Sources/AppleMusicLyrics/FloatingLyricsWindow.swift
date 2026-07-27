import AppKit
import CoreVideo
import QuartzCore

/// Floating Apple Music-style lyrics panel with a custom, continuously animated canvas.
final class FloatingLyricsController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "No track")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let canvas = LyricsCanvasView()
    private var frameSaveWorkItem: DispatchWorkItem?
    private var moveEndWorkItem: DispatchWorkItem?

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
        frameSaveWorkItem?.cancel()
        frameSaveWorkItem = nil
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: frameDefaultsKey)
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
        canvas.setWindowVisible(false)
        onVisibilityChanged?(false)
        saveFrame()
    }

    func windowWillMove(_ notification: Notification) {
        moveEndWorkItem?.cancel()
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
            self.panel.hasShadow = true
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
        panel.hasShadow = true
        panel.invalidateShadow()
        saveFrame()
    }
}

// MARK: - Lyrics canvas

private final class LyricsCanvasView: NSView {
    private enum AnimationSpec {
        static let lineStateDuration: CFTimeInterval = 0.33
        static let lineSpringMass: CGFloat = 1
        static let lineSpringStiffness: CGFloat = 140
        static let lineSpringDamping: CGFloat = 24
        static let lineScrollHeadstart: TimeInterval = 0.5
        static let featherWidth: CGFloat = 10
        static let animationHeadstart: TimeInterval = 0
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
        return min(2.2, max(0.85, min(widthScale, heightScale)))
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

    private var basePosition: TimeInterval = 0
    private var sampledAt = CACurrentMediaTime()
    private var isPlaying = false

    private let edgeMask = CAGradientLayer()
    private let lyricsLayer = NoImplicitAnimationLayer()
    private var karaokeLayers: [KaraokeLineLayer] = []
    private var visualActiveIndex: Int?
    private var visualScrollIndex: Int?
    private var scrollPosition: CGFloat = 0
    private var scrollTarget: CGFloat = 0
    private var scrollVelocity: CGFloat = 0
    private var scrollSampleTime: CFTimeInterval = 0
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
        let needsLineStateUpdate = lineChanged || visualActiveIndex != resolvedIndex
        let anticipatedIndex = lineIndex(
            at: position + AnimationSpec.lineScrollHeadstart
        ) ?? resolvedIndex
        let scrollIndex = min(resolvedIndex + 1, anticipatedIndex)
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
        if needsScrollUpdate || !animateLineChange {
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
        advanceScroll(at: frameTime)
        CATransaction.commit()
    }

    private func updateLineStates(activeIndex: Int, animated: Bool) {
        let previous = visualActiveIndex
        visualActiveIndex = activeIndex
        var candidates = Set(max(0, activeIndex - 7)...min(karaokeLayers.count - 1, activeIndex + 7))
        if let previous {
            candidates.formUnion(
                max(0, previous - 7)...min(karaokeLayers.count - 1, previous + 7)
            )
        }

        for index in candidates {
            let lineLayer = karaokeLayers[index]
            let distance = abs(index - activeIndex)
            if distance <= 7 {
                lineLayer.prepareForDisplay()
            }
            let opacity: Float = distance == 0 ? 1 : max(0.16, 0.62 - Float(distance) * 0.13)
            let scale: CGFloat = distance == 0 ? 1 : max(0.82, 0.88 - CGFloat(distance) * 0.015)
            lineLayer.setVisualState(
                opacity: opacity,
                scale: scale,
                hidden: distance > 5,
                animated: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                duration: AnimationSpec.lineStateDuration
            )
        }
    }

    private func scroll(to index: Int, animated: Bool) {
        let target = lineCenters[index] - bounds.height * 0.44
        if !isScrollStateInitialized {
            scrollPosition = lyricsLayer.bounds.origin.y
            scrollTarget = scrollPosition
            scrollVelocity = 0
            scrollSampleTime = CACurrentMediaTime()
            isScrollStateInitialized = true
        }

        scrollTarget = target
        guard animated,
              isPlaying,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            scrollPosition = target
            scrollVelocity = 0
            applyScrollPosition()
            return
        }
    }

    private func advanceScroll(at now: CFTimeInterval) {
        guard isScrollStateInitialized else { return }
        var remaining = min(max(0, now - scrollSampleTime), 1.0 / 15.0)
        scrollSampleTime = now

        // Small fixed integration steps keep the spring stable when the main
        // thread misses a display refresh, while retaining velocity across lines.
        while remaining > 0 {
            let step = min(remaining, 1.0 / 120.0)
            let delta = CGFloat(step)
            let acceleration = (
                AnimationSpec.lineSpringStiffness * (scrollTarget - scrollPosition)
                    - AnimationSpec.lineSpringDamping * scrollVelocity
            ) / AnimationSpec.lineSpringMass
            scrollVelocity += acceleration * delta
            scrollPosition += scrollVelocity * delta
            remaining -= step
        }

        if abs(scrollTarget - scrollPosition) < 0.05,
           abs(scrollVelocity) < 0.05 {
            scrollPosition = scrollTarget
            scrollVelocity = 0
        }
        applyScrollPosition()
    }

    private func applyScrollPosition() {
        var newBounds = lyricsLayer.bounds
        newBounds.origin.y = scrollPosition
        lyricsLayer.bounds = newBounds
    }

    private func clearKaraokeLayers() {
        karaokeLayers.forEach { $0.removeFromSuperlayer() }
        karaokeLayers = []
        visualActiveIndex = nil
        visualScrollIndex = nil
        scrollPosition = 0
        scrollTarget = 0
        scrollVelocity = 0
        scrollSampleTime = 0
        isScrollStateInitialized = false
        lyricsLayer.isHidden = true
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
    private let ranges: [TimedRange]
    private var timedMasks: [TimedMask] = []
    private var timedUnits: [TimedUnit] = []

    let textHeight: CGFloat

    init(
        line: LyricLine,
        fallbackEnd: TimeInterval,
        font: NSFont,
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
        textHeight = upcomingLayer.textHeight

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

        for range in ranges {
            let upcomingFragments = upcomingLayer.fragments(for: range.characterRange)
            let highlightedFragments = highlightedLayer.fragments(for: range.characterRange)
            let totalWidth = upcomingFragments.reduce(CGFloat(0)) { $0 + $1.rect.width }
            let unit = TimedGlyphUnitLayer(
                size: CGSize(width: width, height: textHeight),
                lift: max(1.5, font.pointSize * 0.12)
            )
            var consumedWidth: CGFloat = 0
            for (upcomingFragment, highlightedFragment) in zip(
                upcomingFragments,
                highlightedFragments
            ) where upcomingFragment.rect.width > 0 {
                let duration = max(0.01, range.end - range.start)
                let fragmentStart = range.start
                    + duration * TimeInterval(consumedWidth / max(1, totalWidth))
                consumedWidth += upcomingFragment.rect.width
                let fragmentEnd = range.start
                    + duration * TimeInterval(consumedWidth / max(1, totalWidth))

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
            timedUnits.append(
                TimedUnit(start: range.start, layer: unit)
            )
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override init(layer: Any) {
        guard let source = layer as? KaraokeLineLayer else {
            fatalError("Unexpected layer copy")
        }
        upcomingLayer = source.upcomingLayer
        highlightedLayer = source.highlightedLayer
        ranges = source.ranges
        timedMasks = source.timedMasks
        timedUnits = source.timedUnits
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
    }

    func setVisualState(
        opacity: Float,
        scale: CGFloat,
        hidden: Bool,
        animated: Bool,
        duration: CFTimeInterval
    ) {
        let targetTransform = CATransform3DMakeScale(scale, scale, 1)
        if isHidden == hidden,
           abs(self.opacity - opacity) < 0.001,
           CATransform3DEqualToTransform(transform, targetTransform) {
            return
        }
        isHidden = hidden
        let oldOpacity = presentation()?.opacity ?? self.opacity
        let oldTransform = presentation()?.transform ?? transform
        self.opacity = opacity
        transform = targetTransform
        guard animated else {
            removeAnimation(forKey: "lineOpacity")
            removeAnimation(forKey: "lineScale")
            return
        }

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = oldOpacity
        opacityAnimation.toValue = opacity
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
