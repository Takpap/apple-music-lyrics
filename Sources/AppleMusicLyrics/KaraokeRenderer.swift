import AppKit

/// Builds per-character / per-word highlighted attributed strings for karaoke display.
enum KaraokeRenderer {
    static func attributed(
        line: LyricLine,
        position: TimeInterval,
        font: NSFont,
        sungColor: NSColor,
        activeColor: NSColor,
        upcomingColor: NSColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]

        guard !line.words.isEmpty else {
            var attrs = base
            attrs[.foregroundColor] = position >= line.time ? sungColor : upcomingColor
            result.append(NSAttributedString(string: line.text, attributes: attrs))
            return result
        }

        for word in line.words {
            appendWord(
                word,
                position: position,
                into: result,
                base: base,
                sungColor: sungColor,
                activeColor: activeColor,
                upcomingColor: upcomingColor
            )
        }
        return result
    }

    private static func appendWord(
        _ word: LyricWord,
        position: TimeInterval,
        into result: NSMutableAttributedString,
        base: [NSAttributedString.Key: Any],
        sungColor: NSColor,
        activeColor: NSColor,
        upcomingColor: NSColor
    ) {
        let text = word.text
        guard !text.isEmpty else { return }

        if position >= word.end {
            var attrs = base
            attrs[.foregroundColor] = sungColor
            result.append(NSAttributedString(string: text, attributes: attrs))
            return
        }

        if position < word.start {
            var attrs = base
            attrs[.foregroundColor] = upcomingColor
            result.append(NSAttributedString(string: text, attributes: attrs))
            return
        }

        // Mid-word: paint a progressive fraction of grapheme clusters.
        let duration = max(0.04, word.end - word.start)
        let progress = min(1, max(0, (position - word.start) / duration))
        let clusters = Array(text)
        guard clusters.count > 1 else {
            var attrs = base
            attrs[.foregroundColor] = activeColor
            result.append(NSAttributedString(string: text, attributes: attrs))
            return
        }

        let sungCount = min(clusters.count, max(1, Int(ceil(progress * Double(clusters.count)))))
        let sungPart = String(clusters.prefix(sungCount))
        let restPart = String(clusters.suffix(clusters.count - sungCount))

        var sungAttrs = base
        sungAttrs[.foregroundColor] = activeColor
        result.append(NSAttributedString(string: sungPart, attributes: sungAttrs))

        if !restPart.isEmpty {
            var restAttrs = base
            restAttrs[.foregroundColor] = upcomingColor
            result.append(NSAttributedString(string: restPart, attributes: restAttrs))
        }
    }
}
