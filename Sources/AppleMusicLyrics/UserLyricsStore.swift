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
        var looseMap: [String: String] = [:]
        var coreMap: [String: String] = [:]
        for (key, value) in map {
            let translation = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = Self.normalizeKey(key)
            guard !normalized.isEmpty, !translation.isEmpty else { continue }
            normalizedMap[normalized] = translation
            let loose = Self.looseKey(key)
            if !loose.isEmpty, looseMap[loose] == nil { looseMap[loose] = translation }
            let core = Self.coreTokens(key).joined(separator: " ")
            if !core.isEmpty, coreMap[core] == nil { coreMap[core] = translation }
        }
        guard !normalizedMap.isEmpty else { return doc }
        let segments = coreMap.map { (tokens: $0.key.split(separator: " ").map(String.init), translation: $0.value) }

        var composed: [[String]: String?] = [:]
        let lines = doc.lines.map { line -> LyricLine in
            // Exact (case and spacing aside) first; then a looser match so a
            // file written against one lyrics source still fits another that
            // differs only in punctuation, apostrophes, accents or ad-libs;
            // last, a line one source merges from several the file lists
            // separately gets their translations joined.
            let core = Self.coreTokens(line.text)
            guard let translation = normalizedMap[Self.normalizeKey(line.text)]
                    ?? looseMap[Self.looseKey(line.text)]
                    ?? coreMap[core.joined(separator: " ")]
                    ?? { () -> String? in
                        if let cached = composed[core] { return cached }
                        let result = Self.composedTranslation(of: core, from: segments)
                        composed[core] = result
                        return result
                    }() else { return line }
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

    /// Letters and digits only, case- and accent-insensitive, single spaces.
    /// "Tu ne m’entends pas," and "tu ne m'entends pas" give the same key.
    static func looseKey(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result = ""
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.unicodeScalars.append(scalar)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "-" {
                pendingSpace = true
            }
        }
        return result
    }

    /// Sung fillers ignored when matching: "Une seule arme m'emprisonne, yeah"
    /// matches a file row without the "yeah".
    static let fillerWords: Set<String> = ["yeah", "yeh", "oh", "ohh", "ooh", "ah", "aah", "eh", "hey", "uh", "mmh", "mm", "hmm", "woah", "whoa", "ay", "ayy"]

    /// The loose key's words with parenthesised backing vocals and filler
    /// words removed.
    static func coreTokens(_ value: String) -> [String] {
        var stripped = ""
        var depth = 0
        for character in value {
            // Split elisions so "j'me" gives "j me", comparable to "je me".
            if character == "'" || character == "’" || character == "ʼ" { stripped.append(" "); continue }
            if character == "(" || character == "[" { depth += 1; stripped.append(" "); continue }
            if character == ")" || character == "]" { depth = max(0, depth - 1); stripped.append(" "); continue }
            if depth == 0 { stripped.append(character) }
        }
        // A line that is only a parenthesis keeps its words.
        let tokens = looseKey(stripped).split(separator: " ").map(String.init).filter { !fillerWords.contains($0) }
        if !tokens.isEmpty { return tokens }
        return looseKey(value).split(separator: " ").map(String.init).filter { !fillerWords.contains($0) }
    }

    /// Covers `tokens` with file rows, in order, and joins their
    /// translations. Rows may be reused (choruses) and, on lines of five or
    /// more words, may differ by about one word in five in total ("le
    /// jackpot" / "the jackpot", "j'me" / "je me"). Nil when no cover fits.
    static func composedTranslation(of tokens: [String], from segments: [(tokens: [String], translation: String)]) -> String? {
        let count = tokens.count
        guard count >= 2, !segments.isEmpty else { return nil }
        let budget = count >= 5 ? count / 5 : 0
        // best[i]: cheapest cover of tokens[i...] as (edits, rows, row, end).
        var best = [(edits: Int, rows: Int, segment: Int, end: Int)?](repeating: nil, count: count + 1)
        best[count] = (0, 0, -1, count)
        for start in stride(from: count - 1, through: 0, by: -1) {
            for (index, segment) in segments.enumerated() {
                let length = segment.tokens.count
                let lower = max(start + 1, start + length - budget)
                let upper = min(count, start + length + budget)
                guard lower <= upper else { continue }
                for end in lower...upper {
                    guard let rest = best[end], rest.edits <= budget else { continue }
                    let limit = budget - rest.edits
                    guard let edits = tokenDistance(tokens[start..<end], segment.tokens, limit: limit) else { continue }
                    let candidate = (edits: edits + rest.edits, rows: rest.rows + 1, segment: index, end: end)
                    if let current = best[start],
                       (current.edits, current.rows) <= (candidate.edits, candidate.rows) { continue }
                    best[start] = candidate
                }
            }
        }
        guard let first = best[0], first.edits <= budget else { return nil }
        var parts: [String] = []
        var position = 0
        while position < count, let step = best[position] {
            parts.append(segments[step.segment].translation)
            position = step.end
        }
        var result = parts[0]
        for part in parts.dropFirst() {
            if let last = result.last, !".,;:!?…—-".contains(last) { result += "," }
            result += " " + continuation(part)
        }
        return result
    }

    /// Word-level edit distance, or nil once it exceeds `limit`. An elided
    /// word matches its full form ("j" / "je", "c" / "ce").
    static func tokenDistance(_ a: ArraySlice<String>, _ b: [String], limit: Int) -> Int? {
        let a = Array(a)
        guard !a.isEmpty, !b.isEmpty, abs(a.count - b.count) <= limit else { return nil }
        func same(_ x: String, _ y: String) -> Bool {
            if x == y { return true }
            let (short, long) = x.count < y.count ? (x, y) : (y, x)
            return short.count == 1 && long.count <= 3 && long.hasPrefix(short)
        }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            var rowMin = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let substitution = previous[j - 1] + (same(a[i - 1], b[j - 1]) ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return nil }
            previous = current
        }
        let distance = previous[b.count]
        return distance <= limit ? distance : nil
    }

    /// Lowercases a continuation's capital ("That you're there" → "that
    /// you're there") but leaves "I", "I'm" and acronyms alone.
    private static func continuation(_ part: String) -> String {
        let characters = Array(part)
        guard characters.count >= 2, characters[0].isUppercase, characters[1].isLowercase else { return part }
        return characters[0].lowercased() + String(characters.dropFirst())
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
