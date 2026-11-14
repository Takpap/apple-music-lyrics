import Foundation

/// User-owned lyric and translation files stored in Application Support.
///
///     Lyrics/<Artist> - <Title>.lrc        timed lyrics (LRC)
///     Translations/<Artist> - <Title>.txt  `original = translation` rows
final class UserLyricsStore: @unchecked Sendable {
    let directoryURL: URL
    private let fileManager: FileManager

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directoryURL = baseDirectory
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/AppleMusicLyrics", isDirectory: true)
    }

    var lyricsDirectoryURL: URL { directoryURL.appendingPathComponent("Lyrics", isDirectory: true) }
    var translationsDirectoryURL: URL { directoryURL.appendingPathComponent("Translations", isDirectory: true) }

    // MARK: - Lyrics

    func userLyrics(for track: TrackInfo) -> LyricsDocument? {
        guard let url = existingFile(in: lyricsDirectoryURL, baseName: Self.baseName(for: track), ext: "lrc"),
              let text = Self.readText(url) else {
            return nil
        }
        let lines = LRCParser.parse(text)
        guard lines.contains(where: { !$0.text.isEmpty }) else { return nil }
        let hasWords = lines.contains { !$0.words.isEmpty }
        return LyricsDocument(
            lines: lines,
            plainText: lines.map(\.text).joined(separator: "\n"),
            source: "User file",
            isSynced: true,
            wordTiming: hasWords ? .exact : .none
        )
    }

    // MARK: - Translations

    /// Returns normalized original text -> translation.
    func translations(for track: TrackInfo) -> [String: String] {
        guard let url = existingFile(in: translationsDirectoryURL, baseName: Self.baseName(for: track), ext: "txt"),
              let text = Self.readText(url) else {
            return [:]
        }
        return Self.parseTranslations(text)
    }

    func applyingTranslations(_ map: [String: String], to doc: LyricsDocument) -> LyricsDocument {
        guard !map.isEmpty else { return doc }
        var normalizedMap: [String: String] = [:]
        for (key, value) in map {
            let translation = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = Self.normalizeKey(key)
            guard !normalized.isEmpty, !translation.isEmpty else { continue }
            normalizedMap[normalized] = translation
        }
        guard !normalizedMap.isEmpty else { return doc }

        let lines = doc.lines.map { line -> LyricLine in
            guard let translation = normalizedMap[Self.normalizeKey(line.text)] else { return line }
            return LyricLine(
                time: line.time,
                text: line.text,
                words: line.words,
                translation: translation,
                transliteration: line.transliteration
            )
        }
        return LyricsDocument(
            lines: lines,
            plainText: doc.plainText,
            source: doc.source,
            isSynced: doc.isSynced,
            wordTiming: doc.wordTiming,
            artworkURL: doc.artworkURL
        )
    }

    func translationTemplate(for track: TrackInfo, lyrics: LyricsDocument) -> String {
        var output = """
        # Translations for: \(track.displayName)
        # Format: one lyric per line as   original text = your translation
        # Lines starting with # are comments and are ignored.
        # Leave the part after "=" empty to keep the automatic translation.
        # Matching ignores letter case and extra spaces; only the first " = " splits a line.

        """
        var seen = Set<String>()
        for line in lyrics.lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(Self.normalizeKey(text)).inserted else { continue }
            output += "\(text) = \(line.translation ?? "")\n"
        }
        return output
    }

    func translationsFileURL(for track: TrackInfo) -> URL {
        let baseName = Self.baseName(for: track)
        return existingFile(in: translationsDirectoryURL, baseName: baseName, ext: "txt")
            ?? translationsDirectoryURL.appendingPathComponent("\(baseName).txt")
    }

    @discardableResult
    func ensureTranslationsFile(for track: TrackInfo, lyrics: LyricsDocument) throws -> URL {
        let url = translationsFileURL(for: track)
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try translationTemplate(for: track, lyrics: lyrics).write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Saves corrected translations for individual lines, keeping every other
    /// line of the file as it is. An empty translation clears the override, so
    /// the automatic (Apple or on-device) translation is used again.
    func setTranslations(_ changes: [(original: String, translation: String)], for track: TrackInfo) throws {
        let changes = changes.filter { !Self.normalizeKey($0.original).isEmpty }
        guard !changes.isEmpty else { return }
        let url = translationsFileURL(for: track)
        var lines: [String]
        if let existing = Self.readText(url) {
            lines = existing.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
        } else {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            lines = [
                "# Translations for: \(track.displayName)",
                "# Format: one lyric per line as   original text = your translation",
                "# Lines starting with # are comments. Leave the translation empty to use the automatic one.",
                ""
            ]
        }
        for change in changes {
            let original = change.original
                .split(whereSeparator: { $0.isNewline })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            let translation = change.translation
                .split(whereSeparator: { $0.isNewline })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            let key = Self.normalizeKey(original)
            let entry = "\(original) = \(translation)"
            if let index = lines.firstIndex(where: { Self.entryKey(of: $0) == key }) {
                lines[index] = entry
            } else {
                lines.append(entry)
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// The normalized original text of one `original = translation` row.
    private static func entryKey(of row: String) -> String? {
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        if let range = row.range(of: " = ") {
            return normalizeKey(String(row[..<range.lowerBound]))
        }
        if let equals = row.firstIndex(of: "=") {
            return normalizeKey(String(row[..<equals]))
        }
        return nil
    }

    // MARK: - Helpers

    static func baseName(for track: TrackInfo) -> String {
        let artist = sanitize(track.artist)
        let title = sanitize(track.title)
        return artist.isEmpty ? title : "\(artist) - \(title)"
    }

    static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed, lowercased, whitespace-collapsed.
    static func normalizeKey(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    static func parseTranslations(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let original: Substring
            let translation: Substring
            if let range = rawLine.range(of: " = ") {
                original = rawLine[..<range.lowerBound]
                translation = rawLine[range.upperBound...]
            } else if let equals = rawLine.firstIndex(of: "=") {
                original = rawLine[..<equals]
                translation = rawLine[rawLine.index(after: equals)...]
            } else {
                continue
            }
            let key = normalizeKey(String(original))
            let value = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Exact path first, then a case/Unicode-normalization-insensitive match
    /// against the directory listing.
    private func existingFile(in directory: URL, baseName: String, ext: String) -> URL? {
        let fileName = "\(baseName).\(ext)"
        let exact = directory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: exact.path) { return exact }

        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return nil }
        let wanted = Self.foldedFileName(fileName)
        return names
            .sorted()
            .first { Self.foldedFileName($0) == wanted }
            .map { directory.appendingPathComponent($0) }
    }

    private static func foldedFileName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
