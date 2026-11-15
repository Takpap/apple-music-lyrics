import Foundation

/// Fetches synced lyrics from the free LRCLIB API (https://lrclib.net/docs).
final class LRCLibLyricsProvider: @unchecked Sendable {
    /// Performs a request and returns the body with the HTTP status code.
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)

    static let userAgent = "AppleMusicLyrics (https://github.com/Takpap/apple-music-lyrics)"
    static let maximumDurationDifference: TimeInterval = 4
    static let negativeCacheLifetime: TimeInterval = 10 * 60
    static let failureCacheLifetime: TimeInterval = 60
    /// Waits before retrying a rate-limited (429) or failed (5xx) request.
    static let retryDelays: [TimeInterval] = [1.5, 4]

    private struct CacheEntry {
        let document: LyricsDocument?
        let expiresAt: Date?
    }

    private let baseURL: URL
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let logger = DiagnosticLogger.shared
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    init(
        baseURL: URL = URL(string: "https://lrclib.net")!,
        fetch: @escaping Fetch = LRCLibLyricsProvider.urlSessionFetch,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.baseURL = baseURL
        self.fetch = fetch
        self.now = now
        self.sleep = sleep
    }

    func lyrics(for track: TrackInfo) async -> LyricsDocument? {
        let key = track.identityKey
        if let cached = cachedEntry(for: key) { return cached.document }

        guard !track.title.isEmpty else { return nil }

        do {
            let document = try await fetchDocument(for: track)
            store(CacheEntry(
                document: document,
                expiresAt: document == nil ? now().addingTimeInterval(Self.negativeCacheLifetime) : nil
            ), for: key)
            return document
        } catch {
            logger.warning("LRCLIB lookup failed; track=\(track.displayName); error=\(error.localizedDescription)")
            store(CacheEntry(
                document: nil,
                expiresAt: now().addingTimeInterval(Self.failureCacheLifetime)
            ), for: key)
            return nil
        }
    }

    // MARK: - Lookup

    private struct Record: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?

        var hasSynced: Bool { !(syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var hasPlain: Bool { !(plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func fetchDocument(for track: TrackInfo) async throws -> LyricsDocument? {
        var plainFallback: Record?

        if track.duration > 0 {
            let query: [(String, String)] = [
                ("track_name", track.title),
                ("artist_name", track.artist),
                ("album_name", track.album),
                ("duration", String(Int(track.duration.rounded())))
            ]
            let (data, status) = try await send(request(path: "/api/get", query: query))
            if status == 200, let record = try? JSONDecoder().decode(Record.self, from: data) {
                if record.hasSynced, let document = Self.document(from: record) { return document }
                if record.hasPlain { plainFallback = record }
            } else if status != 404 && status != 200 && status != 400 {
                throw LookupError.badStatus(status)
            }
        }

        // Search with the full title and artist, then with the decorations
        // ("(feat. …)", "(Mixed)", "[Demo]", a second artist) stripped. The
        // duration check keeps a different recording from matching.
        var seen = Set<String>()
        var looseMatch: Record?
        for variant in Self.searchVariants(title: track.title, artist: track.artist) {
            let key = "\(variant.title.lowercased())|\(variant.artist.lowercased())"
            guard seen.insert(key).inserted else { continue }
            var query = [("track_name", variant.title)]
            if !variant.artist.isEmpty { query.append(("artist_name", variant.artist)) }
            let (data, status) = try await send(request(path: "/api/search", query: query))
            guard status == 200 else {
                if status == 404 || status == 400 { continue }
                throw LookupError.badStatus(status)
            }
            let results = (try? JSONDecoder().decode([Record].self, from: data)) ?? []
            if let best = closest(results.filter { $0.hasSynced && $0.instrumental != true }, to: track),
               let document = Self.document(from: best) {
                return document
            }
            if plainFallback == nil {
                plainFallback = closest(results.filter { $0.hasPlain && $0.instrumental != true }, to: track)
            }
            if looseMatch == nil {
                looseMatch = results.first { record in
                    record.instrumental != true && (record.hasPlain || record.hasSynced)
                        && Self.sameName(record.trackName, Self.strippedTitle(track.title))
                        && Self.sameName(record.artistName, Self.primaryArtist(track.artist))
                }
            }
        }
        if let plainFallback { return Self.document(from: plainFallback) }
        // A different cut of the same song (a mix, a radio edit): its timing
        // would be wrong, so show the words without syncing.
        return looseMatch.flatMap(Self.unsyncedDocument(from:))
    }

    private static func sameName(_ candidate: String?, _ wanted: String) -> Bool {
        guard let candidate else { return false }
        let fold: (String) -> String = {
            strippedTitle($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        return fold(candidate) == fold(wanted) || fold(primaryArtist(candidate)) == fold(wanted)
    }

    private static func unsyncedDocument(from record: Record) -> LyricsDocument? {
        let text = record.hasPlain
            ? record.plainLyrics
            : record.syncedLyrics.map { LRCParser.parse($0).map(\.text).joined(separator: "\n") }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return LyricsDocument(lines: [], plainText: text, source: "LRCLIB", isSynced: false, wordTiming: .none)
    }

    private func closest(_ candidates: [Record], to track: TrackInfo) -> Record? {
        let scored = candidates.map { record -> (Record, TimeInterval) in
            let diff = track.duration > 0 ? abs((record.duration ?? .infinity) - track.duration) : 0
            return (record, diff)
        }
        .filter { $0.1 <= Self.maximumDurationDifference }
        return scored.min { $0.1 < $1.1 }?.0
    }

    /// Sends a request, retrying when LRCLIB rate-limits (429) or fails (5xx).
    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        var attempt = 0
        while true {
            let result = try await fetch(request)
            let retryable = result.1 == 429 || (500...599).contains(result.1)
            guard retryable, attempt < Self.retryDelays.count else { return result }
            await sleep(Self.retryDelays[attempt])
            attempt += 1
        }
    }

    struct SearchVariant: Equatable {
        let title: String
        let artist: String
    }

    /// The title/artist pairs to search, most specific first.
    static func searchVariants(title: String, artist: String) -> [SearchVariant] {
        let cleanTitle = strippedTitle(title)
        let mainArtist = primaryArtist(artist)
        var variants = [SearchVariant(title: title, artist: artist)]
        if cleanTitle != title { variants.append(SearchVariant(title: cleanTitle, artist: artist)) }
        if mainArtist != artist {
            variants.append(SearchVariant(title: title, artist: mainArtist))
            if cleanTitle != title { variants.append(SearchVariant(title: cleanTitle, artist: mainArtist)) }
        }
        return variants.filter { !$0.title.isEmpty }
    }

    /// Drops "(feat. …)", "[Demo]", "- Remastered 2011" style decorations.
    static func strippedTitle(_ title: String) -> String {
        var result = title
        for pattern in [#"\s*[\(\[][^\)\]]*[\)\]]"#, #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#, #"\s+-\s+.*$"#] {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? title : result
    }

    /// The first credited artist of "A & B", "A, B", "A feat. B", "A x B".
    static func primaryArtist(_ artist: String) -> String {
        let pattern = #"\s*(,|&| and | x | feat\.?\s| ft\.?\s| featuring ).*$"#
        let result = artist.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? artist : result
    }

    private static func document(from record: Record) -> LyricsDocument? {
        if record.hasSynced, let synced = record.syncedLyrics {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty {
                let hasWords = lines.contains { !$0.words.isEmpty }
                let plain = record.hasPlain
                    ? record.plainLyrics
                    : lines.map(\.text).joined(separator: "\n")
                return LyricsDocument(
                    lines: lines,
                    plainText: plain,
                    source: "LRCLIB",
                    isSynced: true,
                    wordTiming: hasWords ? .exact : .none
                )
            }
        }
        if record.hasPlain, let plain = record.plainLyrics {
            return LyricsDocument(
                lines: [],
                plainText: plain,
                source: "LRCLIB",
                isSynced: false,
                wordTiming: .none
            )
        }
        return nil
    }

    // MARK: - Requests

    private enum LookupError: Error, LocalizedError {
        case badStatus(Int)
        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "HTTP \(code)"
            }
        }
    }

    private func request(path: String, query: [(String, String)]) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.percentEncodedQuery = query
            .map { "\($0.0)=\(Self.encode($0.1))" }
            .joined(separator: "&")
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static let queryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
    }

    @Sendable
    static func urlSessionFetch(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - Cache

    private func cachedEntry(for key: String) -> CacheEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key] else { return nil }
        if let expiry = entry.expiresAt, expiry <= now() {
            cache[key] = nil
            return nil
        }
        return entry
    }

    private func store(_ entry: CacheEntry, for key: String) {
        lock.lock()
        cache[key] = entry
        lock.unlock()
    }
}
