import Foundation

// Models for Dispatcharr's Xtream Codes compatible API (player_api.php).
// Field shapes verified against Dispatcharr's apps/output/views.py.

struct XCAuthResponse: Decodable {
    struct UserInfo: Decodable {
        var auth: Bool
        var status: String?
        var expDate: Date?
        var maxConnections: Int?
        var activeConnections: Int?
        var message: String?

        enum CodingKeys: String, CodingKey {
            case auth, status, exp_date, max_connections, active_cons, message
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            auth = c.flexBool(.auth)
            status = c.flexString(.status)
            expDate = c.flexInt(.exp_date).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            maxConnections = c.flexInt(.max_connections)
            activeConnections = c.flexInt(.active_cons)
            message = c.flexString(.message)
        }
    }

    struct ServerInfo: Decodable {
        var timezone: String?
        var timestampNow: Int?
        enum CodingKeys: String, CodingKey { case timezone, timestamp_now }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            timezone = c.flexString(.timezone)
            timestampNow = c.flexInt(.timestamp_now)
        }
    }

    var userInfo: UserInfo?
    var serverInfo: ServerInfo?
    enum CodingKeys: String, CodingKey { case user_info, server_info }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userInfo = try? c.decodeIfPresent(UserInfo.self, forKey: .user_info)
        serverInfo = try? c.decodeIfPresent(ServerInfo.self, forKey: .server_info)
    }
}

struct XCCategory: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var parentID: String?

    enum CodingKeys: String, CodingKey { case category_id, category_name, parent_id }
    init(id: String, name: String, parentID: String? = nil) {
        self.id = id; self.name = name; self.parentID = parentID
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexString(.category_id) ?? "0"
        name = c.flexString(.category_name) ?? "Uncategorized"
        parentID = c.flexString(.parent_id)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .category_id)
        try c.encode(name, forKey: .category_name)
        try c.encodeIfPresent(parentID, forKey: .parent_id)
    }
}

struct XCChannel: Codable, Hashable, Identifiable {
    var id: Int
    var number: Int?
    var name: String
    var icon: URL?
    var epgChannelID: String?
    var categoryID: String
    var isRadio: Bool
    var isAdult: Bool
    var hasArchive: Bool
    var archiveDays: Int

    enum CodingKeys: String, CodingKey {
        case num, name, stream_type, stream_id, stream_icon, epg_channel_id, category_id
        case tv_archive, tv_archive_duration, is_adult
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let sid = c.flexInt(.stream_id) else {
            throw DecodingError.dataCorruptedError(forKey: .stream_id, in: c, debugDescription: "missing stream_id")
        }
        id = sid
        number = c.flexInt(.num)
        name = c.flexString(.name) ?? "Channel \(sid)"
        icon = c.flexURL(.stream_icon)
        epgChannelID = c.flexString(.epg_channel_id)
        categoryID = c.flexString(.category_id) ?? "0"
        isRadio = c.flexString(.stream_type) == "radio_streams"
        isAdult = c.flexBool(.is_adult)
        hasArchive = c.flexBool(.tv_archive)
        archiveDays = c.flexInt(.tv_archive_duration) ?? 0
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .stream_id)
        try c.encodeIfPresent(number, forKey: .num)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(icon?.absoluteString, forKey: .stream_icon)
        try c.encodeIfPresent(epgChannelID, forKey: .epg_channel_id)
        try c.encode(categoryID, forKey: .category_id)
        try c.encode(isRadio ? "radio_streams" : "live", forKey: .stream_type)
        try c.encode(isAdult ? 1 : 0, forKey: .is_adult)
        try c.encode(hasArchive ? 1 : 0, forKey: .tv_archive)
        try c.encode(archiveDays, forKey: .tv_archive_duration)
    }
}

struct XCMovie: Codable, Hashable, Identifiable {
    var id: Int
    var name: String
    var icon: URL?
    var rating: Double?
    var added: Int?
    var tmdbID: Int?
    var imdbID: String?
    var plot: String?
    var genre: String?
    var year: Int?
    var categoryID: String
    var ext: String
    var isAdult: Bool
    var director: String?
    var cast: String?
    var trailer: String?

    enum CodingKeys: String, CodingKey {
        case stream_id, name, stream_icon, rating, added, tmdb_id, imdb_id, plot, genre, year
        case category_id, container_extension, is_adult, director, cast, trailer, releasedate, release_date
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let sid = c.flexInt(.stream_id) else {
            throw DecodingError.dataCorruptedError(forKey: .stream_id, in: c, debugDescription: "missing stream_id")
        }
        id = sid
        name = c.flexString(.name) ?? "Untitled"
        icon = c.flexURL(.stream_icon)
        rating = c.flexDouble(.rating).flatMap { $0 > 0 ? $0 : nil }
        added = c.flexInt(.added)
        tmdbID = c.flexInt(.tmdb_id).flatMap { $0 > 0 ? $0 : nil }
        imdbID = c.flexString(.imdb_id)
        plot = c.flexString(.plot)
        genre = c.flexString(.genre)
        year = c.flexInt(.year) ?? (c.flexString(.release_date) ?? c.flexString(.releasedate)).flatMap { Int($0.prefix(4)) }
        categoryID = c.flexString(.category_id) ?? "0"
        ext = c.flexString(.container_extension) ?? "mp4"
        isAdult = c.flexBool(.is_adult)
        director = c.flexString(.director)
        cast = c.flexString(.cast)
        trailer = c.flexString(.trailer)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .stream_id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(icon?.absoluteString, forKey: .stream_icon)
        try c.encodeIfPresent(rating, forKey: .rating)
        try c.encodeIfPresent(added, forKey: .added)
        try c.encodeIfPresent(tmdbID, forKey: .tmdb_id)
        try c.encodeIfPresent(imdbID, forKey: .imdb_id)
        try c.encodeIfPresent(plot, forKey: .plot)
        try c.encodeIfPresent(genre, forKey: .genre)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encode(categoryID, forKey: .category_id)
        try c.encode(ext, forKey: .container_extension)
        try c.encode(isAdult ? 1 : 0, forKey: .is_adult)
        try c.encodeIfPresent(director, forKey: .director)
        try c.encodeIfPresent(cast, forKey: .cast)
        try c.encodeIfPresent(trailer, forKey: .trailer)
    }
}

struct XCSeries: Codable, Hashable, Identifiable {
    var id: Int
    var name: String
    var cover: URL?
    var backdrop: URL?
    var plot: String?
    var genre: String?
    var year: Int?
    var rating: Double?
    var categoryID: String
    var lastModified: Int?
    var tmdbID: Int?
    var imdbID: String?
    var cast: String?
    var trailer: String?

    enum CodingKeys: String, CodingKey {
        case series_id, name, cover, backdrop_path, plot, genre, release_date, releaseDate, rating
        case category_id, last_modified, tmdb_id, imdb_id, cast, youtube_trailer, year
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let sid = c.flexInt(.series_id) else {
            throw DecodingError.dataCorruptedError(forKey: .series_id, in: c, debugDescription: "missing series_id")
        }
        id = sid
        name = c.flexString(.name) ?? "Untitled"
        cover = c.flexURL(.cover)
        backdrop = c.flexStringArray(.backdrop_path).first.flatMap(URL.init(string:))
        plot = c.flexString(.plot)
        genre = c.flexString(.genre)
        let date = c.flexString(.release_date) ?? c.flexString(.releaseDate)
        year = c.flexInt(.year) ?? date.flatMap { Int($0.prefix(4)) }
        rating = c.flexDouble(.rating).flatMap { $0 > 0 ? $0 : nil }
        categoryID = c.flexString(.category_id) ?? "0"
        lastModified = c.flexInt(.last_modified)
        tmdbID = c.flexInt(.tmdb_id).flatMap { $0 > 0 ? $0 : nil }
        imdbID = c.flexString(.imdb_id)
        cast = c.flexString(.cast)
        trailer = c.flexString(.youtube_trailer)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .series_id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(cover?.absoluteString, forKey: .cover)
        try c.encodeIfPresent(backdrop.map { [$0.absoluteString] }, forKey: .backdrop_path)
        try c.encodeIfPresent(plot, forKey: .plot)
        try c.encodeIfPresent(genre, forKey: .genre)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encodeIfPresent(rating, forKey: .rating)
        try c.encode(categoryID, forKey: .category_id)
        try c.encodeIfPresent(lastModified, forKey: .last_modified)
        try c.encodeIfPresent(tmdbID, forKey: .tmdb_id)
        try c.encodeIfPresent(imdbID, forKey: .imdb_id)
        try c.encodeIfPresent(cast, forKey: .cast)
        try c.encodeIfPresent(trailer, forKey: .youtube_trailer)
    }
}

struct XCEpisode: Decodable, Hashable {
    var id: Int
    var season: Int
    var episode: Int
    var title: String
    var ext: String
    var plot: String?
    var image: URL?
    var durationSecs: Int?
    var airDate: String?
    var rating: Double?

    enum CodingKeys: String, CodingKey { case id, season, episode_num, title, container_extension, info }
    enum InfoKeys: String, CodingKey {
        case overview, plot, movie_image, duration_secs, air_date, releasedate, release_date, rating, name
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let eid = c.flexInt(.id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "missing id")
        }
        id = eid
        season = c.flexInt(.season) ?? 1
        episode = c.flexInt(.episode_num) ?? 0
        title = c.flexString(.title) ?? "Episode"
        ext = c.flexString(.container_extension) ?? "mp4"
        if let info = try? c.nestedContainer(keyedBy: InfoKeys.self, forKey: .info) {
            plot = info.flexString(.overview) ?? info.flexString(.plot)
            image = info.flexURL(.movie_image)
            durationSecs = info.flexInt(.duration_secs)
            airDate = info.flexString(.air_date) ?? info.flexString(.release_date) ?? info.flexString(.releasedate)
            rating = info.flexDouble(.rating).flatMap { $0 > 0 ? $0 : nil }
        }
    }
}

struct XCSeriesInfo: Decodable {
    struct Season: Decodable {
        var number: Int
        var name: String?
        var cover: URL?
        enum CodingKeys: String, CodingKey { case season_number, name, cover, cover_big }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            number = c.flexInt(.season_number) ?? 0
            name = c.flexString(.name)
            cover = c.flexURL(.cover_big) ?? c.flexURL(.cover)
        }
    }

    var seasons: [Season]
    var episodes: [Int: [XCEpisode]]
    var plot: String?
    var cover: URL?
    var backdrop: URL?
    var genre: String?
    var cast: String?
    var director: String?
    var trailer: String?
    var tmdbID: Int?
    var imdbID: String?
    var rating: Double?
    var releaseDate: String?

    enum CodingKeys: String, CodingKey { case seasons, episodes, info }
    enum InfoKeys: String, CodingKey {
        case plot, cover, backdrop_path, genre, cast, director, youtube_trailer, tmdb, imdb, rating, release_date
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasons = (try? c.decode(LossyArray<Season>.self, forKey: .seasons))?.elements ?? []
        var eps: [Int: [XCEpisode]] = [:]
        // Episodes come as {"1": [...], "2": [...]} or, from some panels, as a flat array.
        if let dict = try? c.nestedContainer(keyedBy: DynamicKey.self, forKey: .episodes) {
            for key in dict.allKeys {
                let list = (try? dict.decode(LossyArray<XCEpisode>.self, forKey: key))?.elements ?? []
                let s = Int(key.stringValue) ?? list.first?.season ?? 1
                eps[s, default: []].append(contentsOf: list)
            }
        } else if let flat = try? c.decode(LossyArray<XCEpisode>.self, forKey: .episodes) {
            for e in flat.elements { eps[e.season, default: []].append(e) }
        } else if let nested = try? c.decode([LossyArray<XCEpisode>].self, forKey: .episodes) {
            for list in nested { for e in list.elements { eps[e.season, default: []].append(e) } }
        }
        for k in eps.keys { eps[k]?.sort { $0.episode < $1.episode } }
        episodes = eps

        if let info = try? c.nestedContainer(keyedBy: InfoKeys.self, forKey: .info) {
            plot = info.flexString(.plot)
            cover = info.flexURL(.cover)
            backdrop = info.flexStringArray(.backdrop_path).first.flatMap(URL.init(string:))
            genre = info.flexString(.genre)
            cast = info.flexString(.cast)
            director = info.flexString(.director)
            trailer = info.flexString(.youtube_trailer)
            tmdbID = info.flexInt(.tmdb)
            imdbID = info.flexString(.imdb)
            rating = info.flexDouble(.rating)
            releaseDate = info.flexString(.release_date)
        }
    }
}

struct XCVODInfo: Decodable {
    var plot: String?
    var cover: URL?
    var backdrop: URL?
    var genre: String?
    var cast: String?
    var director: String?
    var trailer: String?
    var tmdbID: Int?
    var imdbID: String?
    var rating: Double?
    var durationSecs: Int?
    var country: String?
    var releaseDate: String?
    var ext: String?

    enum CodingKeys: String, CodingKey { case info, movie_data }
    enum InfoKeys: String, CodingKey {
        case plot, description, cover_big, movie_image, backdrop_path, genre, cast, actors, director
        case youtube_trailer, tmdb_id, imdb_id, rating, duration_secs, country, release_date
    }
    enum DataKeys: String, CodingKey { case container_extension }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let info = try? c.nestedContainer(keyedBy: InfoKeys.self, forKey: .info) {
            plot = info.flexString(.plot) ?? info.flexString(.description)
            cover = info.flexURL(.cover_big) ?? info.flexURL(.movie_image)
            backdrop = info.flexStringArray(.backdrop_path).first.flatMap(URL.init(string:))
            genre = info.flexString(.genre)
            cast = info.flexString(.cast) ?? info.flexString(.actors)
            director = info.flexString(.director)
            trailer = info.flexString(.youtube_trailer)
            tmdbID = info.flexInt(.tmdb_id)
            imdbID = info.flexString(.imdb_id)
            rating = info.flexDouble(.rating)
            durationSecs = info.flexInt(.duration_secs)
            country = info.flexString(.country)
            releaseDate = info.flexString(.release_date)
        }
        if let data = try? c.nestedContainer(keyedBy: DataKeys.self, forKey: .movie_data) {
            ext = data.flexString(.container_extension)
        }
    }
}

struct XCEPGListing: Decodable, Hashable, Identifiable {
    var id: String
    var title: String
    var description: String
    var start: Date
    var end: Date
    var hasArchive: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, description, start_timestamp, stop_timestamp, has_archive, start, end
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (c.flexString(.title) ?? "").base64Decoded
        description = (c.flexString(.description) ?? "").base64Decoded
        if let s = c.flexInt(.start_timestamp), let e = c.flexInt(.stop_timestamp) {
            start = Date(timeIntervalSince1970: TimeInterval(s))
            end = Date(timeIntervalSince1970: TimeInterval(e))
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.timeZone = TimeZone(identifier: "UTC")
            start = c.flexString(.start).flatMap(f.date(from:)) ?? .distantPast
            end = c.flexString(.end).flatMap(f.date(from:)) ?? .distantPast
        }
        hasArchive = c.flexBool(.has_archive)
        id = c.flexString(.id) ?? "\(Int(start.timeIntervalSince1970))"
    }

    init(id: String, title: String, description: String, start: Date, end: Date, hasArchive: Bool = false) {
        self.id = id; self.title = title; self.description = description
        self.start = start; self.end = end; self.hasArchive = hasArchive
    }

    var isLive: Bool { let now = Date(); return start <= now && now < end }
    var progress: Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return min(1, max(0, Date().timeIntervalSince(start) / total))
    }
    var timeRangeText: String {
        let f = DateFormatter(); f.timeStyle = .short
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }
}

struct XCEPGResponse: Decodable {
    var listings: [XCEPGListing]
    enum CodingKeys: String, CodingKey { case epg_listings }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        listings = (try? c.decode(LossyArray<XCEPGListing>.self, forKey: .epg_listings))?.elements ?? []
    }
}
