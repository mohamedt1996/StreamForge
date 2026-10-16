import Foundation

enum MediaType: String, Codable, Hashable, CaseIterable {
    case movie, series, channel, episode, other

    var stremioType: String {
        switch self {
        case .movie: return "movie"
        case .series, .episode: return "series"
        case .channel: return "tv"
        case .other: return "other"
        }
    }

    init(stremio: String) {
        switch stremio {
        case "movie": self = .movie
        case "series": self = .series
        case "tv", "channel": self = .channel
        default: self = .other
        }
    }
}

/// Where an item came from, which decides how it is resolved and played.
enum MediaOrigin: Codable, Hashable {
    /// Dispatcharr VOD movie: stream id + container extension.
    case dispatcharrMovie(serverID: UUID, streamID: Int, ext: String)
    /// Dispatcharr series: series id.
    case dispatcharrSeries(serverID: UUID, seriesID: Int)
    /// Dispatcharr live channel.
    case dispatcharrChannel(serverID: UUID, channelID: Int)
    /// A Stremio meta from an addon (id like "tt0111161" or "kitsu:123").
    case stremio(addonID: String, metaID: String)
    /// Pure metadata item from TMDB.
    case tmdb(id: Int)
}

/// The single item model every screen renders, regardless of source.
struct MediaItem: Identifiable, Hashable, Codable {
    var id: String
    var type: MediaType
    var title: String
    var year: Int?
    var poster: URL?
    var backdrop: URL?
    var logo: URL?
    var overview: String?
    var rating: Double?
    var genres: [String] = []
    var imdbID: String?
    var tmdbID: Int?
    var origin: MediaOrigin
    var added: Date?
    var runtimeMinutes: Int?
    var categoryID: String?
    /// Optional direct AVPlayer-compatible preview; older saved items decode without it.
    var trailerURL: URL?

    static func == (a: MediaItem, b: MediaItem) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var yearText: String? { year.map(String.init) }

    /// Stremio-compatible id used to ask addons for streams/subtitles.
    var stremioID: String? {
        if let imdbID, imdbID.hasPrefix("tt") { return imdbID }
        if case .stremio(_, let metaID) = origin { return metaID }
        if let tmdbID { return "tmdb:\(tmdbID)" }
        return nil
    }
}

struct EpisodeRef: Codable, Hashable, Identifiable {
    var id: String
    var season: Int
    var episode: Int
    var title: String
    var overview: String?
    var still: URL?
    var airDate: String?
    var runtimeMinutes: Int?
    /// Dispatcharr episode stream id + extension when the episode is playable from the server.
    var dispatcharrEpisodeID: Int?
    var ext: String?
    /// Stremio video id (e.g. "tt0944947:1:2").
    var stremioVideoID: String?

    var code: String { String(format: "S%02dE%02d", season, episode) }
}

/// A TMDB movie collection ("franchise"), e.g. "The Lord of the Rings Collection".
struct CollectionInfo: Hashable, Codable, Identifiable {
    var id: Int
    var name: String
    var poster: URL?
    var backdrop: URL?
}

struct Person: Identifiable, Hashable, Codable {
    var id: Int
    var name: String
    var role: String?
    var photo: URL?
}

struct RatingBadge: Hashable, Codable, Identifiable {
    var id: String { source }
    var source: String   // "IMDb", "TMDB", "Rotten Tomatoes", "Metacritic"
    var value: String
}

struct SeasonInfo: Hashable, Codable, Identifiable {
    var id: Int { number }
    var number: Int
    var name: String
    var poster: URL?
    var episodeCount: Int?
}

/// Fully enriched details for the detail screen.
struct MediaDetails {
    var item: MediaItem
    var tagline: String?
    var cast: [Person] = []
    var directors: [String] = []
    /// YouTube ids of trailers/teasers, best first. Players try them in order (a video can be
    /// removed or region-locked), so every source's trailers are kept, not just the first.
    var trailerKeys: [String] = []
    var ratings: [RatingBadge] = []
    var seasons: [SeasonInfo] = []
    var episodesBySeason: [Int: [EpisodeRef]] = [:]
    var similar: [MediaItem] = []
    var certification: String?
    var status: String?
    var networks: [String] = []
    /// TMDB collection this movie belongs to.
    var collection: CollectionInfo?

    var trailerYouTubeKey: String? { trailerKeys.first }

    /// Adds trailer ids (bare ids or YouTube URLs), skipping duplicates and junk.
    mutating func addTrailers(_ raw: [String], atFront: Bool = false) {
        if item.trailerURL == nil {
            item.trailerURL = raw.compactMap { TrailerSelection.directURL(URL(string: $0)) }.first
        }
        let incoming = raw.filter { TrailerSelection.directURL(URL(string: $0)) == nil }
            .compactMap(Self.cleanYouTubeKey).filter { !trailerKeys.contains($0) }
        var seen = Set<String>()
        let unique = incoming.filter { seen.insert($0).inserted }
        trailerKeys = atFront ? unique + trailerKeys : trailerKeys + unique
    }

    /// "https://youtu.be/abc_DEF-123", "…watch?v=abc_DEF-123" or "abc_DEF-123" → "abc_DEF-123".
    static func cleanYouTubeKey(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.contains("/") || s.contains("=") {
            if let comps = URLComponents(string: s) {
                let host = comps.host?.lowercased() ?? ""
                guard ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtube-nocookie.com"].contains(host) else { return nil }
                if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value {
                    s = v
                } else if let last = comps.path.split(separator: "/").last {
                    s = String(last)
                } else {
                    return nil
                }
            } else {
                return nil
            }
        }
        let allowed = s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
        return allowed && (6...20).contains(s.count) ? s : nil
    }
}

extension TimeInterval {
    var clockText: String {
        guard isFinite, self >= 0 else { return "--:--" }
        let total = Int(self)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

extension Int {
    var runtimeText: String {
        let h = self / 60, m = self % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

extension Int64 {
    var byteText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// Cleans provider titles such as "EN | The Matrix (1999) [4K]" into "The Matrix" + 1999.
enum TitleCleaner {
    private static let prefixPattern = try! NSRegularExpression(pattern: #"^\s*(\[[^\]]{1,12}\]|[A-Z0-9]{2,4}\s*[\|\-:•]+)\s*"#)
    private static let yearPattern = try! NSRegularExpression(pattern: #"[\(\[]?\b(19[2-9]\d|20[0-4]\d)\b[\)\]]?"#)
    private static let tagPattern = try! NSRegularExpression(
        pattern: #"(?i)[\(\[]?\b(4k|uhd|fhd|hd|sd|hevc|x26[45]|h\.?26[45]|1080p|720p|2160p|multi|vostfr|subbed|dubbed|hdr10?\+?|dolby vision|dv|imax)\b[\)\]]?"#)

    static func clean(_ raw: String) -> (title: String, year: Int?) {
        var s = raw
        let ns = { (str: String) in NSRange(str.startIndex..., in: str) }
        // Strip up to two stacked prefixes like "EN | VOD | ".
        for _ in 0..<2 {
            s = prefixPattern.stringByReplacingMatches(in: s, range: ns(s), withTemplate: "")
        }
        var year: Int?
        if let m = yearPattern.matches(in: s, range: ns(s)).last, let r = Range(m.range(at: 1), in: s) {
            let candidate = Int(s[r])
            if let full = Range(m.range, in: s) {
                var stripped = s
                stripped.removeSubrange(full)
                // Keep titles that *are* a year, like "1917" or "2012".
                if !stripped.trimmingCharacters(in: CharacterSet(charactersIn: " -|:()[]")).isEmpty {
                    s = stripped
                    year = candidate
                }
            }
        }
        s = tagPattern.stringByReplacingMatches(in: s, range: ns(s), withTemplate: "")
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -|:•[]()").union(.whitespaces))
        return (s.isEmpty ? raw.trimmed : s, year)
    }

    /// Splits "EN | Action" style category names into (group: "EN", name: "Action").
    static func splitCategory(_ raw: String) -> (group: String?, name: String) {
        let separators = ["|", " - ", ":", "•", "»"]
        for sep in separators {
            let parts = raw.components(separatedBy: sep)
            if parts.count >= 2 {
                let head = parts[0].trimmed
                if head.count <= 12, !head.isEmpty {
                    let rest = parts.dropFirst().joined(separator: sep).trimmed
                    if !rest.isEmpty { return (head.uppercased(), rest) }
                }
            }
        }
        return (nil, raw.trimmed)
    }
}
