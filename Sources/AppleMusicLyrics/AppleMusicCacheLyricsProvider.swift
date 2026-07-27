import Foundation

/// Reads the catalog responses already downloaded by Music.app. This provider
/// never uses Apple account credentials and never makes a network request.
final class AppleMusicCacheLyricsProvider: @unchecked Sendable {
    private let fileManager: FileManager
    private let cacheDirectory: URL
    private let databaseURL: URL
    private let maximumCandidates = 160

    init(
        fileManager: FileManager = .default,
        cacheDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        let root = cacheDirectory
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/com.apple.Music", isDirectory: true)
        self.cacheDirectory = root.appendingPathComponent("fsCachedData", isDirectory: true)
        self.databaseURL = root.appendingPathComponent("Cache.db")
    }

    func lyrics(for track: TrackInfo) -> LyricsDocument {
        var best: (score: Int, song: CatalogSong)?

        for candidate in candidates() {
            guard let data = candidate.data(),
                  let response = try? JSONDecoder().decode(CatalogResponse.self, from: data) else {
                continue
            }

            for song in response.data {
                let score = matchScore(song.attributes, track: track)
                guard score >= 80,
                      song.relationships?.syllableLyrics?.data.first?.attributes.ttmlLocalizations != nil else {
                    continue
                }
                if best == nil || score > best!.score {
                    best = (score, song)
                }
            }

            // Exact metadata plus duration is definitive; candidates are newest first.
            if best?.score ?? 0 >= 140 { break }
        }

        guard let song = best?.song,
              let rawTTML = song.relationships?.syllableLyrics?.data.first?.attributes.ttmlLocalizations,
              let ttml = localizedTTML(from: rawTTML),
              let parsed = try? AppleTTMLParser.parse(ttml),
              !parsed.lines.isEmpty else {
            return .empty
        }

        return LyricsDocument(
            lines: parsed.lines,
            plainText: parsed.lines.map(\.text).joined(separator: "\n"),
            source: "Apple Music",
            isSynced: true,
            wordTiming: parsed.wordTiming
        )
    }

    // MARK: - Cache index

    private func candidates() -> [CacheCandidate] {
        let indexed = indexedCandidates()
        var candidates = indexed
        var indexedPaths = Set(indexed.compactMap(\.fileURL))

        // The database is a private implementation detail. Always append recent
        // files as a fallback because an index can exist while containing stale
        // paths after a Music or macOS update.
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return candidates }

        let recentFiles = urls
            .filter { (try? $0.resourceValues(forKeys: keys).isRegularFile) == true }
            .sorted {
                let lhs = try? $0.resourceValues(forKeys: keys).contentModificationDate
                let rhs = try? $1.resourceValues(forKeys: keys).contentModificationDate
                return (lhs ?? .distantPast) > (rhs ?? .distantPast)
            }
            .prefix(maximumCandidates)
        for url in recentFiles where indexedPaths.insert(url).inserted {
            candidates.append(.file(url))
        }
        return candidates
    }

    private func indexedCandidates() -> [CacheCandidate] {
        guard fileManager.isReadableFile(atPath: databaseURL.path),
              fileManager.isExecutableFile(atPath: "/usr/bin/sqlite3") else {
            return []
        }

        let query = """
        SELECT d.isDataOnFS || char(9) || hex(d.receiver_data)
        FROM cfurl_cache_response r
        JOIN cfurl_cache_receiver_data d USING(entry_ID)
        WHERE r.request_key LIKE '%syllable-lyrics%'
        ORDER BY r.time_stamp DESC
        LIMIT \(maximumCandidates);
        """

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", databaseURL.path, query]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let raw = String(data: data, encoding: .utf8) else {
                return []
            }
            return raw.components(separatedBy: .newlines).compactMap { row in
                let fields = row.split(separator: "\t", maxSplits: 1).map(String.init)
                guard fields.count == 2, let payload = Data(hexEncoded: fields[1]) else {
                    return nil
                }
                if fields[0] == "1",
                   let name = String(data: payload, encoding: .utf8),
                   let url = cacheFileURL(named: name) {
                    return .file(url)
                }
                if fields[0] == "0" {
                    return .inline(payload)
                }
                return nil
            }
        } catch {
            return []
        }
    }

    private func cacheFileURL(named name: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        guard name.count == 36,
              name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        let url = cacheDirectory.appendingPathComponent(name, isDirectory: false)
        return fileManager.isReadableFile(atPath: url.path) ? url : nil
    }

    // MARK: - Matching

    private func matchScore(_ song: CatalogSongAttributes, track: TrackInfo) -> Int {
        let wantedTitle = normalized(track.title)
        let candidateTitle = normalized(song.name)
        guard !wantedTitle.isEmpty, !candidateTitle.isEmpty else { return 0 }

        var score = 0
        if candidateTitle == wantedTitle {
            score += 70
        } else if candidateTitle.contains(wantedTitle) || wantedTitle.contains(candidateTitle) {
            score += 35
        } else {
            return 0
        }

        let wantedArtist = normalized(track.artist)
        let candidateArtist = normalized(song.artistName)
        if !wantedArtist.isEmpty, !candidateArtist.isEmpty {
            if candidateArtist == wantedArtist {
                score += 40
            } else if candidateArtist.contains(wantedArtist) || wantedArtist.contains(candidateArtist) {
                score += 20
            } else {
                score -= 35
            }
        }

        if track.duration > 0, let duration = song.durationInMillis, duration > 0 {
            let difference = abs(Double(duration) / 1000 - track.duration)
            if difference <= 2 { score += 30 }
            else if difference <= 5 { score += 20 }
            else if difference <= 12 { score += 5 }
            else { score -= 30 }
        }

        let wantedAlbum = normalized(track.album)
        let candidateAlbum = normalized(song.albumName ?? "")
        if !wantedAlbum.isEmpty, wantedAlbum == candidateAlbum { score += 10 }
        return score
    }

    private func normalized(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private func localizedTTML(from value: TTMLLocalizations) -> String? {
        let localizations: [String: String]
        switch value {
        case .ttml(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<") { return trimmed }
            guard let data = trimmed.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                return nil
            }
            localizations = decoded
        case .localized(let values):
            localizations = values
        }
        let preferred = Locale.preferredLanguages
        for language in preferred {
            if let exact = localizations[language] { return exact }
            let base = language.split(separator: "-").first.map(String.init)
            if let base, let match = localizations.first(where: { $0.key.hasPrefix(base) }) {
                return match.value
            }
        }
        return localizations.values.first
    }
}

private enum CacheCandidate {
    case file(URL)
    case inline(Data)

    var fileURL: URL? {
        guard case .file(let url) = self else { return nil }
        return url
    }

    func data() -> Data? {
        switch self {
        case .file(let url):
            return try? Data(contentsOf: url, options: .mappedIfSafe)
        case .inline(let data):
            return data
        }
    }
}

private extension Data {
    init?(hexEncoded value: String) {
        guard value.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }
        self.init(bytes)
    }
}

private struct CatalogResponse: Decodable {
    let data: [CatalogSong]
}

private struct CatalogSong: Decodable {
    let attributes: CatalogSongAttributes
    let relationships: CatalogRelationships?
}

private struct CatalogSongAttributes: Decodable {
    let name: String
    let artistName: String
    let albumName: String?
    let durationInMillis: Int?
}

private struct CatalogRelationships: Decodable {
    let syllableLyrics: CatalogRelationship?

    enum CodingKeys: String, CodingKey {
        case syllableLyrics = "syllable-lyrics"
    }
}

private struct CatalogRelationship: Decodable {
    let data: [CatalogLyric]
}

private struct CatalogLyric: Decodable {
    let attributes: CatalogLyricAttributes
}

private struct CatalogLyricAttributes: Decodable {
    let ttmlLocalizations: TTMLLocalizations?
}

private enum TTMLLocalizations: Decodable {
    case ttml(String)
    case localized([String: String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .ttml(value)
        } else {
            self = .localized(try container.decode([String: String].self))
        }
    }
}
