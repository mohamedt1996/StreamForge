import Foundation

/// Canonical item keys shared by every StreamForge client (PROTOCOL.md §3):
/// IMDb → TMDB → Dispatcharr → addon meta id, plus `:s<season>e<episode>` for episodes.
enum SyncKeys {
    static let legacyFavoriteBase: Double = 1_600_000_000_000

    /// "movie" / "series", or nil for things that never sync (channels, torrent files…).
    static func typeName(_ type: MediaType) -> String? {
        switch type {
        case .movie: return "movie"
        case .series, .episode: return "series"
        case .channel, .other: return nil
        }
    }

    static func imdbID(of item: MediaItem) -> String? {
        if let i = item.imdbID?.trimmingCharacters(in: .whitespaces), i.hasPrefix("tt"), i.count > 2 { return i }
        if case .stremio(_, let meta) = item.origin, meta.hasPrefix("tt"), !meta.contains(":") { return meta }
        if item.id.hasPrefix("tt"), !item.id.contains(":"), !item.id.contains("#") { return item.id }
        return nil
    }

    static func tmdbID(of item: MediaItem) -> Int? {
        if let t = item.tmdbID, t > 0 { return t }
        if case .tmdb(let t) = item.origin, t > 0 { return t }
        return nil
    }

    /// `movie:tt0111161`, `movie:tmdb:278`, `movie:dispatcharr:<uuid>:<id>`, `series:meta:<id>`.
    static func itemKey(_ item: MediaItem) -> String? {
        guard let type = typeName(item.type) else { return nil }
        if let imdb = imdbID(of: item) { return "\(type):\(imdb)" }
        if let tmdb = tmdbID(of: item) { return "\(type):tmdb:\(tmdb)" }
        switch item.origin {
        case .dispatcharrMovie(let serverID, let streamID, _):
            return "\(type):dispatcharr:\(serverID.uuidString.lowercased()):\(streamID)"
        case .dispatcharrSeries(let serverID, let seriesID):
            return "\(type):dispatcharr:\(serverID.uuidString.lowercased()):\(seriesID)"
        case .stremio(_, let metaID):
            return metaID.isEmpty ? nil : "\(type):meta:\(metaID)"
        case .dispatcharrChannel, .tmdb:
            return nil
        }
    }

    static func episodeSuffix(season: Int, episode: Int) -> String { ":s\(season)e\(episode)" }

    static func fullKey(_ item: MediaItem, _ episode: EpisodeRef?) -> String? {
        guard let key = itemKey(item) else { return nil }
        guard let episode else { return key }
        return key + episodeSuffix(season: episode.season, episode: episode.episode)
    }

    /// Splits `series:tt1:s1e2` into ("series:tt1", (1, 2)).
    static func splitEpisode(_ key: String) -> (item: String, season: Int, episode: Int)? {
        guard let colon = key.range(of: ":s", options: .backwards) else { return nil }
        let tail = key[colon.upperBound...]
        let parts = tail.split(separator: "e", omittingEmptySubsequences: false)
        guard parts.count == 2, let s = Int(parts[0]), let e = Int(parts[1]) else { return nil }
        return (String(key[..<colon.lowerBound]), s, e)
    }

    enum Parsed {
        case imdb(String)
        case tmdb(Int)
        case dispatcharr(UUID, Int)
        case meta(String)
    }

    /// Parses an item key (without the episode suffix).
    static func parse(_ itemKey: String) -> (type: MediaType, id: Parsed)? {
        guard let colon = itemKey.firstIndex(of: ":") else { return nil }
        let typeName = itemKey[..<colon]
        let type: MediaType
        switch typeName {
        case "movie": type = .movie
        case "series": type = .series
        default: return nil
        }
        let rest = String(itemKey[itemKey.index(after: colon)...])
        if rest.hasPrefix("tmdb:"), let n = Int(rest.dropFirst(5)) { return (type, .tmdb(n)) }
        if rest.hasPrefix("dispatcharr:") {
            let parts = rest.dropFirst("dispatcharr:".count).split(separator: ":")
            if parts.count == 2, let uuid = UUID(uuidString: String(parts[0])), let n = Int(parts[1]) {
                return (type, .dispatcharr(uuid, n))
            }
            return nil
        }
        if rest.hasPrefix("meta:") { return (type, .meta(String(rest.dropFirst(5)))) }
        if rest.hasPrefix("tt") { return (type, .imdb(rest)) }
        return nil
    }

    /// The id this app would give a MediaItem with that key (used for watched marks of items this
    /// device has never seen; any id works as long as it round-trips through the canonical map).
    static func localItemID(forItemKey itemKey: String) -> String {
        guard let parsed = parse(itemKey) else { return itemKey }
        switch parsed.id {
        case .imdb(let i): return i
        case .tmdb(let n): return "tmdb:\(parsed.type.rawValue):\(n)"
        case .dispatcharr(let uuid, let n):
            return "xc:\(uuid.uuidString.prefix(8)):\(parsed.type == .series ? "series" : "movie"):\(n)"
        case .meta(let m): return m.hasPrefix("tt") ? m : "meta:\(m)"
        }
    }

    /// Best-effort canonical key for a watched mark recorded before canonical keys were stored.
    static func legacyKey(forLocalKey localKey: String, serverIDs: [UUID]) -> String? {
        let parts = localKey.components(separatedBy: "#")
        let itemID = parts[0]
        var suffix = ""
        var isEpisode = false
        if parts.count > 1 {
            let se = parts[1].split(separator: "x")
            guard se.count == 2, let s = Int(se[0]), let e = Int(se[1]) else { return nil }
            suffix = episodeSuffix(season: s, episode: e)
            isEpisode = true
        }
        if itemID.hasPrefix("tt"), !itemID.contains(":") {
            return (isEpisode ? "series" : "movie") + ":" + itemID + suffix
        }
        if itemID.hasPrefix("tmdb:") {
            let p = itemID.split(separator: ":")
            if p.count == 3, let n = Int(p[2]) {
                let type = p[1] == "series" ? "series" : "movie"
                return "\(type):tmdb:\(n)\(suffix)"
            }
            return nil
        }
        if itemID.hasPrefix("xc:") {
            let p = itemID.split(separator: ":")
            if p.count == 4, let n = Int(p[3]), p[2] == "movie" || p[2] == "series",
               let server = serverIDs.first(where: { $0.uuidString.hasPrefix(String(p[1])) }) {
                return "\(p[2]):dispatcharr:\(server.uuidString.lowercased()):\(n)\(suffix)"
            }
            return nil
        }
        if itemID.hasPrefix("stremio:"), isEpisode {
            // "stremio:<addonID>:<metaID>"; addon ids never contain ":".
            let rest = itemID.dropFirst("stremio:".count)
            if let c = rest.firstIndex(of: ":") {
                let meta = rest[rest.index(after: c)...]
                if !meta.isEmpty { return "series:meta:\(meta)\(suffix)" }
            }
        }
        return nil
    }
}
