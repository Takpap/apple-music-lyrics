import AppKit
import QuartzCore
import SwiftUI

/// Playback progress bar for the full-screen player.
///
/// The fill moves with a linear Core Animation running to the end of the
/// song, so the GPU animates it and the app does no per-frame work. The time
/// labels change once a second. Earlier this was a SwiftUI view in a 4 Hz
/// TimelineView, and every tick re-checked the whole lyrics view.
struct ProgressScrubberBar: NSViewRepresentable {
    let model: ImmersiveLyricsModel
    /// Inputs that should resync the bar at once.
    let isPlaying: Bool
    let trackKey: String?
    let duration: TimeInterval

    func makeNSView(context: Context) -> ProgressBarView {
        let view = ProgressBarView(model: model)
        model.onClockJump = { [weak view] in view?.refresh() }
        return view
    }

    func updateNSView(_ view: ProgressBarView, context: Context) {
        view.refresh()
    }
}

@MainActor
final class ProgressBarView: NSView {
    private unowned let model: ImmersiveLyricsModel
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let elapsedLabel = ProgressBarView.makeLabel(alignment: .left)
    private let remainingLabel = ProgressBarView.makeLabel(alignment: .right)
    private var labelTimer: Timer?
    private var hovering = false
    private var dragFraction: CGFloat?
    private var trackingArea: NSTrackingArea?

    private static let barAreaHeight: CGFloat = 12
    private static let labelGap: CGFloat = 6

    init(model: ImmersiveLyricsModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        trackLayer.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        fillLayer.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
        fillLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        addSubview(elapsedLabel)
        addSubview(remainingLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.barAreaHeight + Self.labelGap + 14)
    }

    private static func makeLabel(alignment: NSTextAlignment) -> NSTextField {
        let label = NSTextField(labelWithString: "0:00")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.5)
        label.alignment = alignment
        return label
    }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        labelTimer?.invalidate()
        labelTimer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        labelTimer = timer
        refresh()
    }

    override func layout() {
        super.layout()
        let labelHeight: CGFloat = 14
        let labelY = Self.barAreaHeight + Self.labelGap
        elapsedLabel.frame = NSRect(x: 0, y: labelY, width: bounds.width / 2, height: labelHeight)
        remainingLabel.frame = NSRect(x: bounds.width / 2, y: labelY, width: bounds.width / 2, height: labelHeight)
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: NSRect(x: 0, y: 0, width: bounds.width, height: Self.barAreaHeight),
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Drawing

    /// Puts the fill at the current position and, while playing, lets Core
    /// Animation carry it to the end of the song.
    func refresh() {
        let duration = max(model.duration, 0.01)
        let position = model.position()
        let shownTime = dragFraction.map { TimeInterval($0) * duration } ?? position
        let fraction = dragFraction ?? CGFloat(min(max(position / duration, 0), 1))
        let emphasized = hovering || dragFraction != nil
        let barHeight: CGFloat = emphasized ? 8 : 5
        let width = bounds.width
        let barY = (Self.barAreaHeight - barHeight) / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = CGRect(x: 0, y: barY, width: width, height: barHeight)
        trackLayer.cornerRadius = barHeight / 2
        fillLayer.cornerRadius = barHeight / 2
        fillLayer.backgroundColor = NSColor.white.withAlphaComponent(emphasized ? 0.9 : 0.72).cgColor
        fillLayer.position = CGPoint(x: 0, y: barY + barHeight / 2)
        let currentWidth = max(barHeight, width * fraction)
        fillLayer.bounds = CGRect(x: 0, y: 0, width: currentWidth, height: barHeight)
        fillLayer.removeAnimation(forKey: "progress")
        let remaining = duration - position
        if model.isPlaying, dragFraction == nil, remaining > 0.05, width > 0 {
            let grow = CABasicAnimation(keyPath: "bounds.size.width")
            grow.fromValue = currentWidth
            grow.toValue = max(barHeight, width)
            grow.duration = remaining
            grow.timingFunction = CAMediaTimingFunction(name: .linear)
            grow.fillMode = .forwards
            grow.isRemovedOnCompletion = false
            fillLayer.add(grow, forKey: "progress")
        }
        CATransaction.commit()

        let elapsedText = Self.format(shownTime)
        let remainingText = "-" + Self.format(max(duration - shownTime, 0))
        if elapsedLabel.stringValue != elapsedText { elapsedLabel.stringValue = elapsedText }
        if remainingLabel.stringValue != remainingText { remainingLabel.stringValue = remainingText }
    }

    static func format(_ time: TimeInterval) -> String {
        let total = Int(max(time, 0).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        model.isScrubbing = true
        updateDrag(event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateDrag(event)
    }

    override func mouseUp(with event: NSEvent) {
        updateDrag(event)
        let fraction = dragFraction ?? 0
        model.seek(to: TimeInterval(fraction) * max(model.duration, 0.01))
        model.isScrubbing = false
        dragFraction = nil
        refresh()
    }

    private func updateDrag(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        dragFraction = bounds.width > 0 ? min(max(x / bounds.width, 0), 1) : 0
        refresh()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return local.y <= Self.barAreaHeight + 2 && bounds.contains(local) ? self : nil
    }
}
