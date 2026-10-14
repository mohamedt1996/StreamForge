import Foundation

// REST streaming mode: for account / API-key users whose Dispatcharr user has no XC password.
//
// Dispatcharr's XC endpoints (player_api.php, xmltv.php, /live, /movie, /series, /timeshift) reject a
// user whose stored xc_password is empty, and only admins may set one (PATCH /api/accounts/users/{id}/
// is IsAdmin; /users/me/ strips xc_password). Everything else the app needs is available without it:
//
// - channels: /api/channels/channels/summary/ (IsStandardUser, filtered by the user's level) with
//   /api/channels/channels/ as fallback for older servers; groups: /api/channels/groups/
// - logos: /api/channels/logos/{id}/cache/ (AllowAny)
// - guide: /output/epg (no auth, "M3U / EPG" network setting) and /api/epg/programs/search/
// - movies / series: /api/vod/all/ (+ /api/vod/categories/), /api/vod/{movies|series}/{id}/provider-info/
// - playback: /proxy/ts/stream/{channel uuid}, /proxy/vod/{movie|episode}/{uuid} (AllowAny, "Streams"
//   network setting)
//
// The catalog converts those responses into the same XC models the rest of the app uses. Numeric ids
// are the ones the XC API uses too (Channel.id, Movie.id, Episode.id); series use Series.id.

/// Numeric Dispatcharr id → UUID, which the proxy URLs need. Persisted per server so Continue
/// Watching and episode playback work after a relaunch before anything is reloaded.
final class DispatcharrUUIDs: @unchecked Sendable {
    enum Kind: String { case channel = "c", movie = "m", episode = "e" }

    static let shared = DispatcharrUUIDs()
    private let lock = NSLock()
    private var maps: [UUID: [String: String]] = [:]

    private static func fileName(_ server: UUID) -> String { "dispatcharr-uuids-\(server.uuidString).json" }

    /// Call with the lock held.
    private func map(_ server: UUID) -> [String: String] {
        if let m = maps[server] { return m }
        let m = FileStore.load([String: String].self, Self.fileName(server)) ?? [:]
        maps[server] = m
        return m
    }

    func uuid(_ kind: Kind, _ id: Int, server: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return map(server)["\(kind.rawValue)\(id)"]
    }

    /// Records id → UUID pairs; saves the map when something changed.
    func record(_ kind: Kind, _ entries: [Int: String], server: UUID) {
        guard !entries.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var m = map(server)
        var changed = false
        for (id, uuid) in entries where !uuid.isEmpty {
            let key = "\(kind.rawValue)\(id)"
            if m[key] != uuid {
                m[key] = uuid
                changed = true
            }
        }
        guard changed else { return }
        maps[server] = m
        FileStore.save(m, Self.fileName(server))
    }

    func remove(server: UUID) {
        lock.lock()
        defer { lock.unlock() }
        maps[server] = nil
        FileStore.remove(Self.fileName(server))
    }
}

/// The VOD library in XC models.
struct RESTVODLibrary: Sendable {
    var movieCategories: [XCCategory]
    var movies: [XCMovie]
    var seriesCategories: [XCCategory]
    var series: [XCSeries]
}

/// Movies and series are loaded in one pass; this shares it between the four XC-style calls the
/// store makes in parallel.
private actor RESTVODCache {
    static let shared = RESTVODCache()
    private var entries: [UUID: (date: Date, task: Task<RESTVODLibrary, Error>)] = [:]

    func library(server: UUID, load: @escaping @Sendable () async throws -> RESTVODLibrary) async throws -> RESTVODLibrary {
        if let e = entries[server], Date().timeIntervalSince(e.date) < 120 {
            return try await e.task.value
        }
        let task = Task { try await load() }
        entries[server] = (Date(), task)
        do {
            return try await task.value
        } catch {
            entries[server] = nil
            throw error
        }
    }
}

struct DispatcharrRESTCatalog: Sendable {
    let server: DispatcharrServer
    let rest: DispatcharrREST

    private var base: URL {
        get throws {
            guard let u = server.url else { throw HTTPError.badURL(server.baseURL) }
            return u
        }
    }

    // MARK: JSON helpers

    private func json(_ path: String, _ query: [String: String?] = [:], timeout: TimeInterval? = nil) async throws -> Any {
        let data = try await rest.get(path, query: query, timeout: timeout)
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw HTTPError.decoding("\(path): not JSON")
        }
        return obj
    }

    private static func objects(_ v: Any?) -> [[String: Any]] {
        (v as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// A plain JSON list, or every page of a paginated one ({results, next}; `next` is a URL in DRF
    /// pages and a Bool in /api/vod/all/).
    private func list(_ path: String, _ query: [String: String?] = [:], timeout: TimeInterval? = nil, maxPages: Int = 1000) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var q = query
        var page = Int(query["page"].flatMap { $0 } ?? "") ?? 1
        while true {
            let root = try await json(path, q, timeout: timeout)
            if root is [Any] { return out + Self.objects(root) }
            guard let obj = root as? [String: Any], obj["results"] != nil else { return out }
            let results = Self.objects(obj["results"])
            out += results
            var more = false
            if let next = obj["next"] as? String {
                more = !next.isEmpty
            } else if let next = obj["next"] as? NSNumber {
                more = next.boolValue
            }
            guard more, !results.isEmpty, page < maxPages else { return out }
            page += 1
            q["page"] = String(page)
        }
    }

    private static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }

    /// Absolute URL string for a possibly relative server path.
    private func absolute(_ s: String?) -> String? {
        guard let s = s?.trimmed, !s.isEmpty else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return s }
        return (try? base.appendingRawPath(s).absoluteString)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func date(_ v: Any?) -> Date? {
        guard let s = JSONValue.string(v) else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    private static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmed) }
        return nil
    }

    /// Copies the JSON-safe value (drops null / empty strings).
    private static func put(_ d: inout [String: Any], _ key: String, _ value: Any?) {
        guard let value, !(value is NSNull) else { return }
        if let s = value as? String, s.isEmpty { return }
        d[key] = value
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ rows: [[String: Any]]) -> [T] {
        guard JSONSerialization.isValidJSONObject(rows),
              let data = try? JSONSerialization.data(withJSONObject: rows),
              let list = try? JSONDecoder().decode(LossyArray<T>.self, from: data) else { return [] }
        return list.elements
    }

    private static func decodeOne<T: Decodable>(_ type: T.Type, _ obj: [String: Any]) throws -> T {
        guard JSONSerialization.isValidJSONObject(obj) else { throw HTTPError.decoding("invalid JSON object") }
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Live

    func liveCategories() async throws -> [XCCategory] {
        try await list("api/channels/groups/").compactMap { g -> XCCategory? in
            guard let id = JSONValue.int(g["id"]) else { return nil }
            return XCCategory(id: String(id), name: JSONValue.string(g["name"]) ?? "Group \(id)")
        }
    }

    /// The channels this user may watch. Non-admins restricted to channel profiles get the union of
    /// those profiles, like Dispatcharr's own XC output.
    func liveChannels() async throws -> [XCChannel] {
        var profileIDs: [Int] = []
        if let me = try? await rest.me(), (me.userLevel ?? 0) < 10 { profileIDs = me.channelProfileIDs }
        var rows: [[String: Any]] = []
        if profileIDs.isEmpty {
            rows = try await channelRows(profileID: nil)
        } else {
            var seen = Set<Int>()
            for pid in profileIDs {
                for row in try await channelRows(profileID: pid) {
                    if let id = JSONValue.int(row["id"]), seen.insert(id).inserted { rows.append(row) }
                }
            }
        }
        var uuids: [Int: String] = [:]
        var xc: [[String: Any]] = []
        xc.reserveCapacity(rows.count)
        for row in rows {
            guard let id = JSONValue.int(row["id"]) else { continue }
            if let uuid = JSONValue.string(row["uuid"]) { uuids[id] = uuid } else { continue }
            var d: [String: Any] = ["stream_id": id, "name": JSONValue.string(row["name"]) ?? "Channel \(id)",
                                    "stream_type": "live", "tv_archive": 0, "tv_archive_duration": 0]
            let number = Self.double(row["channel_number"])
            if let number { d["num"] = Int(number) }
            // /output/epg names channels by their number (or the channel id when there's none).
            if let number {
                d["epg_channel_id"] = number.rounded() == number ? String(Int(number)) : String(number)
            } else {
                d["epg_channel_id"] = String(id)
            }
            let group = JSONValue.int(row["channel_group_id"]) ?? JSONValue.int(Self.dict(row["channel_group"])?["id"])
                ?? JSONValue.int(row["channel_group"])
            if let group { d["category_id"] = String(group) }
            let logo = JSONValue.int(row["logo_id"]) ?? JSONValue.int(Self.dict(row["logo"])?["id"]) ?? JSONValue.int(row["logo"])
            if let logo, let url = absolute("api/channels/logos/\(logo)/cache/") { d["stream_icon"] = url }
            if let adult = row["is_adult"] as? NSNumber { d["is_adult"] = adult.boolValue ? 1 : 0 }
            xc.append(d)
        }
        DispatcharrUUIDs.shared.record(.channel, uuids, server: server.id)
        return Self.decode(XCChannel.self, xc)
    }

    /// The lightweight summary endpoint (newer Dispatcharr), else the full channel list.
    private func channelRows(profileID: Int?) async throws -> [[String: Any]] {
        let q: [String: String?] = ["channel_profile_id": profileID.map { String($0) }]
        do {
            return try await list("api/channels/channels/summary/", q, timeout: 120)
        } catch HTTPError.status(let code, _) where code == 404 || code == 405 {
            return try await list("api/channels/channels/", q, timeout: 180)
        }
    }

    /// Upcoming (or, with `includePast`, the last day's and upcoming) programmes for one channel.
    func programmes(channelID: Int, limit: Int, includePast: Bool) async throws -> [XCEPGListing] {
        let from = includePast ? Date().addingTimeInterval(-86_400) : Date()
        let rows = try await list("api/epg/programs/search/",
                                  ["channel_id": String(channelID), "end_after": Self.isoPlain.string(from: from),
                                   "page_size": String(min(500, max(1, limit)))],
                                  maxPages: 1)
        return rows.compactMap { r -> XCEPGListing? in
            guard let start = Self.date(r["start_time"]), let end = Self.date(r["end_time"]) else { return nil }
            var l = XCEPGListing(id: JSONValue.string(r["id"]) ?? "\(Int(start.timeIntervalSince1970))",
                                 title: JSONValue.string(r["title"]) ?? "",
                                 description: JSONValue.string(r["description"]) ?? "",
                                 start: start, end: end)
            l.subtitle = JSONValue.string(r["sub_title"])
            return l
        }
        .sorted { $0.start < $1.start }
    }

    // MARK: VOD

    func vodLibrary() async throws -> RESTVODLibrary {
        let catalog = self
        return try await RESTVODCache.shared.library(server: server.id) { try await catalog.loadVODLibrary() }
    }

    private func loadVODLibrary() async throws -> RESTVODLibrary {
        let categories = (try? await list("api/vod/categories/")) ?? []
        let items = try await vodItems()

        // Category membership: /api/vod/all/ filtered per category ("name|type").
        var movieCats: [XCCategory] = []
        var seriesCats: [XCCategory] = []
        var jobs: [(id: String, filter: String, isSeries: Bool)] = []
        for c in categories {
            guard let id = JSONValue.int(c["id"]), let name = JSONValue.string(c["name"]) else { continue }
            let type = (JSONValue.string(c["category_type"]) ?? "movie").lowercased()
            let isSeries = type == "series"
            let cat = XCCategory(id: String(id), name: name)
            if isSeries { seriesCats.append(cat) } else { movieCats.append(cat) }
            jobs.append((String(id), "\(name)|\(isSeries ? "series" : "movie")", isSeries))
        }
        var movieCategory: [Int: String] = [:]
        var seriesCategory: [Int: String] = [:]
        let catalog = self
        await withTaskGroup(of: (catID: String, isSeries: Bool, ids: [Int]).self) { group in
            var index = 0
            while index < min(6, jobs.count) {
                let job = jobs[index]
                index += 1
                group.addTask { await catalog.categoryMembers(job.id, filter: job.filter, isSeries: job.isSeries) }
            }
            while let result = await group.next() {
                for id in result.ids {
                    if result.isSeries {
                        if seriesCategory[id] == nil { seriesCategory[id] = result.catID }
                    } else if movieCategory[id] == nil {
                        movieCategory[id] = result.catID
                    }
                }
                if index < jobs.count {
                    let job = jobs[index]
                    index += 1
                    group.addTask { await catalog.categoryMembers(job.id, filter: job.filter, isSeries: job.isSeries) }
                }
            }
        }

        var movieRows: [[String: Any]] = []
        var seriesRows: [[String: Any]] = []
        var movieUUIDs: [Int: String] = [:]
        for item in items {
            guard let id = JSONValue.int(item["id"]) else { continue }
            let props = Self.dict(item["custom_properties"]) ?? [:]
            let isSeries = (JSONValue.string(item["content_type"]) ?? "movie") == "series"
            var d: [String: Any] = ["name": JSONValue.string(item["name"]) ?? "Untitled"]
            Self.put(&d, "genre", JSONValue.string(item["genre"]))
            Self.put(&d, "year", JSONValue.int(item["year"]))
            if let r = Self.double(item["rating"]), r > 0 { d["rating"] = r }
            Self.put(&d, "tmdb_id", JSONValue.string(item["tmdb_id"]) ?? JSONValue.string(props["tmdb_id"]))
            Self.put(&d, "imdb_id", JSONValue.string(item["imdb_id"]) ?? JSONValue.string(props["imdb_id"]))
            Self.put(&d, "plot", JSONValue.string(item["description"]) ?? JSONValue.string(props["plot"]))
            let art = poster(item, props)
            if isSeries {
                d["series_id"] = id
                d["category_id"] = seriesCategory[id] ?? "0"
                Self.put(&d, "cover", art)
                if let backdrop = Self.backdrop(props) { d["backdrop_path"] = [backdrop] }
                if let t = Self.date(item["updated_at"]) ?? Self.date(item["created_at"]) { d["last_modified"] = Int(t.timeIntervalSince1970) }
                seriesRows.append(d)
            } else {
                d["stream_id"] = id
                d["category_id"] = movieCategory[id] ?? "0"
                Self.put(&d, "stream_icon", art)
                Self.put(&d, "container_extension", JSONValue.string(props["container_extension"]))
                if let t = Self.date(item["created_at"]) { d["added"] = Int(t.timeIntervalSince1970) }
                if let adult = item["is_adult"] as? NSNumber { d["is_adult"] = adult.boolValue ? 1 : 0 }
                if let uuid = JSONValue.string(item["uuid"]) { movieUUIDs[id] = uuid }
                movieRows.append(d)
            }
        }
        DispatcharrUUIDs.shared.record(.movie, movieUUIDs, server: server.id)
        if movieRows.contains(where: { ($0["category_id"] as? String) == "0" }) {
            movieCats.append(XCCategory(id: "0", name: "Uncategorized"))
        }
        if seriesRows.contains(where: { ($0["category_id"] as? String) == "0" }) {
            seriesCats.append(XCCategory(id: "0", name: "Uncategorized"))
        }
        return RESTVODLibrary(movieCategories: movieCats, movies: Self.decode(XCMovie.self, movieRows),
                              seriesCategories: seriesCats, series: Self.decode(XCSeries.self, seriesRows))
    }

    /// Ids of the movies (or series) in one VOD category.
    private func categoryMembers(_ catID: String, filter: String, isSeries: Bool) async -> (catID: String, isSeries: Bool, ids: [Int]) {
        let rows = (try? await list("api/vod/all/", ["category": filter, "page_size": "5000"], timeout: 120)) ?? []
        let wanted = isSeries ? "series" : "movie"
        let ids = rows.filter { (JSONValue.string($0["content_type"]) ?? wanted) == wanted }.compactMap { JSONValue.int($0["id"]) }
        return (catID, isSeries, ids)
    }

    /// Every movie and series. /api/vod/all/ (one query, any page size) on current Dispatcharr;
    /// the paginated per-type endpoints on servers that don't have it.
    private func vodItems() async throws -> [[String: Any]] {
        do {
            return try await list("api/vod/all/", ["page_size": "5000"], timeout: 180)
        } catch HTTPError.status(let code, _) where code == 404 || code == 405 {
            var out: [[String: Any]] = []
            for (path, type) in [("api/vod/movies/", "movie"), ("api/vod/series/", "series")] {
                let rows = (try? await list(path, ["page_size": "100"], timeout: 120)) ?? []
                out += rows.map { row -> [String: Any] in
                    var r = row
                    r["content_type"] = type
                    return r
                }
            }
            return out
        }
    }

    /// Poster: the provider's own image URL when it's absolute, else Dispatcharr's cached copy.
    private func poster(_ item: [String: Any], _ props: [String: Any]) -> String? {
        if let logo = Self.dict(item["logo"]) {
            if let url = JSONValue.string(logo["url"]), url.hasPrefix("http") { return url }
            if let cached = absolute(JSONValue.string(logo["cache_url"])) { return cached }
        }
        for key in ["cover_big", "movie_image", "cover", "poster", "logo_url"] {
            if let url = JSONValue.string(props[key]) ?? JSONValue.string(item[key]), url.hasPrefix("http") { return url }
        }
        return nil
    }

    private static func backdrop(_ props: [String: Any]) -> String? {
        if let list = props["backdrop_path"] as? [Any] {
            return list.compactMap { JSONValue.string($0) }.first { $0.hasPrefix("http") }
        }
        return JSONValue.string(props["backdrop_path"]).flatMap { $0.hasPrefix("http") ? $0 : nil }
    }

    /// Looks up UUIDs this device hasn't recorded yet.
    func resolveUUIDs(movieID: Int?, episodeID: Int?) async {
        let uuids = DispatcharrUUIDs.shared
        if let id = movieID, uuids.uuid(.movie, id, server: server.id) == nil,
           let d = Self.dict(try? await json("api/vod/movies/\(id)/")), let uuid = JSONValue.string(d["uuid"]) {
            uuids.record(.movie, [id: uuid], server: server.id)
        }
        if let id = episodeID, uuids.uuid(.episode, id, server: server.id) == nil,
           let d = Self.dict(try? await json("api/vod/episodes/\(id)/")), let uuid = JSONValue.string(d["uuid"]) {
            uuids.record(.episode, [id: uuid], server: server.id)
        }
    }

    func movieInfo(_ id: Int) async throws -> XCVODInfo {
        let d: [String: Any]
        do {
            d = Self.dict(try await json("api/vod/movies/\(id)/provider-info/", timeout: 60)) ?? [:]
        } catch {
            d = Self.dict(try await json("api/vod/movies/\(id)/")) ?? [:]
        }
        let props = Self.dict(d["custom_properties"]) ?? [:]
        if JSONValue.int(d["id"]) == id, let uuid = JSONValue.string(d["uuid"]) {
            DispatcharrUUIDs.shared.record(.movie, [id: uuid], server: server.id)
        }
        func value(_ key: String) -> Any? {
            if let v = d[key], !(v is NSNull) { return v }
            return props[key]
        }
        var info: [String: Any] = [:]
        Self.put(&info, "plot", JSONValue.string(value("plot")) ?? JSONValue.string(value("description")))
        Self.put(&info, "cover_big", JSONValue.string(value("cover_big")) ?? JSONValue.string(value("movie_image"))
                 ?? Self.dict(d["logo"]).flatMap { JSONValue.string($0["url"]) })
        if let list = value("backdrop_path") as? [Any] {
            let urls = list.compactMap { JSONValue.string($0) }
            if !urls.isEmpty { info["backdrop_path"] = urls }
        } else if let one = JSONValue.string(value("backdrop_path")) {
            info["backdrop_path"] = [one]
        }
        for key in ["genre", "director", "youtube_trailer", "country", "release_date", "imdb_id"] {
            Self.put(&info, key, JSONValue.string(value(key)))
        }
        Self.put(&info, "actors", JSONValue.string(value("actors")) ?? JSONValue.string(value("cast")))
        Self.put(&info, "tmdb_id", JSONValue.int(value("tmdb_id")))
        Self.put(&info, "rating", Self.double(value("rating")))
        Self.put(&info, "duration_secs", JSONValue.int(value("duration_secs")))
        var root: [String: Any] = ["info": info]
        if let ext = JSONValue.string(value("container_extension")) { root["movie_data"] = ["container_extension": ext] }
        return try Self.decodeOne(XCVODInfo.self, root)
    }

    func seriesInfo(_ id: Int) async throws -> XCSeriesInfo {
        var d: [String: Any] = [:]
        do {
            d = Self.dict(try await json("api/vod/series/\(id)/provider-info/", ["include_episodes": "true"], timeout: 120)) ?? [:]
        } catch {
            d = Self.dict(try? await json("api/vod/series/\(id)/")) ?? [:]
        }
        let props = Self.dict(d["custom_properties"]) ?? [:]
        func value(_ key: String) -> Any? {
            if let v = d[key], !(v is NSNull) { return v }
            return props[key]
        }

        // Episodes: {"1": [...], "2": [...]} from provider-info, else the flat /episodes/ list.
        var raw: [(season: Int?, row: [String: Any])] = []
        if let bySeason = Self.dict(d["episodes"]), !bySeason.isEmpty {
            for (key, list) in bySeason {
                for row in Self.objects(list) { raw.append((Int(key), row)) }
            }
        } else if let flat = try? await list("api/vod/series/\(id)/episodes/", timeout: 120) {
            raw = flat.map { (season: Int?.none, row: $0) }
        }
        guard !raw.isEmpty || !d.isEmpty else { throw HTTPError.decoding("series \(id): no data") }

        var uuids: [Int: String] = [:]
        var episodes: [String: [[String: Any]]] = [:]
        for (seasonKey, row) in raw {
            guard let eid = JSONValue.int(row["id"]) else { continue }
            if let uuid = JSONValue.string(row["uuid"]) { uuids[eid] = uuid }
            let eprops = Self.dict(row["custom_properties"]) ?? [:]
            let season = JSONValue.int(row["season_number"]) ?? seasonKey ?? 1
            var e: [String: Any] = ["id": eid, "season": season,
                                    "episode_num": JSONValue.int(row["episode_number"]) ?? 0,
                                    "title": JSONValue.string(row["title"]) ?? JSONValue.string(row["name"]) ?? "Episode",
                                    "container_extension": JSONValue.string(row["container_extension"])
                                        ?? JSONValue.string(eprops["container_extension"]) ?? "mp4"]
            var info: [String: Any] = [:]
            Self.put(&info, "plot", JSONValue.string(row["plot"]) ?? JSONValue.string(row["description"]))
            Self.put(&info, "movie_image", JSONValue.string(row["movie_image"]) ?? JSONValue.string(eprops["movie_image"]))
            Self.put(&info, "duration_secs", JSONValue.int(row["duration_secs"]))
            Self.put(&info, "air_date", JSONValue.string(row["air_date"]))
            Self.put(&info, "rating", Self.double(row["rating"]))
            e["info"] = info
            episodes[String(season), default: []].append(e)
        }
        DispatcharrUUIDs.shared.record(.episode, uuids, server: server.id)

        var info: [String: Any] = [:]
        Self.put(&info, "plot", JSONValue.string(value("description")) ?? JSONValue.string(value("plot")))
        Self.put(&info, "cover", JSONValue.string(value("cover")) ?? Self.dict(d["logo"]).flatMap { JSONValue.string($0["url"]) })
        if let list = value("backdrop_path") as? [Any] {
            let urls = list.compactMap { JSONValue.string($0) }
            if !urls.isEmpty { info["backdrop_path"] = urls }
        } else if let one = JSONValue.string(value("backdrop_path")) {
            info["backdrop_path"] = [one]
        }
        for key in ["genre", "cast", "director", "youtube_trailer", "release_date"] {
            Self.put(&info, key, JSONValue.string(value(key)))
        }
        Self.put(&info, "tmdb", JSONValue.int(value("tmdb_id")))
        Self.put(&info, "imdb", JSONValue.string(value("imdb_id")))
        Self.put(&info, "rating", Self.double(value("rating")))
        return try Self.decodeOne(XCSeriesInfo.self, ["info": info, "episodes": episodes])
    }
}
