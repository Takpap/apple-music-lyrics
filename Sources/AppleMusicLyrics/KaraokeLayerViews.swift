import AppKit
import QuartzCore
import SwiftUI

// The two parts of the full-screen player that change every frame, the word
// sweep of the line being sung and the dots of an instrumental break, are
// drawn with Core Animation. Their animations are laid out once per line on
// a layer whose local time is the song position, so the render server plays
// them on the GPU and the app does no per-frame work. (Driving them from a
// SwiftUI TimelineView made SwiftUI re-evaluate its view graph 60 times a
// second, which was most of the app's CPU.)

// MARK: - Song clock

/// A layer whose local time runs as the song position: animations added to
/// it, or to its sublayers, use song seconds for `beginTime`.
final class SongClockLayer: CALayer {
    /// Puts the layer's local time at `position`, running or paused.
    func sync(position: TimeInterval, playing: Bool) {
        let parentNow = superlayer.map { $0.convertTime(CACurrentMediaTime(), from: nil) } ?? CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        speed = playing ? 1 : 0
        beginTime = parentNow
        timeOffset = position
        CATransaction.commit()
    }

    /// The song position the layer is showing now.
    var songTime: TimeInterval {
        let parentNow = superlayer.map { $0.convertTime(CACurrentMediaTime(), from: nil) } ?? CACurrentMediaTime()
        return (parentNow - beginTime) * Double(speed) + timeOffset
    }

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Base for views that animate on a `SongClockLayer`: keeps the clock in
/// step with the model, checking twice a second (a cheap comparison) and
/// resetting it only after a seek or drift.
class SongClockView: NSView {
    let clock = SongClockLayer()
    weak var model: ImmersiveLyricsModel?
    private var syncTimer: Timer?
    private var playing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer = CALayer()
        layer?.addSublayer(clock)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            syncTimer?.invalidate()
            syncTimer = nil
        } else {
            updateContentsScale()
            resync(force: true)
            startTimerIfNeeded()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    func updateContentsScale() {}

    func setPlaying(_ playing: Bool) {
        guard playing != self.playing else { return }
        self.playing = playing
        resync(force: true)
        startTimerIfNeeded()
    }

    func resync(force: Bool) {
        guard let model else { return }
        let target = model.position()
        if force || abs(clock.songTime - target) > 0.06 || (clock.speed == 0) == playing {
            clock.sync(position: target, playing: playing)
        }
    }

    private func startTimerIfNeeded() {
        guard syncTimer == nil, window != nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.resync(force: false) }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        syncTimer = timer
    }

    deinit { syncTimer?.invalidate() }

    /// A layer animation that begins at song time `start` (in clock time)
    /// and holds its first and last values outside its span.
    static func timed(_ animation: CAAnimation, start: TimeInterval, duration: TimeInterval) -> CAAnimation {
        // 0 means "now" to Core Animation, so never pass exactly 0.
        animation.beginTime = start == 0 ? 0.0001 : start
        animation.duration = max(duration, 0.01)
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }
}

// MARK: - Karaoke line

/// Lays out word groups exactly like the SwiftUI rows: each group is kept on
/// one row and groups wrap left-aligned.
struct KaraokeLineLayout {
    struct Token {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let frame: CGRect
    }

    let tokens: [Token]
    let size: CGSize

    init(groups: [[SyllableToken]], font: NSFont, maxWidth: CGFloat, rowSpacing: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        var tokens: [Token] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var widest: CGFloat = 0
        for group in groups {
            let widths = group.map { ceil(($0.text as NSString).size(withAttributes: attributes).width) }
            let groupWidth = widths.reduce(0, +)
            if x > 0, x + groupWidth > maxWidth {
                y += lineHeight + rowSpacing
                x = 0
            }
            for (token, width) in zip(group, widths) {
                tokens.append(Token(
                    text: token.text, start: token.start, end: token.end,
                    frame: CGRect(x: x, y: y, width: width, height: lineHeight)
                ))
                x += width
            }
            widest = max(widest, x)
        }
        self.tokens = tokens
        self.size = CGSize(width: min(widest, maxWidth), height: tokens.isEmpty ? 0 : y + lineHeight)
    }
}

final class KaraokeLineNSView: SongClockView {
    struct Content: Hashable {
        let groups: [[String]]
        let times: [[TimeInterval]]
        let fontSize: CGFloat
        let width: CGFloat
    }

    private var content: Content?
    private var groups: [[SyllableToken]] = []
    private var metrics: LyricsMetrics?
    /// Recent measurements: SwiftUI asks for sizes at several trial widths
    /// on every layout pass, and measuring the text each time was the
    /// line's biggest cost.
    private var sizes: [Content: CGSize] = [:]

    /// Sets the line to show. The layers are built for the view's real
    /// width, here or in `layout()`, never for SwiftUI's trial widths.
    func configure(groups: [[SyllableToken]], metrics: LyricsMetrics) {
        self.groups = groups
        self.metrics = metrics
        rebuildIfNeeded()
    }

    private func rebuildIfNeeded() {
        guard let metrics, bounds.width > 0 else { return }
        let next = Self.key(groups: groups, metrics: metrics, width: bounds.width)
        guard next != content else { return }
        content = next
        let font = NSFont.systemFont(ofSize: metrics.fontSize, weight: .bold)
        let layout = KaraokeLineLayout(groups: groups, font: font, maxWidth: bounds.width, rowSpacing: metrics.rowSpacing)
        build(layout, font: font, metrics: metrics)
    }

    func size(groups: [[SyllableToken]], metrics: LyricsMetrics, width: CGFloat) -> CGSize {
        let key = Self.key(groups: groups, metrics: metrics, width: width)
        if let size = sizes[key] { return size }
        let font = NSFont.systemFont(ofSize: metrics.fontSize, weight: .bold)
        let size = KaraokeLineLayout(groups: groups, font: font, maxWidth: width, rowSpacing: metrics.rowSpacing).size
        if sizes.count >= 8 { sizes.removeAll(keepingCapacity: true) }
        sizes[key] = size
        return size
    }

    private static func key(groups: [[SyllableToken]], metrics: LyricsMetrics, width: CGFloat) -> Content {
        Content(
            groups: groups.map { $0.map(\.text) },
            times: groups.map { $0.flatMap { [$0.start, $0.end] } },
            fontSize: metrics.fontSize,
            width: width
        )
    }

    override func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 2
        clock.sublayers?.forEach { word in
            word.sublayers?.forEach { $0.contentsScale = scale; $0.mask?.contentsScale = scale }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clock.frame = bounds
        CATransaction.commit()
        rebuildIfNeeded()
    }

    private func build(_ layout: KaraokeLineLayout, font: NSFont, metrics: LyricsMetrics) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clock.sublayers?.forEach { $0.removeFromSuperlayer() }
        let scale = window?.backingScaleFactor ?? 2
        let fade = metrics.fadeWidth
        let lift = metrics.liftDistance

        for token in layout.tokens {
            let word = CALayer()
            // Scale from the bottom edge, like the SwiftUI rows. The view is
            // flipped, so the bottom edge is maxY.
            word.bounds = CGRect(origin: .zero, size: token.frame.size)
            word.anchorPoint = CGPoint(x: 0.5, y: 1)
            word.position = CGPoint(x: token.frame.midX, y: token.frame.maxY)

            let dim = Self.textLayer(token.text, font: font, color: NSColor.white.withAlphaComponent(0.34), scale: scale)
            dim.frame = word.bounds
            word.addSublayer(dim)

            let bright = Self.textLayer(token.text, font: font, color: .white, scale: scale)
            bright.frame = word.bounds
            // The sweep: a mask that is opaque, then fades over `fade`
            // points, then clear; sliding it right reveals the word.
            let mask = CAGradientLayer()
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            let maskWidth = token.frame.width * 2 + fade
            mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
            mask.locations = [
                0,
                NSNumber(value: Double(token.frame.width / maskWidth)),
                NSNumber(value: Double((token.frame.width + fade) / maskWidth)),
                1
            ]
            mask.anchorPoint = .zero
            mask.bounds = CGRect(x: 0, y: 0, width: maskWidth, height: token.frame.height)
            mask.position = CGPoint(x: -token.frame.width - fade, y: 0)
            mask.contentsScale = scale
            bright.mask = mask
            word.addSublayer(bright)

            let duration = max(token.end - token.start, 0.05)
            let sweep = CABasicAnimation(keyPath: "position.x")
            // Ends with the opaque part exactly over the word (the fade
            // past its right edge), so a sung word is lit from its first
            // letter. Ending at `+fade` left the first letters dim.
            sweep.fromValue = -token.frame.width - fade
            sweep.toValue = 0
            mask.add(Self.timed(sweep, start: token.start, duration: duration), forKey: "sweep")

            // Each word rises a little as it is sung (smoothstep). The view
            // is flipped, so up is negative y.
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = 0
            rise.toValue = -lift
            rise.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 0, 0.67, 1)
            word.add(Self.timed(rise, start: token.start, duration: duration), forKey: "rise")

            // Long, held words glow and swell slightly while they are sung.
            let letters = token.text.trimmingCharacters(in: .whitespaces).count
            if duration >= 1.0, letters > 0, letters <= 9 {
                let strength = CGFloat(min(1, (duration - 0.8) / 1.2))
                bright.shadowColor = NSColor.white.cgColor
                bright.shadowOffset = .zero
                bright.shadowRadius = metrics.fontSize * 0.2
                bright.shadowOpacity = 0
                let curve = (0...12).map { CGFloat(sin(Double($0) / 12 * .pi)) * strength }
                let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
                glow.values = curve.map { Float($0 * 0.7) }
                bright.add(Self.timed(glow, start: token.start, duration: duration), forKey: "glow")
                let swell = CAKeyframeAnimation(keyPath: "transform.scale")
                swell.values = curve.map { 1 + $0 * 0.045 }
                word.add(Self.timed(swell, start: token.start, duration: duration), forKey: "swell")
            }
            clock.addSublayer(word)
        }
        CATransaction.commit()
        resync(force: true)
    }

    private static func textLayer(_ text: String, font: NSFont, color: NSColor, scale: CGFloat) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        layer.contentsScale = scale
        layer.isWrapped = false
        layer.truncationMode = .none
        return layer
    }
}

/// The line being sung, for word-timed lyrics.
struct KaraokeLine: NSViewRepresentable {
    let model: ImmersiveLyricsModel
    let groups: [[SyllableToken]]
    let metrics: LyricsMetrics
    let isPlaying: Bool

    func makeNSView(context: Context) -> KaraokeLineNSView {
        let view = KaraokeLineNSView()
        view.model = model
        return view
    }

    func updateNSView(_ view: KaraokeLineNSView, context: Context) {
        view.model = model
        view.configure(groups: groups, metrics: metrics)
        view.setPlaying(isPlaying)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: KaraokeLineNSView, context: Context) -> CGSize? {
        // Unbounded or zero trial widths measure at the column width.
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? metrics.width
        let size = nsView.size(groups: groups, metrics: metrics, width: width)
        return CGSize(width: width, height: size.height)
    }
}

// MARK: - Interlude dots

final class InterludeDotsNSView: SongClockView {
    struct Content: Equatable {
        let start: TimeInterval
        let end: TimeInterval
        let dotSize: CGFloat
    }

    private var content: Content?

    func configure(start: TimeInterval, end: TimeInterval, dotSize: CGFloat) {
        let next = Content(start: start, end: end, dotSize: dotSize)
        guard next != content else { return }
        content = next
        build(next)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clock.frame = bounds
        CATransaction.commit()
    }

    private func build(_ content: Content) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clock.sublayers?.forEach { $0.removeFromSuperlayer() }
        let size = content.dotSize
        let spacing = size * 0.62
        let height = size * 1.6
        let group = CALayer()
        group.bounds = CGRect(x: 0, y: 0, width: size * 3 + spacing * 2, height: height)
        group.anchorPoint = CGPoint(x: 0, y: 0.5)
        group.position = CGPoint(x: 0, y: height / 2)

        let length = max(content.end - content.start, 0.5)
        let fillDuration = max(length - 0.75, 0.25)
        for index in 0..<3 {
            let dot = CALayer()
            dot.frame = CGRect(x: CGFloat(index) * (size + spacing), y: (height - size) / 2, width: size, height: size)
            dot.cornerRadius = size / 2
            dot.backgroundColor = NSColor.white.cgColor
            dot.opacity = 0.3
            group.addSublayer(dot)
            // Each dot fills over its third of the break.
            let fill = CABasicAnimation(keyPath: "opacity")
            fill.fromValue = 0.3
            fill.toValue = 1.0
            dot.add(Self.timed(fill, start: content.start + fillDuration * Double(index) / 3, duration: fillDuration / 3), forKey: "fill")
        }

        // Grow in, breathe, swell, then vanish just before the next line:
        // the same curve the SwiftUI version computed every frame.
        let steps = max(24, Int(length * 12))
        var scales: [CGFloat] = []
        var opacities: [Float] = []
        for step in 0...steps {
            let elapsed = length * Double(step) / Double(steps)
            var scale = 1 + 0.07 * sin(elapsed * 2 * .pi / 2.4)
            var opacity = 1.0
            let toEnd = length - elapsed
            if toEnd < 0.75 {
                let phase = 1 - max(toEnd, 0) / 0.75
                if phase < 0.45 {
                    scale *= 1 + 0.18 * (phase / 0.45)
                } else {
                    let shrink = (phase - 0.45) / 0.55
                    scale *= 1.18 * (1 - shrink)
                    opacity = 1 - shrink
                }
            } else if elapsed < 0.4 {
                scale *= 0.6 + 0.4 * (elapsed / 0.4)
            }
            scales.append(CGFloat(max(scale, 0.001)))
            opacities.append(Float(opacity))
        }
        let breathe = CAKeyframeAnimation(keyPath: "transform.scale")
        breathe.values = scales
        group.add(Self.timed(breathe, start: content.start, duration: length), forKey: "breathe")
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = opacities
        group.add(Self.timed(fade, start: content.start, duration: length), forKey: "fade")
        clock.addSublayer(group)
        CATransaction.commit()
        resync(force: true)
    }
}

struct InterludeDots: NSViewRepresentable {
    let model: ImmersiveLyricsModel
    let start: TimeInterval
    let end: TimeInterval
    let metrics: LyricsMetrics
    let isPlaying: Bool

    func makeNSView(context: Context) -> InterludeDotsNSView {
        let view = InterludeDotsNSView()
        view.model = model
        return view
    }

    func updateNSView(_ view: InterludeDotsNSView, context: Context) {
        view.model = model
        view.configure(start: start, end: end, dotSize: metrics.dotSize)
        view.setPlaying(isPlaying)
    }
}
