import CryptoKit
import Foundation

/// Lyrics for one track. `lines` is non-empty only for time-synced lyrics.
struct Lyrics: Codable, Equatable {
    struct Line: Codable, Equatable {
        let time: Double
        let text: String
    }

    var lines: [Line] = []
    var plain: String?
    var instrumental = false

    var isSynced: Bool { !lines.isEmpty }
}

/// Fetches lyrics from LRCLIB (https://lrclib.net — free, no key) and caches them on disk.
///
/// Only the track title, artist, album and duration are sent, and only once per track:
/// hits and misses are both cached.
final class LyricsService: @unchecked Sendable {
    struct Query: Hashable {
        let title: String
        let artist: String
        let album: String
        let duration: Double
    }

    enum Result {
        case found(Lyrics)
        case notFound
    }

    private let session: URLSession
    private let cacheDir: URL
    /// How long a "no lyrics" answer is trusted before asking again (LRCLIB grows over time).
    private let missTTL: TimeInterval = 3 * 24 * 3600

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = ["User-Agent": "AgentNotch/0.1 (macOS notch app)"]
        session = URLSession(configuration: config)

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        cacheDir = base.appendingPathComponent("AgentNotch/Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Public

    /// Throws only for network/server trouble (not cached, so it's retried next time).
    func lyrics(for query: Query) async throws -> Result {
        let cleaned = Self.clean(query)
        let key = Self.cacheKey(cleaned)
        if let cached = readCache(key) { return cached }

        let result = try await fetch(cleaned)
        writeCache(key, result)
        return result
    }

    // MARK: - LRCLIB

    private struct Record: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private func fetch(_ q: Query) async throws -> Result {
        // 1. Exact signature match (fast, cached on their side).
        if !q.artist.isEmpty, q.duration > 0 {
            var items = [
                URLQueryItem(name: "track_name", value: q.title),
                URLQueryItem(name: "artist_name", value: q.artist),
                URLQueryItem(name: "duration", value: String(Int(q.duration.rounded()))),
            ]
            if !q.album.isEmpty { items.append(URLQueryItem(name: "album_name", value: q.album)) }
            if let record: Record = try await get("get", items), let lyrics = Self.lyrics(from: record) {
                if lyrics.isSynced || lyrics.instrumental { return .found(lyrics) }
                // Plain-only exact hit: keep it, but a search might still find a synced version.
                if let better = try await search(q), better.isSynced { return .found(better) }
                return .found(lyrics)
            }
        }
        // 2. Fuzzy search.
        if let lyrics = try await search(q) { return .found(lyrics) }
        return .notFound
    }

    private func search(_ q: Query) async throws -> Lyrics? {
        var items = [URLQueryItem(name: "track_name", value: q.title)]
        if !q.artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: q.artist)) }
        var records: [Record] = try await get("search", items) ?? []
        if records.isEmpty, !q.artist.isEmpty {
            // Artist names from video sites are often a channel name; try a free-text query.
            records = try await get("search", [URLQueryItem(name: "q", value: "\(q.artist) \(q.title)")]) ?? []
        }
        return Self.best(records, for: q).flatMap(Self.lyrics(from:))
    }

    /// Picks the closest-duration record, preferring synced lyrics. Rejects clear mismatches.
    private static func best(_ records: [Record], for q: Query) -> Record? {
        let tolerance: Double = 4
        let candidates = records.filter { r in
            guard q.duration > 0, let d = r.duration else { return true }
            return abs(d - q.duration) <= tolerance
        }
        func score(_ r: Record) -> Double {
            var s = 0.0
            if r.syncedLyrics?.isEmpty == false { s += 10 }
            if let d = r.duration, q.duration > 0 { s -= abs(d - q.duration) }
            if normalize(r.trackName ?? "") == normalize(q.title) { s += 3 }
            return s
        }
        return candidates.max { score($0) < score($1) }
    }

    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem]) async throws -> T? {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")!
        components.queryItems = items
        let (data, response) = try await session.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func lyrics(from r: Record) -> Lyrics? {
        let lines = r.syncedLyrics.map(parseLRC) ?? []
        let plain = r.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        let instrumental = r.instrumental ?? false
        guard !lines.isEmpty || plain?.isEmpty == false || instrumental else { return nil }
        return Lyrics(lines: lines, plain: plain?.isEmpty == false ? plain : nil, instrumental: instrumental)
    }

    // MARK: - LRC parsing

    /// Parses `[mm:ss.xx] text` lines. A line may carry several timestamps; metadata tags are skipped.
    static func parseLRC(_ text: String) -> [Lyrics.Line] {
        var result: [Lyrics.Line] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let t = parseTimestamp(tag) { times.append(t) }
                rest = rest[rest.index(after: close)...]
            }
            guard !times.isEmpty else { continue }
            let line = rest.trimmingCharacters(in: .whitespaces)
            for t in times { result.append(.init(time: t, text: line)) }
        }
        result.sort { $0.time < $1.time }
        // Drop trailing empty lines; they'd just blank the notch at the end of the song.
        while result.last?.text.isEmpty == true { result.removeLast() }
        return result
    }

    private static func parseTimestamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }

    // MARK: - Cleaning video-site metadata

    /// Strips noise like "(Official Video)", "[4K]", " - Topic", "VEVO" and splits "Artist - Song" titles.
    static func clean(_ q: Query) -> Query {
        var title = q.title
        var artist = q.artist

        let noise = #"\s*[\(\[][^\)\]]*(official|video|audio|lyric|lyrics|visualizer|mv|m/v|hd|hq|4k|remaster(ed)?|live)[^\)\]]*[\)\]]"#
        title = title.replacingOccurrences(of: noise, with: "", options: [.regularExpression, .caseInsensitive])
        title = title.replacingOccurrences(of: #"\s*\|.*$"#, with: "", options: .regularExpression)
        artist = artist.replacingOccurrences(of: #"\s*-\s*Topic$"#, with: "", options: [.regularExpression, .caseInsensitive])
        artist = artist.replacingOccurrences(of: #"VEVO$"#, with: "", options: [.regularExpression, .caseInsensitive])

        // "Artist - Song" in the title (common on YouTube, where the "artist" is the channel).
        let dashParts = title.components(separatedBy: " - ")
        if dashParts.count == 2 {
            let left = dashParts[0].trimmingCharacters(in: .whitespaces)
            let right = dashParts[1].trimmingCharacters(in: .whitespaces)
            if artist.isEmpty || normalize(left).contains(normalize(artist)) || normalize(artist).contains(normalize(left)) {
                artist = left
                title = right
            } else if q.album.isEmpty {
                artist = left
                title = right
            }
        }
        // "feat." credits rarely match the database's track name.
        title = title.replacingOccurrences(of: #"\s*[\(\[]?\s*(feat\.?|ft\.?|featuring)\s+[^\)\]]*[\)\]]?"#,
                                           with: "", options: [.regularExpression, .caseInsensitive])

        return Query(title: title.trimmingCharacters(in: .whitespaces),
                     artist: artist.trimmingCharacters(in: .whitespaces),
                     album: q.album, duration: q.duration)
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Disk cache

    private struct CacheEntry: Codable {
        let lyrics: Lyrics?
        let date: Date
    }

    private static func cacheKey(_ q: Query) -> String {
        let raw = "\(normalize(q.artist))|\(normalize(q.title))|\(Int(q.duration.rounded()))"
        return SHA256.hash(data: Data(raw.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func readCache(_ key: String) -> Result? {
        let url = cacheDir.appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data) else { return nil }
        if let lyrics = entry.lyrics { return .found(lyrics) }
        return Date().timeIntervalSince(entry.date) < missTTL ? .notFound : nil
    }

    private func writeCache(_ key: String, _ result: Result) {
        let lyrics: Lyrics?
        switch result {
        case .found(let l): lyrics = l
        case .notFound: lyrics = nil
        }
        let url = cacheDir.appendingPathComponent(key + ".json")
        if let data = try? JSONEncoder().encode(CacheEntry(lyrics: lyrics, date: Date())) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
