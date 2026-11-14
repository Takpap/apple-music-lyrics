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

private struct ItemHeightKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Column

/// The right-hand lyrics column: every row is positioned absolutely and
/// springs to its new place with a small per-row delay, which produces the
/// cascading motion of Music.app's lyrics view.
struct ImmersiveLyricsColumn: View {
    @ObservedObject var model: ImmersiveLyricsModel
    let metrics: LyricsMetrics
    let anchorFraction: CGFloat

    @State private var heights: [Int: CGFloat] = [:]
    @State private var laidOut = false

    var body: some View {
        GeometryReader { geometry in
            let tops = topOffsets()
            let anchor = geometry.size.height * anchorFraction
            let active = model.activeIndex ?? 0
            let activeTop = tops.indices.contains(active) ? tops[active] : 0
            let base = model.isSynced ? anchor - activeTop : geometry.size.height * 0.12

            ZStack(alignment: .topLeading) {
                ForEach(model.items) { item in
                    let distance = model.isSynced ? item.id - (model.activeIndex ?? -1) : 0
                    let target = base + (tops.indices.contains(item.id) ? tops[item.id] : 0)
                    row(for: item, distance: distance)
                        .frame(width: metrics.width + metrics.hoverPaddingH * 2, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: ItemHeightKey.self, value: [item.id: proxy.size.height])
                            }
                        )
                        .offset(x: -metrics.hoverPaddingH, y: target)
                        .animation(laidOut ? rowAnimation(distance: distance) : nil, value: target)
                        .animation(.easeOut(duration: 0.35), value: model.isUserScrolling)
                        .offset(y: model.manualScrollOffset)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                scrollIndicator(viewport: geometry.size.height, activeTop: activeTop, total: tops.last ?? 0)
            }
            .onPreferenceChange(ItemHeightKey.self) { value in
                heights = value
                if !laidOut, value.count >= model.items.count {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { laidOut = true }
                }
            }
            .onAppear { publishScrollRange(viewport: geometry.size.height) }
            .onChange(of: heights) { _ in publishScrollRange(viewport: geometry.size.height) }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.09),
                    .init(color: .black, location: 0.86),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private func row(for item: LyricDisplayItem, distance: Int) -> some View {
        switch item.kind {
        case .line(let line):
            LyricRowView(
                model: model,
                item: item,
                line: line,
                distance: distance,
                metrics: metrics
            )
        case .interlude:
            InterludeRowView(
                model: model,
                item: item,
                isActive: distance == 0,
                metrics: metrics
            )
        }
    }

    /// Thin indicator on the right while the user scrolls, as in Music.app.
    @ViewBuilder
    private func scrollIndicator(viewport: CGFloat, activeTop: CGFloat, total: CGFloat) -> some View {
        if model.isUserScrolling, total > 0 {
            let track = viewport * 0.7
            let thumb = max(36, track * min(1, viewport / (total + viewport)))
            let current = activeTop - model.manualScrollOffset
            let fraction = min(max(current / total, 0), 1)
            ZStack(alignment: .top) {
                Capsule().fill(Color.white.opacity(0.12)).frame(width: 5, height: track)
                Capsule().fill(Color.white.opacity(0.75)).frame(width: 5, height: thumb)
                    .offset(y: (track - thumb) * fraction)
            }
            .padding(.top, viewport * 0.14)
            .transition(.opacity)
        }
    }

    private func topOffsets() -> [CGFloat] {
        var tops: [CGFloat] = []
        tops.reserveCapacity(model.items.count)
        var y: CGFloat = 0
        for item in model.items {
            tops.append(y)
            let height = heights[item.id] ?? (metrics.fontSize * 1.3 + metrics.hoverPaddingV * 2)
            y += height + (height > 1 ? metrics.itemSpacing : 0)
        }
        return tops
    }

    private func publishScrollRange(viewport: CGFloat) {
        let total = topOffsets().last.map { $0 + metrics.fontSize * 2 } ?? 0
        model.scrollLimit = -(total) ... max(viewport * 0.6, total)
    }

    /// Rows above the current line move first and later rows follow, about
    /// 45 ms apart, like Music.app.
    private func rowAnimation(distance: Int) -> Animation {
        let spring = Animation.spring(response: 0.62, dampingFraction: 0.84)
        guard distance >= -1 else { return spring }
        return spring.delay(min(Double(distance + 1) * 0.045, 0.4))
    }
}

// MARK: - Lyric row

private struct LyricRowView: View {
    @ObservedObject var model: ImmersiveLyricsModel
    let item: LyricDisplayItem
    let line: LyricLine
    let distance: Int
    let metrics: LyricsMetrics

    @State private var hovering = false

    private var isActive: Bool { model.isSynced && distance == 0 }
    private var unfocused: Bool { model.isUserScrolling || !model.isSynced }

    private var wordTimed: Bool { model.hasExactWordTiming && !line.words.isEmpty }

    private var blurRadius: CGFloat {
        guard !unfocused, distance != 0 else { return 0 }
        let steps = CGFloat(min(abs(distance), 6))
        return min(1.4 + (steps - 1) * 1.0, 6) * (metrics.fontSize / 36)
    }

    private var dimOpacity: Double {
        if !model.isSynced { return 0.92 }
        if model.isUserScrolling { return 0.42 }
        return abs(distance) > 7 ? 0.0 : 1
    }

    private var translation: String? {
        guard model.showTranslation, let value = line.translation, !value.isEmpty else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.translationSize * 0.3) {
            if isActive && wordTimed {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !model.isPlaying)) { _ in
                    WordFlowView(
                        line: line,
                        item: item,
                        position: model.position(),
                        exactTiming: true,
                        isActive: true,
                        metrics: metrics
                    )
                }
            } else {
                WordFlowView(
                    line: line,
                    item: item,
                    position: 0,
                    exactTiming: wordTimed,
                    isActive: isActive,
                    metrics: metrics,
                    staticBright: !model.isSynced
                )
            }

            if let translation {
                Text(translation)
                    .font(.system(size: metrics.translationSize, weight: .bold))
                    .foregroundStyle(Color.white.opacity(isActive ? 0.72 : (model.isSynced ? 0.3 : 0.6)))
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeOut(duration: 0.45), value: isActive)
            }
        }
        .padding(.horizontal, metrics.hoverPaddingH)
        .padding(.vertical, metrics.hoverPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.fontSize * 0.3, style: .continuous)
                .fill(Color.white.opacity(hovering && model.isSynced ? 0.09 : 0))
        )
        .scaleEffect(isActive || unfocused ? 1 : 0.97, anchor: .leading)
        .blur(radius: blurRadius)
        // Rasterise the row once: the window compositor then moves a plain
        // texture instead of re-running a blur filter on every frame.
        .drawingGroup()
        .opacity(dimOpacity)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.18)) { hovering = inside }
        }
        .onTapGesture {
            guard model.isSynced else { return }
            model.seek(to: item.start)
        }
        .contextMenu {
            Button("Edit Translation…") { model.openTranslationEditor(focusing: line.text) }
            Divider()
            Button("Copy Lyric") { Self.copy(line.text) }
            if let value = line.translation, !value.isEmpty {
                Button("Copy Translation") { Self.copy(value) }
            }
            if model.isSynced {
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

private struct InterludeRowView: View {
    @ObservedObject var model: ImmersiveLyricsModel
    let item: LyricDisplayItem
    let isActive: Bool
    let metrics: LyricsMetrics

    var body: some View {
        Group {
            if isActive {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !model.isPlaying)) { _ in
                    dots(position: model.position())
                }
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
