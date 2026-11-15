import AppKit
import SwiftUI

// MARK: - Layout metrics

struct LyricsMetrics: Equatable {
    let fontSize: CGFloat
    let width: CGFloat

    var translationSize: CGFloat { (fontSize * 0.56).rounded() }
    var itemSpacing: CGFloat { (fontSize * 0.62).rounded() }
    var hoverPaddingH: CGFloat { (fontSize * 0.36).rounded() }
    var hoverPaddingV: CGFloat { (fontSize * 0.26).rounded() }
    var rowSpacing: CGFloat { (fontSize * 0.06).rounded() }
    var dotSize: CGFloat { (fontSize * 0.36).rounded() }
    var liftDistance: CGFloat { max(1.5, fontSize * 0.05) }
    /// Width of the soft edge that sweeps across a word as it is sung.
    var fadeWidth: CGFloat { fontSize * 0.55 }
}

// MARK: - Column

/// The state the column draws; equal states skip all work, so model updates
/// that don't concern the lyrics (volume, artwork, chrome) cost nothing.
struct LyricsColumnState: Equatable {
    var items: [LyricDisplayItem]
    var activeIndex: Int?
    var isSynced: Bool
    var isUserScrolling: Bool
    var manualScrollOffset: CGFloat
    var showTranslation: Bool
    var hasExactWordTiming: Bool
    var isPlaying: Bool
    var metrics: LyricsMetrics
    var anchorFraction: CGFloat
}

/// The right-hand lyrics column. Each row is a small SwiftUI view in its own
/// hosting view whose content changes only when the row's own state does
/// (it becomes the current line, a translation arrives). Moving the rows,
/// and their scale, blur and fade as the current line changes, are Core
/// Animation springs, with a small per-row delay for the cascading motion of
/// Music.app's lyrics view. The render server plays them, so a line change
/// no longer makes SwiftUI redraw the column on every display frame.
struct ImmersiveLyricsColumn: NSViewRepresentable {
    @ObservedObject var model: ImmersiveLyricsModel
    let metrics: LyricsMetrics
    let anchorFraction: CGFloat

    func makeNSView(context: Context) -> LyricsColumnView {
        LyricsColumnView(model: model)
    }

    func updateNSView(_ view: LyricsColumnView, context: Context) {
        view.update(
            LyricsColumnState(
                items: model.items,
                activeIndex: model.activeIndex,
                isSynced: model.isSynced,
                isUserScrolling: model.isUserScrolling,
                manualScrollOffset: model.manualScrollOffset,
                showTranslation: model.showTranslation,
                hasExactWordTiming: model.hasExactWordTiming,
                isPlaying: model.isPlaying,
                metrics: metrics,
                anchorFraction: anchorFraction
            ),
            animated: context.transaction.animation != nil
        )
    }
}

final class LyricsColumnView: NSView {
    private let model: ImmersiveLyricsModel
    private(set) var state: LyricsColumnState?
    private(set) var rows: [LyricRowContainer] = []
    private var heights: [CGFloat] = []
    private var laidOut = false
    private var moveCount = 0
    private let fadeMask = CAGradientLayer()
    private let indicatorTrack = CALayer()
    private let indicatorThumb = CALayer()

    init(model: ImmersiveLyricsModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        fadeMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fadeMask.locations = [0, 0.09, 0.86, 1]
        layer?.mask = fadeMask
        for capsule in [indicatorTrack, indicatorThumb] {
            capsule.cornerRadius = 2.5
            capsule.opacity = 0
            capsule.zPosition = 10
            layer?.addSublayer(capsule)
        }
        indicatorTrack.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        indicatorThumb.backgroundColor = NSColor.white.withAlphaComponent(0.75).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Wider than the column so the hover highlight, which reaches left
        // of the text, is not cut off.
        fadeMask.frame = bounds.insetBy(dx: -200, dy: 0)
        CATransaction.commit()
        relayout(animated: false, cascadeFrom: nil)
    }

    func update(_ new: LyricsColumnState, animated: Bool) {
        guard new != state else { return }
        let old = state
        state = new

        if old?.items.map(\.id) != new.items.map(\.id) || old?.metrics != new.metrics {
            rebuildRows(new)
        } else {
            refreshContent(new)
        }
        let activeChanged = old?.activeIndex != new.activeIndex
        let scrollModeChanged = old?.isUserScrolling != new.isUserScrolling
        applyVisuals(new, animated: laidOut, cascade: activeChanged)
        relayout(
            animated: laidOut && (activeChanged || scrollModeChanged || animated || old?.showTranslation != new.showTranslation),
            cascadeFrom: activeChanged ? new.activeIndex : nil,
            slow: scrollModeChanged || (animated && !activeChanged)
        )
        if !laidOut, !rows.isEmpty, bounds.height > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.laidOut = true }
        }
    }

    // MARK: Rows

    private func rebuildRows(_ state: LyricsColumnState) {
        rows.forEach { $0.removeFromSuperview() }
        rows = state.items.map { item in
            let row = LyricRowContainer()
            row.onHeightChange = { [weak self, weak row] height in
                guard let self, let row, let index = self.rows.firstIndex(where: { $0 === row }) else { return }
                self.setHeight(height, at: index)
            }
            addSubview(row)
            return row
        }
        heights = Array(repeating: 0, count: rows.count)
        refreshContent(state)
    }

    private func refreshContent(_ state: LyricsColumnState) {
        for (index, item) in state.items.enumerated() where rows.indices.contains(index) {
            let isActive = state.isSynced && state.activeIndex == item.id
            let content = LyricRowContent(
                model: model,
                item: item,
                isActive: isActive,
                metrics: state.metrics,
                isSynced: state.isSynced,
                showTranslation: state.showTranslation,
                hasExactWordTiming: state.hasExactWordTiming,
                // Only the current line plays, so play/pause redraws one row.
                isPlaying: isActive && state.isPlaying
            )
            if rows[index].setContent(content, width: rowWidth(state.metrics)) {
                heights[index] = rows[index].measuredHeight
            }
        }
    }

    private func setHeight(_ height: CGFloat, at index: Int) {
        guard heights.indices.contains(index), abs(heights[index] - height) > 0.5 else { return }
        heights[index] = height
        relayout(animated: laidOut, cascadeFrom: nil)
    }

    private func rowWidth(_ metrics: LyricsMetrics) -> CGFloat {
        metrics.width + metrics.hoverPaddingH * 2
    }

    // MARK: Layout

    private func tops(_ metrics: LyricsMetrics) -> [CGFloat] {
        var tops: [CGFloat] = []
        tops.reserveCapacity(heights.count + 1)
        var y: CGFloat = 0
        for height in heights {
            tops.append(y)
            y += height + (height > 1 ? metrics.itemSpacing : 0)
        }
        tops.append(y)
        return tops
    }

    private func relayout(animated: Bool, cascadeFrom active: Int?, slow: Bool = false) {
        guard let state, !rows.isEmpty, bounds.height > 0 else { return }
        let metrics = state.metrics
        let tops = tops(metrics)
        let activeIndex = min(max(state.activeIndex ?? 0, 0), rows.count - 1)
        let base = state.isSynced
            ? bounds.height * state.anchorFraction - tops[activeIndex]
            : bounds.height * 0.12
        let now = CACurrentMediaTime()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, row) in rows.enumerated() {
            let frame = CGRect(
                x: -metrics.hoverPaddingH,
                y: (base + tops[index] + state.manualScrollOffset).rounded(),
                width: rowWidth(metrics),
                height: max(heights[index], 0)
            )
            let delta = row.frame.minY - frame.minY
            let wasPlaced = row.frame != .zero
            row.frame = frame
            guard animated, wasPlaced, abs(delta) > 0.5, !row.isHidden,
                  frame.maxY > -bounds.height, frame.minY < bounds.height * 2,
                  let layer = row.layer else { continue }
            let distance = active.map { index - $0 } ?? 0
            let delay = active != nil && distance >= -1 ? min(Double(distance + 1) * 0.035, 0.25) : 0
            let spring = Self.spring(keyPath: "position.y", slow: slow)
            spring.fromValue = delta
            spring.toValue = 0
            spring.isAdditive = true
            spring.beginTime = now + delay
            spring.fillMode = .backwards
            // Unique keys let a new move stack on one still settling, so
            // fast line changes stay smooth instead of jumping.
            moveCount &+= 1
            layer.add(spring, forKey: "move\(moveCount)")
        }
        CATransaction.commit()

        let total = tops.last.map { $0 + metrics.fontSize * 2 } ?? 0
        model.scrollLimit = -(total) ... max(bounds.height * 0.6, total)
        updateIndicator(state, activeTop: tops[activeIndex], total: tops.last ?? 0)
    }

    /// SwiftUI's spring(response: 0.52, dampingFraction: 0.9); a softer one
    /// (0.7, 0.86) when manual scrolling ends.
    static func spring(keyPath: String, slow: Bool = false) -> CASpringAnimation {
        let response = slow ? 0.7 : 0.52
        let damping = slow ? 0.86 : 0.9
        let animation = CASpringAnimation(keyPath: keyPath)
        let omega = 2 * Double.pi / response
        animation.mass = 1
        animation.stiffness = omega * omega
        animation.damping = 2 * damping * omega
        animation.duration = animation.settlingDuration
        return animation
    }

    // MARK: Row visuals

    private func applyVisuals(_ state: LyricsColumnState, animated: Bool, cascade: Bool) {
        let active = state.activeIndex ?? 0
        let now = CACurrentMediaTime()
        for (index, row) in rows.enumerated() {
            let distance = state.isSynced ? index - active : 0
            let unfocused = state.isUserScrolling || !state.isSynced
            var visual = LyricRowContainer.Visual.plain
            if case .line = state.items[index].kind {
                if !state.isSynced {
                    visual.opacity = 0.92
                } else if state.isUserScrolling {
                    visual.opacity = 0.42
                } else {
                    visual.opacity = abs(distance) > 7 ? 0 : 1
                }
                if !unfocused, distance != 0 {
                    let steps = CGFloat(min(abs(distance), 6))
                    visual.blur = min(1.4 + (steps - 1) * 1.0, 6) * (state.metrics.fontSize / 36)
                    visual.scale = 0.97
                }
            }
            // Rows well past the faded-out ones are hidden, so the render
            // server skips them; when they come back they fade in from 0.
            let hidden = state.isSynced && !state.isUserScrolling && abs(distance) > 9
            let delay = cascade && distance >= -1 ? min(Double(distance + 1) * 0.035, 0.25) : 0
            row.apply(visual, hidden: hidden, animated: animated, beginTime: now + delay)
        }
    }

    // MARK: Scroll indicator

    private func updateIndicator(_ state: LyricsColumnState, activeTop: CGFloat, total: CGFloat) {
        let visible = state.isUserScrolling && total > 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        if visible {
            CATransaction.setDisableActions(indicatorTrack.opacity > 0)
            let viewport = bounds.height
            let track = viewport * 0.7
            let thumb = max(36, track * min(1, viewport / (total + viewport)))
            let fraction = min(max((activeTop - state.manualScrollOffset) / total, 0), 1)
            let x = bounds.width - 5
            indicatorTrack.frame = CGRect(x: x, y: viewport * 0.14, width: 5, height: track)
            indicatorThumb.frame = CGRect(x: x, y: viewport * 0.14 + (track - thumb) * fraction, width: 5, height: thumb)
        }
        CATransaction.commit()
        let opacity: Float = visible ? 1 : 0
        if indicatorTrack.opacity != opacity {
            indicatorTrack.opacity = opacity
            indicatorThumb.opacity = opacity
        }
    }
}

/// One row: a hosting view for its SwiftUI content inside a layer whose
/// opacity, blur and scale Core Animation plays.
final class LyricRowContainer: NSView {
    struct Visual: Equatable {
        var opacity: CGFloat
        var blur: CGFloat
        var scale: CGFloat
        static let plain = Visual(opacity: 1, blur: 0, scale: 1)
    }

    private let hosting: NSHostingView<LyricRowContentView>
    private(set) var content: LyricRowContent?
    private(set) var visual = Visual.plain
    private(set) var measuredHeight: CGFloat = 0
    var onHeightChange: ((CGFloat) -> Void)?

    init() {
        hosting = NSHostingView(rootView: LyricRowContentView(content: nil, onHeight: { _ in }))
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Faded-out rows don't take clicks or hover, as in SwiftUI.
    override func hitTest(_ point: NSPoint) -> NSView? {
        visual.opacity < 0.05 || isHidden ? nil : super.hitTest(point)
    }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        updateScaleTransform(animated: false, beginTime: 0)
    }

    /// Returns true when the content changed and was measured again.
    @discardableResult
    func setContent(_ content: LyricRowContent, width: CGFloat) -> Bool {
        guard content != self.content else { return false }
        self.content = content
        hosting.rootView = LyricRowContentView(content: content, onHeight: { [weak self] height in
            guard let self, abs(self.measuredHeight - height) > 0.5 else { return }
            self.measuredHeight = height
            self.onHeightChange?(height)
        })
        if hosting.frame.width != width {
            hosting.frame.size.width = width
        }
        measuredHeight = hosting.fittingSize.height
        return true
    }

    func apply(_ new: Visual, hidden: Bool, animated: Bool, beginTime: CFTimeInterval) {
        if isHidden != hidden { isHidden = hidden }
        guard new != visual, let layer else { return }
        let old = visual
        visual = new
        let animate = animated && !hidden

        if old.opacity != new.opacity {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = Float(new.opacity)
            CATransaction.commit()
            if animate {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = (layer.presentation()?.opacity).map { CGFloat($0) } ?? old.opacity
                fade.toValue = new.opacity
                fade.duration = 0.45
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                fade.beginTime = beginTime
                fade.fillMode = .backwards
                layer.add(fade, forKey: "opacity")
            }
        }

        if old.blur != new.blur {
            setBlur(from: old.blur, to: new.blur, animated: animate, beginTime: beginTime)
        }
        if old.scale != new.scale {
            updateScaleTransform(animated: animate, beginTime: beginTime, from: old.scale)
        }
    }

    // MARK: Blur

    private static let blurName = "rowBlur"
    private var blurRemoval: DispatchWorkItem?

    private func setBlur(from old: CGFloat, to new: CGFloat, animated: Bool, beginTime: CFTimeInterval) {
        guard let layer else { return }
        blurRemoval?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layer.filters?.isEmpty ?? true {
            guard let filter = CIFilter(name: "CIGaussianBlur") else { CATransaction.commit(); return }
            filter.name = Self.blurName
            filter.setValue(animated ? old : new, forKey: kCIInputRadiusKey)
            layer.filters = [filter]
        }
        layer.setValue(new, forKeyPath: "filters.\(Self.blurName).inputRadius")
        CATransaction.commit()

        if animated {
            let animation = CABasicAnimation(keyPath: "filters.\(Self.blurName).inputRadius")
            animation.fromValue = old
            animation.toValue = new
            animation.duration = 0.45
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animation.beginTime = beginTime
            animation.fillMode = .backwards
            layer.add(animation, forKey: "blur")
        }
        // An unblurred row, such as the current line, drops the filter so
        // it is not drawn off screen every frame.
        if new == 0 {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.visual.blur == 0 else { return }
                self.layer?.filters = nil
            }
            blurRemoval = work
            let wait = animated ? max(0, beginTime - CACurrentMediaTime()) + 0.5 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
        }
    }

    // MARK: Scale

    /// Scales the row about its leading edge's vertical centre.
    private func scaleTransform(_ scale: CGFloat) -> CATransform3D {
        guard scale != 1, let layer else { return CATransform3DIdentity }
        let anchor = CGPoint(x: layer.anchorPoint.x * bounds.width, y: layer.anchorPoint.y * bounds.height)
        let pivot = CGPoint(x: 0, y: bounds.height / 2)
        var transform = CATransform3DMakeTranslation(pivot.x - anchor.x, pivot.y - anchor.y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, anchor.x - pivot.x, anchor.y - pivot.y, 0)
    }

    private func updateScaleTransform(animated: Bool, beginTime: CFTimeInterval, from old: CGFloat? = nil) {
        guard let layer else { return }
        let target = scaleTransform(visual.scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = target
        CATransaction.commit()
        guard animated, let old else { return }
        let animation = LyricsColumnView.spring(keyPath: "sublayerTransform")
        animation.fromValue = NSValue(caTransform3D: layer.presentation()?.sublayerTransform ?? scaleTransform(old))
        animation.toValue = NSValue(caTransform3D: target)
        animation.beginTime = beginTime
        animation.fillMode = .backwards
        layer.add(animation, forKey: "scale")
    }
}

/// Everything a row's SwiftUI content depends on.
struct LyricRowContent: Equatable {
    let model: ImmersiveLyricsModel
    let item: LyricDisplayItem
    let isActive: Bool
    let metrics: LyricsMetrics
    let isSynced: Bool
    let showTranslation: Bool
    let hasExactWordTiming: Bool
    let isPlaying: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.item == rhs.item && lhs.isActive == rhs.isActive
            && lhs.metrics == rhs.metrics && lhs.isSynced == rhs.isSynced
            && lhs.showTranslation == rhs.showTranslation
            && lhs.hasExactWordTiming == rhs.hasExactWordTiming && lhs.isPlaying == rhs.isPlaying
    }
}

struct LyricRowContentView: View {
    let content: LyricRowContent?
    let onHeight: (CGFloat) -> Void

    var body: some View {
        if let content {
            row(content)
                .frame(width: content.metrics.width + content.metrics.hoverPaddingH * 2, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { onHeight(proxy.size.height) }
                            .onChange(of: proxy.size.height) { onHeight($0) }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func row(_ content: LyricRowContent) -> some View {
        switch content.item.kind {
        case .line(let line):
            LyricRowView(
                model: content.model,
                item: content.item,
                line: line,
                isActive: content.isActive,
                metrics: content.metrics,
                isSynced: content.isSynced,
                showTranslation: content.showTranslation,
                hasExactWordTiming: content.hasExactWordTiming,
                isPlaying: content.isPlaying
            )
        case .interlude:
            InterludeRowView(
                model: content.model,
                item: content.item,
                isActive: content.isActive,
                metrics: content.metrics,
                isPlaying: content.isPlaying
            )
        }
    }
}

// MARK: - Lyric row

/// A lyric line's content. It does not observe the model: it gets plain
/// values, and its hosting view is only given new ones when they change.
/// Position, scale, blur and fade are the column's Core Animation layers.
private struct LyricRowView: View, Equatable {
    let model: ImmersiveLyricsModel
    let item: LyricDisplayItem
    let line: LyricLine
    let isActive: Bool
    let metrics: LyricsMetrics
    let isSynced: Bool
    let showTranslation: Bool
    let hasExactWordTiming: Bool
    let isPlaying: Bool

    @State private var hovering = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.item == rhs.item && lhs.isActive == rhs.isActive
            && lhs.metrics == rhs.metrics && lhs.isSynced == rhs.isSynced
            && lhs.showTranslation == rhs.showTranslation
            && lhs.hasExactWordTiming == rhs.hasExactWordTiming && lhs.isPlaying == rhs.isPlaying
    }

    private var wordTimed: Bool { hasExactWordTiming && !line.words.isEmpty }

    private var translation: String? {
        guard showTranslation, let value = line.translation, !value.isEmpty else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.translationSize * 0.3) {
            if isActive && wordTimed {
                // Core Animation plays the word sweep; see KaraokeLayerViews.
                KaraokeLine(
                    model: model,
                    groups: WordGrouping.groups(for: line, item: item, wordTimed: true),
                    metrics: metrics,
                    isPlaying: isPlaying
                )
            } else {
                WordFlowView(
                    line: line,
                    item: item,
                    position: 0,
                    exactTiming: wordTimed,
                    isActive: isActive,
                    metrics: metrics,
                    staticBright: !isSynced
                )
                // Rasterise the words once, so the row's scale and blur
                // animations as lines change never make the text draw again.
                // Only this branch: the karaoke line above is an AppKit view,
                // which SwiftUI can't put in a drawing group (it draws a red
                // "not supported" placeholder instead, which showed on the
                // lyrics while that view faded out after its line). The
                // margin keeps lifted or glowing words from being clipped.
                .padding(metrics.fontSize * 0.25)
                .drawingGroup()
                .padding(-metrics.fontSize * 0.25)
            }

            if let translation {
                Text(translation)
                    .font(.system(size: metrics.translationSize, weight: .bold))
                    .foregroundStyle(Color.white.opacity(isActive ? 0.72 : (isSynced ? 0.3 : 0.6)))
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeOut(duration: 0.45), value: isActive)
            }
        }
        .padding(.horizontal, metrics.hoverPaddingH)
        .padding(.vertical, metrics.hoverPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.fontSize * 0.3, style: .continuous)
                .fill(Color.white.opacity(hovering && isSynced ? 0.09 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.18)) { hovering = inside }
        }
        .onTapGesture {
            guard isSynced else { return }
            model.seek(to: item.start)
        }
        .contextMenu {
            Button("Edit Translation…") { model.openTranslationEditor(focusing: line.text) }
            Divider()
            Button("Copy Lyric") { Self.copy(line.text) }
            if let value = line.translation, !value.isEmpty {
                Button("Copy Translation") { Self.copy(value) }
            }
            if isSynced {
                Button("Play from Here") { model.seek(to: item.start) }
            }
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Word-level highlighting

struct SyllableToken: Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

enum WordGrouping {
    /// Groups syllables into wrap-able words: Apple's TTML spans can be
    /// syllables ("dan" + "se,") that must stay on one row.
    static func groups(for line: LyricLine, item: LyricDisplayItem, wordTimed: Bool) -> [[SyllableToken]] {
        let source: [SyllableToken]
        if wordTimed, !line.words.isEmpty {
            source = line.words.map { SyllableToken(text: $0.text, start: $0.start, end: $0.end) }
        } else {
            source = [SyllableToken(text: line.text, start: item.start, end: item.end)]
        }

        // Split every token at whitespace so lines can wrap between words.
        // Apple's TTML puts the space before a word (" mon"); it is moved to
        // the end of the previous word so wrapped rows stay flush left.
        var groups: [[SyllableToken]] = []
        var current: [SyllableToken] = []
        func closeGroup() {
            if !current.isEmpty { groups.append(current) }
            current = []
        }
        for token in source {
            let characters = Array(token.text)
            let count = Double(max(characters.count, 1))
            let span = token.end - token.start
            var buffer = ""
            var bufferStart = 0
            func emit(through end: Int) {
                guard !buffer.isEmpty else { return }
                current.append(SyllableToken(
                    text: buffer,
                    start: token.start + span * Double(bufferStart) / count,
                    end: token.start + span * Double(end) / count
                ))
                buffer = ""
            }
            for (index, character) in characters.enumerated() {
                if character.isWhitespace {
                    if buffer.isEmpty {
                        if let last = current.popLast() {
                            let text = last.text.last?.isWhitespace == true ? last.text : last.text + " "
                            current.append(SyllableToken(text: text, start: last.start, end: last.end))
                        }
                    } else {
                        buffer.append(" ")
                        emit(through: index + 1)
                    }
                    closeGroup()
                    bufferStart = index + 1
                } else {
                    if buffer.isEmpty { bufferStart = index }
                    buffer.append(character)
                    if containsCJK(String(character)) {
                        emit(through: index + 1)
                        closeGroup()
                        bufferStart = index + 1
                    }
                }
            }
            emit(through: characters.count)
        }
        closeGroup()
        return groups
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }
}

private struct WordFlowView: View {
    let line: LyricLine
    let item: LyricDisplayItem
    let position: TimeInterval
    let exactTiming: Bool
    let isActive: Bool
    let metrics: LyricsMetrics
    var staticBright = false

    var body: some View {
        let groups = WordGrouping.groups(for: line, item: item, wordTimed: exactTiming)
        LyricFlowLayout(rowSpacing: metrics.rowSpacing) {
            ForEach(groups.indices, id: \.self) { index in
                HStack(spacing: 0) {
                    ForEach(groups[index].indices, id: \.self) { tokenIndex in
                        let token = groups[index][tokenIndex]
                        SyllableView(
                            text: token.text,
                            progress: progress(for: token),
                            isActive: isActive,
                            staticBright: staticBright,
                            emphasis: emphasis(for: token),
                            metrics: metrics
                        )
                    }
                }
                .fixedSize()
            }
        }
    }

    private func progress(for token: SyllableToken) -> CGFloat {
        guard isActive else { return staticBright ? 1 : 0 }
        guard exactTiming else {
            // Line-timed lyrics light up as a whole, like Music.app.
            return 1
        }
        let duration = max(token.end - token.start, 0.05)
        return CGFloat(min(max((position - token.start) / duration, 0), 1))
    }

    /// Long, held words glow and swell slightly while they are sung.
    private func emphasis(for token: SyllableToken) -> CGFloat {
        guard isActive, exactTiming else { return 0 }
        let duration = token.end - token.start
        let letters = token.text.trimmingCharacters(in: .whitespaces).count
        guard duration >= 1.0, letters > 0, letters <= 9 else { return 0 }
        let p = (position - token.start) / duration
        guard p > 0, p < 1.25 else { return 0 }
        return CGFloat(sin(min(p, 1) * .pi)) * CGFloat(min(1, (duration - 0.8) / 1.2))
    }
}

private struct SyllableView: View {
    let text: String
    let progress: CGFloat
    let isActive: Bool
    let staticBright: Bool
    let emphasis: CGFloat
    let metrics: LyricsMetrics

    private var font: Font { .system(size: metrics.fontSize, weight: .bold) }

    var body: some View {
        let eased = progress * progress * (3 - 2 * progress)
        ZStack(alignment: .leading) {
            Text(text)
                .font(font)
                .foregroundStyle(Color.white.opacity(staticBright ? 0 : 0.34))
            Text(text)
                .font(font)
                .foregroundStyle(Color.white)
                .mask(alignment: .leading) { sweepMask }
                .shadow(color: .white.opacity(Double(emphasis) * 0.7), radius: emphasis > 0.01 ? metrics.fontSize * 0.2 : 0)
                .opacity(isActive || staticBright ? 1 : 0)
                .animation(.easeOut(duration: 0.5), value: isActive)
        }
        .fixedSize()
        .scaleEffect(1 + emphasis * 0.045, anchor: .bottom)
        .offset(y: isActive ? -metrics.liftDistance * eased : 0)
        .animation(isActive ? nil : .spring(response: 0.5, dampingFraction: 0.9), value: isActive)
    }

    private var sweepMask: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fade = metrics.fadeWidth
            let x = (width + fade) * progress
            HStack(spacing: 0) {
                Rectangle().frame(width: max(0, x - fade))
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: fade)
                Spacer(minLength: 0)
            }
            .frame(width: width + fade, alignment: .leading)
        }
    }
}

/// Wraps word groups onto rows, left aligned.
private struct LyricFlowLayout: Layout {
    var rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + rowSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + rowSpacing
                x = 0
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Interlude dots

private struct InterludeRowView: View, Equatable {
    let model: ImmersiveLyricsModel
    let item: LyricDisplayItem
    let isActive: Bool
    let metrics: LyricsMetrics
    let isPlaying: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.item == rhs.item && lhs.isActive == rhs.isActive
            && lhs.metrics == rhs.metrics && lhs.isPlaying == rhs.isPlaying
    }

    var body: some View {
        Group {
            if isActive {
                InterludeDots(model: model, start: item.start, end: item.end, metrics: metrics, isPlaying: isPlaying)
                    .frame(width: metrics.dotSize * 4.5, height: metrics.dotSize * 1.6, alignment: .leading)
            } else {
                dots(position: nil)
            }
        }
        .padding(.horizontal, metrics.hoverPaddingH)
        .padding(.vertical, isActive ? metrics.hoverPaddingV : 0)
        .frame(height: isActive ? metrics.dotSize * 1.6 + metrics.hoverPaddingV * 2 : 0, alignment: .leading)
        .clipped()
        .animation(.spring(response: 0.55, dampingFraction: 0.85), value: isActive)
    }

    private func dots(position: TimeInterval?) -> some View {
        let length = max(item.end - item.start, 0.5)
        let fillDuration = max(length - 0.75, 0.25)
        let elapsed = (position ?? item.start) - item.start
        let fill = min(max(elapsed / fillDuration, 0), 1)
        // Breathe while waiting, swell then vanish just before the next line.
        let breathe = 1 + 0.07 * sin(elapsed * 2 * .pi / 2.4)
        let toEnd = item.end - (position ?? item.start)
        var scale = breathe
        var opacity = 1.0
        if position == nil {
            scale = 0.6
            opacity = 0
        } else if toEnd < 0.75 {
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

        return HStack(spacing: metrics.dotSize * 0.62) {
            ForEach(0..<3, id: \.self) { index in
                let dotFill = min(max(fill * 3 - Double(index), 0), 1)
                Circle()
                    .fill(Color.white.opacity(0.3 + 0.7 * dotFill))
                    .frame(width: metrics.dotSize, height: metrics.dotSize)
            }
        }
        .scaleEffect(scale, anchor: .leading)
        .opacity(opacity)
        .frame(height: metrics.dotSize * 1.6, alignment: .center)
    }
}
