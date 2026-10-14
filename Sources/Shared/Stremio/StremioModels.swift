import Foundation

// Stremio addon protocol: https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/protocol.md

struct StremioManifest: Codable, Hashable {
    struct Resource: Codable, Hashable {
        var name: String
        var types: [String]?
        var idPrefixes: [String]?

        init(from decoder: Decoder) throws {
            // A resource is either "stream" or {"name":"stream","types":[...],"idPrefixes":[...]}.
            if let single = try? decoder.singleValueContainer().decode(String.self) {
                name = single
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            types = try? c.decodeIfPresent([String].self, forKey: .types)
            idPrefixes = try? c.decodeIfPresent([String].self, forKey: .idPrefixes)
        }
        enum CodingKeys: String, CodingKey { case name, types, idPrefixes }
    }

    struct ExtraProp: Codable, Hashable {
        var name: String
        var isRequired: Bool?
        var options: [String]?
    }

    struct Catalog: Codable, Hashable, Identifiable {
        var type: String
        var id: String
        var name: String?
        var extra: [ExtraProp]?
        var extraSupported: [String]?
        var extraRequired: [String]?

        var identity: String { "\(type)/\(id)" }
        var supportsSearch: Bool {
            (extra?.contains { $0.name == "search" } ?? false) || (extraSupported?.contains("search") ?? false)
        }
        var requiresExtra: Bool {
            (extra?.contains { $0.isRequired == true } ?? false) || !(extraRequired ?? []).isEmpty
        }
        var genreOptions: [String] { extra?.first { $0.name == "genre" }?.options ?? [] }
        var supportsSkip: Bool {
            (extra?.contains { $0.name == "skip" } ?? false) || (extraSupported?.contains("skip") ?? false)
        }
    }

    struct BehaviorHints: Codable, Hashable {
        var adult: Bool?
        var p2p: Bool?
        var configurable: Bool?
        var configurationRequired: Bool?
    }

    var id: String
    var version: String?
    var name: String
    var description: String?
    var logo: String?
    var background: String?
    var types: [String]?
    var resources: [Resource]
    var catalogs: [Catalog]?
    var idPrefixes: [String]?
    var behaviorHints: BehaviorHints?

    enum CodingKeys: String, CodingKey {
        case id, version, name, description, logo, background, types, resources, catalogs, idPrefixes, behaviorHints
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        version = c.flexString(.version)
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        logo = try? c.decodeIfPresent(String.self, forKey: .logo)
        background = try? c.decodeIfPresent(String.self, forKey: .background)
        types = try? c.decodeIfPresent([String].self, forKey: .types)
        resources = (try? c.decode(LossyArray<Resource>.self, forKey: .resources))?.elements ?? []
        catalogs = (try? c.decode(LossyArray<Catalog>.self, forKey: .catalogs))?.elements
        idPrefixes = try? c.decodeIfPresent([String].self, forKey: .idPrefixes)
        behaviorHints = try? c.decodeIfPresent(BehaviorHints.self, forKey: .behaviorHints)
    }

    /// Whether this addon claims it can answer `resource` for `type` + `id`.
    func supports(_ resource: String, type: String, id: String) -> Bool {
        for r in resources where r.name == resource {
            let types = r.types ?? self.types ?? []
            guard types.isEmpty || types.contains(type) else { continue }
            let prefixes = r.idPrefixes ?? self.idPrefixes
            if let prefixes, !prefixes.isEmpty {
                if prefixes.contains(where: { id.hasPrefix($0) }) { return true }
            } else {
                return true
            }
        }
        return false
    }

    var hasStreams: Bool { resources.contains { $0.name == "stream" } }
    var hasSubtitles: Bool { resources.contains { $0.name == "subtitles" } }
    var hasMeta: Bool { resources.contains { $0.name == "meta" } }
}

struct InstalledAddon: Codable, Hashable, Identifiable {
    var id: String { manifest.id }
    /// The transport URL without the trailing "/manifest.json".
    var baseURL: URL
    var manifest: StremioManifest
    var enabled: Bool = true
    var installedAt: Date = Date()

    var logoURL: URL? { manifest.logo.flatMap(URL.init(string:)) }
    var manifestURL: URL { baseURL.appendingRawPath("manifest.json") }
}

struct StremioMetaPreview: Decodable, Hashable, Identifiable {
    var id: String
    var type: String
    var name: String
    var poster: URL?
    var posterShape: String?
    var background: URL?
    var logo: URL?
    var description: String?
    var releaseInfo: String?
    var imdbRating: Double?
    var genres: [String]
    var runtime: String?
    var videos: [StremioVideo]
    var imdbID: String?
    var links: [Link]
    var trailers: [Trailer]

    struct Link: Decodable, Hashable { var name: String?; var category: String?; var url: String? }
    struct Trailer: Decodable, Hashable { var source: String?; var type: String? }

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, posterShape, background, logo, description, releaseInfo, year, imdbRating
        case genres, genre, runtime, videos, imdb_id, links, trailers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = c.flexString(.type) ?? "movie"
        name = c.flexString(.name) ?? id
        poster = c.flexURL(.poster)
        posterShape = c.flexString(.posterShape)
        background = c.flexURL(.background)
        logo = c.flexURL(.logo)
        description = c.flexString(.description)
        releaseInfo = c.flexString(.releaseInfo) ?? c.flexString(.year)
        imdbRating = c.flexDouble(.imdbRating)
        genres = c.flexStringArray(.genres) + c.flexStringArray(.genre)
        runtime = c.flexString(.runtime)
        videos = (try? c.decode(LossyArray<StremioVideo>.self, forKey: .videos))?.elements ?? []
        imdbID = c.flexString(.imdb_id) ?? (id.hasPrefix("tt") ? id : nil)
        links = (try? c.decode(LossyArray<Link>.self, forKey: .links))?.elements ?? []
        trailers = (try? c.decode(LossyArray<Trailer>.self, forKey: .trailers))?.elements ?? []
    }

    var year: Int? { releaseInfo.flatMap { Int($0.prefix(4)) } }

    func mediaItem(addonID: String) -> MediaItem {
        MediaItem(
            id: id.hasPrefix("tt") ? id : "stremio:\(addonID):\(id)",
            type: MediaType(stremio: type),
            title: name,
            year: year,
            poster: poster,
            backdrop: background,
            logo: logo,
            overview: description,
            rating: imdbRating,
            genres: genres,
            imdbID: imdbID,
            origin: .stremio(addonID: addonID, metaID: id),
            runtimeMinutes: runtime.flatMap { Int($0.filter(\.isNumber)) })
    }
}

struct StremioVideo: Decodable, Hashable, Identifiable {
    var id: String
    var title: String
    var season: Int?
    var episode: Int?
    var released: String?
    var thumbnail: URL?
    var overview: String?

    enum CodingKeys: String, CodingKey { case id, title, name, season, episode, number, released, thumbnail, overview, description }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.flexString(.title) ?? c.flexString(.name) ?? id
        season = c.flexInt(.season)
        episode = c.flexInt(.episode) ?? c.flexInt(.number)
        released = c.flexString(.released)
        thumbnail = c.flexURL(.thumbnail)
        overview = c.flexString(.overview) ?? c.flexString(.description)
    }

    var episodeRef: EpisodeRef {
        EpisodeRef(id: id, season: season ?? 0, episode: episode ?? 0, title: title, overview: overview,
                   still: thumbnail, airDate: released.map { String($0.prefix(10)) }, stremioVideoID: id)
    }
}

struct StremioStream: Decodable, Hashable {
    struct Hints: Decodable, Hashable {
        var notWebReady: Bool?
        var bingeGroup: String?
        var filename: String?
        var videoSize: Int64?
        var requestHeaders: [String: String]?

        enum CodingKeys: String, CodingKey { case notWebReady, bingeGroup, filename, videoSize, proxyHeaders }
        enum ProxyKeys: String, CodingKey { case request }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            notWebReady = try? c.decodeIfPresent(Bool.self, forKey: .notWebReady)
            bingeGroup = try? c.decodeIfPresent(String.self, forKey: .bingeGroup)
            filename = try? c.decodeIfPresent(String.self, forKey: .filename)
            videoSize = (try? c.decodeIfPresent(Int64.self, forKey: .videoSize)) ?? c.flexInt(.videoSize).map(Int64.init)
            if let p = try? c.nestedContainer(keyedBy: ProxyKeys.self, forKey: .proxyHeaders) {
                requestHeaders = try? p.decodeIfPresent([String: String].self, forKey: .request)
            }
        }
    }

    var url: URL?
    var ytID: String?
    var infoHash: String?
    var fileIdx: Int?
    var externalURL: URL?
    var name: String?
    var title: String?
    var description: String?
    var sources: [String]
    var hints: Hints?
    var subtitles: [StremioSubtitle]

    enum CodingKeys: String, CodingKey {
        case url, ytId, infoHash, fileIdx, externalUrl, name, title, description, sources, behaviorHints, subtitles
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.flexURL(.url)
        ytID = c.flexString(.ytId)
        infoHash = c.flexString(.infoHash)?.lowercased()
        fileIdx = c.flexInt(.fileIdx)
        externalURL = c.flexURL(.externalUrl)
        name = c.flexString(.name)
        title = c.flexString(.title)
        description = c.flexString(.description)
        sources = c.flexStringArray(.sources)
        hints = try? c.decodeIfPresent(Hints.self, forKey: .behaviorHints)
        subtitles = (try? c.decode(LossyArray<StremioSubtitle>.self, forKey: .subtitles))?.elements ?? []
    }
}

struct StremioSubtitle: Decodable, Hashable, Identifiable {
    var id: String
    var url: URL
    var lang: String

    enum CodingKeys: String, CodingKey { case id, url, lang }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let u = c.flexURL(.url) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "no url")
        }
        url = u
        lang = c.flexString(.lang) ?? "und"
        id = c.flexString(.id) ?? u.absoluteString
    }
    init(id: String, url: URL, lang: String) { self.id = id; self.url = url; self.lang = lang }

    var languageName: String {
        Locale.current.localizedString(forLanguageCode: lang) ?? lang.uppercased()
    }
}
