import Foundation
import UniformTypeIdentifiers

/// File formats supported by lyrics export.
enum LyricsExportFormat: Int, CaseIterable, Sendable {
    /// Standard line-timed LRC.
    case lrc
    /// Enhanced LRC with inline `<mm:ss.xx>` word timestamps.
    case enhancedLRC
    /// SubRip subtitles.
    case srt
    /// Plain text without timestamps.
    case plainText

    var title: String {
        switch self {
        case .lrc: return "LRC（逐行）"
        case .enhancedLRC: return "LRC（逐字）"
        case .srt: return "SRT 字幕"
        case .plainText: return "纯文本"
        }
    }

    var fileExtension: String {
        switch self {
        case .lrc, .enhancedLRC: return "lrc"
        case .srt: return "srt"
        case .plainText: return "txt"
        }
    }

    var contentType: UTType {
        switch self {
        case .plainText: return .plainText
        default: return UTType(filenameExtension: fileExtension, conformingTo: .plainText) ?? .plainText
        }
    }

    /// Whether the format needs line timestamps.
    var requiresSync: Bool { self != .plainText }

    /// Whether the format needs per-word timings.
    var requiresWordTiming: Bool { self == .enhancedLRC }

    func isAvailable(for lyrics: LyricsDocument) -> Bool {
        if requiresWordTiming { return lyrics.isSynced && lyrics.hasKaraoke }
        if requiresSync { return lyrics.isSynced && !lyrics.lines.isEmpty }
        return !lyrics.lines.isEmpty || !(lyrics.plainText ?? "").isEmpty
    }
}

struct LyricsExportOptions: Equatable, Sendable {
    var includeTranslation = true
    var includeTransliteration = false
}

enum LyricsExporter {
    static func export(
        _ lyrics: LyricsDocument,
        track: TrackInfo?,
        format: LyricsExportFormat,
        options: LyricsExportOptions = LyricsExportOptions()
    ) -> String {
        switch format {
        case .lrc: return lrc(lyrics, track: track, options: options, wordLevel: false)
        case .enhancedLRC: return lrc(lyrics, track: track, options: options, wordLevel: true)
        case .srt: return srt(lyrics, track: track, options: options)
        case .plainText: return plainText(lyrics, track: track, options: options)
        }
    }

    /// A filesystem-safe default filename such as `Artist - Title.lrc`.
    static func suggestedFilename(track: TrackInfo?, format: LyricsExportFormat) -> String {
        var base = "Lyrics"
        if let track, !track.title.isEmpty {
            base = track.artist.isEmpty ? track.title : "\(track.artist) - \(track.title)"
        }
        let forbidden = CharacterSet(charactersIn: "/:\\\0")
        let cleaned = base.unicodeScalars
            .map { forbidden.contains($0) ? "_" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? "Lyrics" : cleaned).\(format.fileExtension)"
    }

    // MARK: - LRC

    private static func lrc(
        _ lyrics: LyricsDocument,
        track: TrackInfo?,
        options: LyricsExportOptions,
        wordLevel: Bool
    ) -> String {
        var output: [String] = []
        if let track {
            if !track.title.isEmpty { output.append("[ti:\(tagValue(track.title))]") }
            if !track.artist.isEmpty { output.append("[ar:\(tagValue(track.artist))]") }
            if !track.album.isEmpty { output.append("[al:\(tagValue(track.album))]") }
            if track.duration > 0 { output.append("[length:\(lengthTag(track.duration))]") }
        }
        output.append("[re:Apple Music Lyrics]")
        output.append("")

        for line in lyrics.lines {
            let stamp = "[\(lrcTimestamp(line.time))]"
            if wordLevel, !line.words.isEmpty {
                var body = ""
                for word in line.words {
                    body += "<\(lrcTimestamp(word.start))>\(singleLine(word.text))"
                }
                body += "<\(lrcTimestamp(line.endTime))>"
                output.append(stamp + body)
            } else {
                output.append(stamp + singleLine(line.text))
            }
            // Secondary lines share the timestamp, which most players render
            // underneath the original line.
            for extra in secondaryLines(of: line, options: options) {
                output.append(stamp + extra)
            }
        }
        return output.joined(separator: "\n") + "\n"
    }

    // MARK: - SRT

    private static func srt(
        _ lyrics: LyricsDocument,
        track: TrackInfo?,
        options: LyricsExportOptions
    ) -> String {
        let lines = lyrics.lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        var cues: [String] = []
        for (offset, line) in lines.enumerated() {
            let start = line.time
            let next = lines.indices.contains(offset + 1) ? lines[offset + 1].time : nil
            var end = line.endTime > start ? line.endTime : (next ?? start + 4)
            if let next { end = min(end, next) }
            if let duration = track?.duration, duration > start { end = min(end, duration) }
            if end <= start { end = start + 1 }

            var text = [singleLine(line.text)]
            text.append(contentsOf: secondaryLines(of: line, options: options))
            cues.append(
                "\(offset + 1)\n\(srtTimestamp(start)) --> \(srtTimestamp(end))\n"
                    + text.joined(separator: "\n")
            )
        }
        return cues.joined(separator: "\n\n") + (cues.isEmpty ? "" : "\n")
    }

    // MARK: - Plain text

    private static func plainText(
        _ lyrics: LyricsDocument,
        track: TrackInfo?,
        options: LyricsExportOptions
    ) -> String {
        var output: [String] = []
        if let track, !track.title.isEmpty {
            output.append(track.displayName)
            output.append("")
        }
        if lyrics.lines.isEmpty {
            output.append((lyrics.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            for line in lyrics.lines {
                output.append(singleLine(line.text))
                output.append(contentsOf: secondaryLines(of: line, options: options))
            }
        }
        return output.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    private static func secondaryLines(of line: LyricLine, options: LyricsExportOptions) -> [String] {
        var result: [String] = []
        if options.includeTransliteration, let value = nonEmpty(line.transliteration) {
            result.append(singleLine(value))
        }
        if options.includeTranslation, let value = nonEmpty(line.translation) {
            result.append(singleLine(value))
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func tagValue(_ text: String) -> String {
        singleLine(text).replacingOccurrences(of: "]", with: ")")
    }

    /// `mm:ss.xx` (centiseconds), minutes may exceed 59.
    static func lrcTimestamp(_ time: TimeInterval) -> String {
        let centis = Int((max(0, time) * 100).rounded())
        return String(format: "%02d:%02d.%02d", centis / 6000, (centis / 100) % 60, centis % 100)
    }

    /// `hh:mm:ss,mmm`.
    static func srtTimestamp(_ time: TimeInterval) -> String {
        let millis = Int((max(0, time) * 1000).rounded())
        return String(
            format: "%02d:%02d:%02d,%03d",
            millis / 3_600_000,
            (millis / 60_000) % 60,
            (millis / 1000) % 60,
            millis % 1000
        )
    }

    private static func lengthTag(_ duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
