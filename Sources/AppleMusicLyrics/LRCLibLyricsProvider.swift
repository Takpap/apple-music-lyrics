import Foundation

/// Fetches synced lyrics from the free LRCLIB API (https://lrclib.net/docs).
final class LRCLibLyricsProvider: @unchecked Sendable {
    /// Performs a request and returns the body with the HTTP status code.
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)

    static let userAgent = "AppleMusicLyrics (https://github.com/Takpap/apple-music-lyrics)"
    static let maximumDurationDifference: TimeInterval = 4
    static let negativeCacheLifetime: TimeInterval = 10 * 60
    static let failureCacheLifetime: TimeInterval = 60

    private struct CacheEntry {
        let document: LyricsDocument?
        let expiresAt: Date?
    }

    private let baseURL: URL
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private let logger = DiagnosticLogger.shared
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    init(
        baseURL: URL = URL(string: "https://lrclib.net")!,
        fetch: @escaping Fetch = LRCLibLyricsProvider.urlSessionFetch,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.fetch = fetch
        self.now = now
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
            let (data, status) = try await fetch(request(path: "/api/get", query: query))
            if status == 200, let record = try? JSONDecoder().decode(Record.self, from: data) {
                if record.hasSynced, let document = Self.document(from: record) { return document }
                if record.hasPlain { plainFallback = record }
            } else if status != 404 && status != 200 {
                throw LookupError.badStatus(status)
            }
        }

        let (data, status) = try await fetch(request(path: "/api/search", query: [
            ("track_name", track.title),
            ("artist_name", track.artist)
        ]))
        guard status == 200 else {
            if status == 404 { return plainFallback.flatMap(Self.document(from:)) }
            throw LookupError.badStatus(status)
        }
        let results = (try? JSONDecoder().decode([Record].self, from: data)) ?? []

        func closest(_ candidates: [Record]) -> Record? {
            let scored = candidates.map { record -> (Record, TimeInterval) in
                let diff = track.duration > 0 ? abs((record.duration ?? .infinity) - track.duration) : 0
                return (record, diff)
            }
            .filter { $0.1 <= Self.maximumDurationDifference }
            return scored.min { $0.1 < $1.1 }?.0
        }

        if let best = closest(results.filter { $0.hasSynced && $0.instrumental != true }),
           let document = Self.document(from: best) {
            return document
        }
        if let record = plainFallback ?? closest(results.filter { $0.hasPlain && $0.instrumental != true }) {
            return Self.document(from: record)
        }
        return nil
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
