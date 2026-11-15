import Foundation

/// Parser for LRC lyric files, including multi-timestamp lines, `[offset:]`
/// metadata, duplicate-timestamp translations and enhanced (A2) word tags.
enum LRCParser {
    static func parse(_ text: String) -> [LyricLine] {
        var source = text
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
        let rawLines = source.components(separatedBy: .newlines)

        var offsetSeconds: TimeInterval = 0
        var entries: [Entry] = []

        for raw in rawLines {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var stamps: [TimeInterval] = []

            // Leading bracket tags: timestamps or metadata.
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let inner = rest[rest.index(after: rest.startIndex)..<close]
                if let time = timestamp(inner) {
                    stamps.append(time)
                } else if let value = metadataValue(inner, key: "offset") {
                    if let milliseconds = Double(value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")) {
                        offsetSeconds = milliseconds / 1000
                    }
                } else if stamps.isEmpty == false {
                    // A non-time tag after timestamps is part of the text.
                    break
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !stamps.isEmpty else { continue }

            let (segments, hasInlineTags) = inlineSegments(String(rest))
            for stamp in stamps {
                var entry = Entry(time: stamp, order: entries.count)
                if hasInlineTags {
                    entry.segments = segments.map { Segment(time: $0.time.map { $0 + (stamp - stamps[0]) }, text: $0.text) }
                    entry.text = segments.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                } else {
                    entry.text = String(rest).trimmingCharacters(in: .whitespaces)
                }
                entries.append(entry)
            }
        }

        // Apply offset: positive means lyrics appear earlier.
        if offsetSeconds != 0 {
            for index in entries.indices {
                entries[index].time -= offsetSeconds
                for s in entries[index].segments.indices {
                    entries[index].segments[s].time = entries[index].segments[s].time.map { $0 - offsetSeconds }
                }
            }
        }

        entries.sort { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }

        // Merge same-timestamp pairs: the second becomes the translation.
        var merged: [Entry] = []
        for entry in entries {
            if var previous = merged.last,
               previous.time == entry.time,
               previous.translation == nil,
               !previous.text.isEmpty,
               !entry.text.isEmpty {
                previous.translation = entry.text
                merged[merged.count - 1] = previous
            } else if let previous = merged.last,
                      previous.time == entry.time,
                      entry.text.isEmpty {
                continue
            } else {
                merged.append(entry)
            }
        }

        return merged.enumerated().map { index, entry in
            let nextTime = index + 1 < merged.count ? merged[index + 1].time : nil
            return entry.makeLine(nextLineTime: nextTime)
        }
    }

    // MARK: - Internals

    private struct Segment {
        var time: TimeInterval?
        var text: String
    }

    private struct Entry {
        var time: TimeInterval
        var order: Int
        var text = ""
        var segments: [Segment] = []
        var translation: String?

        func makeLine(nextLineTime: TimeInterval?) -> LyricLine {
            guard !segments.isEmpty else {
                return LyricLine(time: time, text: text, translation: translation)
            }
            var words: [LyricWord] = []
            for (index, segment) in segments.enumerated() {
                guard let start = segment.time ?? (index == 0 ? time : nil), !segment.text.isEmpty else { continue }
                var end: TimeInterval?
                if let following = segments[(index + 1)...].first(where: { $0.time != nil }) {
                    end = following.time
                }
                let resolvedEnd = end ?? nextLineTime ?? (start + 1)
                words.append(LyricWord(text: segment.text, start: start, end: max(resolvedEnd, start)))
            }
            return LyricLine(time: time, text: text, words: words, translation: translation)
        }
    }

    /// Splits `<mm:ss.xx>` tags out of the text. Text before the first tag
    /// has no explicit time (it starts at the line time).
    private static func inlineSegments(_ text: String) -> ([Segment], Bool) {
        var segments: [Segment] = []
        var currentTime: TimeInterval?
        var current = ""
        var sawTag = false
        var index = text.startIndex

        while index < text.endIndex {
            if text[index] == "<",
               let close = text[index...].firstIndex(of: ">"),
               let time = timestamp(text[text.index(after: index)..<close]) {
                if sawTag || !current.isEmpty {
                    segments.append(Segment(time: currentTime, text: current))
                }
                sawTag = true
                currentTime = time
                current = ""
                index = text.index(after: close)
            } else {
                current.append(text[index])
                index = text.index(after: index)
            }
        }
        if sawTag || !current.isEmpty {
            segments.append(Segment(time: currentTime, text: current))
        }
        return (segments, sawTag)
    }

    private static func metadataValue(_ inner: Substring, key: String) -> String? {
        guard let colon = inner.firstIndex(of: ":") else { return nil }
        let name = inner[inner.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard name == key else { return nil }
        return String(inner[inner.index(after: colon)...])
    }

    /// Parses `mm:ss`, `mm:ss.xx`, `mm:ss.xxx` (also `mm:ss:xx`).
    private static func timestamp(_ inner: Substring) -> TimeInterval? {
        let parts = inner.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = digits(parts[0]) else { return nil }
        var seconds: Double
        if parts.count == 2 {
            let secParts = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard secParts.count <= 2, let whole = digits(secParts[0]) else { return nil }
            seconds = Double(whole)
            if secParts.count == 2 {
                guard let fraction = fraction(secParts[1]) else { return nil }
                seconds += fraction
            }
        } else {
            guard let whole = digits(parts[1]), let fraction = fraction(parts[2]) else { return nil }
            seconds = Double(whole) + fraction
        }
        return Double(minutes) * 60 + seconds
    }

    private static func digits(_ value: Substring) -> Int? {
        guard !value.isEmpty, value.count <= 6, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(value)
    }

    private static func fraction(_ value: Substring) -> Double? {
        guard !value.isEmpty, value.count <= 6, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Double(value) else { return nil }
        return number / pow(10, Double(value.count))
    }
}
