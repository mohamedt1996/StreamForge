import Foundation
import Observation

/// A category group, e.g. all "EN | ..." VOD categories under "EN".
struct CategorySection: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var categories: [XCCategory]
}

enum LoadState: Equatable {
    case idle, loading, loaded, failed(String)
}

/// Owns everything loaded from the active Dispatcharr server, cached on disk for instant start.
@MainActor
@Observable
final class DispatcharrStore {
    static let shared = DispatcharrStore()

    private(set) var servers: [DispatcharrServer] = []
    var activeServerID: UUID? {
        didSet { UserDefaults.standard.set(activeServerID?.uuidString, forKey: "dispatcharr.active") }
    }

    // Live
    private(set) var liveCategories: [XCCategory] = []
    private(set) var channels: [XCChannel] = []
    private(set) var channelsByCategory: [String: [XCChannel]] = [:]
    // VOD
    private(set) var movieCategories: [XCCategory] = []
    private(set) var movies: [XCMovie] = []
    private(set) var seriesCategories: [XCCategory] = []
    private(set) var series: [XCSeries] = []
    // Derived
    private(set) var movieGenres: [String] = []
    private(set) var seriesGenres: [String] = []
    private(set) var movieSections: [CategorySection] = []
    private(set) var seriesSections: [CategorySection] = []

    private(set) var liveState: LoadState = .idle
    private(set) var vodState: LoadState = .idle
    private(set) var lastRefresh: Date?

    private var epgCache: [Int: (Date, [XCEPGListing])] = [:]
    private var epgInFlight: [Int: Task<[XCEPGListing], Never>] = [:]
    private var rest: DispatcharrREST?

    var activeServer: DispatcharrServer? {
        servers.first { $0.id == activeServerID } ?? servers.first
    }
    var client: XtreamClient? { activeServer.map(XtreamClient.init(server:)) }
    var isConfigured: Bool { activeServer != nil }

    private init() {
        servers = FileStore.load([DispatcharrServer].self, "dispatcharr-servers.json") ?? []
        if let s = UserDefaults.standard.string(forKey: "dispatcharr.active") { activeServerID = UUID(uuidString: s) }
        loadDiskCache()
    }

    // MARK: Server management

    func upsert(_ server: DispatcharrServer, xcPassword: String, webPassword: String) {
        server.xcPassword = xcPassword
        server.webPassword = webPassword
        if let i = servers.firstIndex(where: { $0.id == server.id }) {
            servers[i] = server
        } else {
            servers.append(server)
        }
        FileStore.save(servers, "dispatcharr-servers.json", mirrorToDefaults: true)
        activate(server.id)
    }

    func remove(_ server: DispatcharrServer) {
        servers.removeAll { $0.id == server.id }
        server.xcPassword = ""
        server.webPassword = ""
        FileStore.save(servers, "dispatcharr-servers.json", mirrorToDefaults: true)
        FileStore.remove(cacheName(server.id))
        if activeServerID == server.id {
            activeServerID = servers.first?.id
            clear()
            loadDiskCache()
        }
    }

    func activate(_ id: UUID) {
        activeServerID = id
        rest = nil
        clear()
        loadDiskCache()
        Task { await refreshAll() }
    }

    func restClient() -> DispatcharrREST? {
        guard let server = activeServer, !server.webPassword.isEmpty else { return nil }
        if let rest { return rest }
        let r = DispatcharrREST(server: server)
        rest = r
        return r
    }

    private func clear() {
        liveCategories = []; channels = []; channelsByCategory = [:]
        movieCategories = []; movies = []; seriesCategories = []; series = []
        movieGenres = []; seriesGenres = []; movieSections = []; seriesSections = []
        epgCache = [:]
        liveState = .idle; vodState = .idle
    }

    // MARK: Loading

    func refreshAll(force: Bool = false) async {
        guard let client else { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 15 * 60, !channels.isEmpty { return }
        async let live: Void = refreshLive(client)
        async let vod: Void = refreshVOD(client)
        _ = await (live, vod)
        lastRefresh = Date()
        saveDiskCache()
    }

    private func refreshLive(_ client: XtreamClient) async {
        if channels.isEmpty { liveState = .loading }
        do {
            async let cats = client.liveCategories()
            async let chans = client.liveChannels()
            let (c, ch) = try await (cats, chans)
            applyLive(categories: c, channels: ch)
            liveState = .loaded
        } catch {
            liveState = channels.isEmpty ? .failed(error.localizedDescription) : .loaded
        }
    }

    private func refreshVOD(_ client: XtreamClient) async {
        if movies.isEmpty && series.isEmpty { vodState = .loading }
        do {
            async let mc = client.vodCategories()
            async let m = client.movies()
            async let sc = client.seriesCategories()
            async let s = client.series()
            let (mcv, mv) = try await (mc, m)
            let (scv, sv) = try await (sc, s)
            applyVOD(movieCategories: mcv, movies: mv, seriesCategories: scv, series: sv)
            vodState = .loaded
        } catch {
            vodState = (movies.isEmpty && series.isEmpty) ? .failed(error.localizedDescription) : .loaded
        }
    }

    private func applyLive(categories: [XCCategory], channels newChannels: [XCChannel]) {
        let hideAdult = AppSettings.shared.values.hideAdult
        let visible = newChannels.filter { !(hideAdult && $0.isAdult) }
        channels = visible.sorted { ($0.number ?? Int.max, $0.name) < ($1.number ?? Int.max, $1.name) }
        channelsByCategory = Dictionary(grouping: channels, by: \.categoryID)
        liveCategories = categories.filter { channelsByCategory[$0.id]?.isEmpty == false }
        // Channels whose category is missing still need a home.
        let known = Set(liveCategories.map(\.id))
        if channels.contains(where: { !known.contains($0.categoryID) }) {
            let orphans = channels.filter { !known.contains($0.categoryID) }
            channelsByCategory["__other"] = orphans
            liveCategories.append(XCCategory(id: "__other", name: "Other"))
        }
    }

    private func applyVOD(movieCategories mc: [XCCategory], movies mv: [XCMovie], seriesCategories sc: [XCCategory], series sv: [XCSeries]) {
        let hideAdult = AppSettings.shared.values.hideAdult
        movies = dedupeMovies(mv.filter { !(hideAdult && $0.isAdult) })
        series = dedupeSeries(sv)
        let movieCats = Set(movies.map(\.categoryID))
        let seriesCats = Set(series.map(\.categoryID))
        movieCategories = mc.filter { movieCats.contains($0.id) }
        seriesCategories = sc.filter { seriesCats.contains($0.id) }
        movieGenres = Self.genres(movies.compactMap(\.genre))
        seriesGenres = Self.genres(series.compactMap(\.genre))
        movieSections = Self.sections(movieCategories)
        seriesSections = Self.sections(seriesCategories)
    }

    /// Providers often list the same film in several categories; keep one per TMDB/IMDb id or title+year.
    private func dedupeMovies(_ list: [XCMovie]) -> [XCMovie] {
        var seen = Set<String>()
        var out: [XCMovie] = []
        out.reserveCapacity(list.count)
        for m in list {
            let key: String
            if let t = m.tmdbID { key = "tmdb\(t)" }
            else if let i = m.imdbID, !i.isEmpty { key = i }
            else { let c = TitleCleaner.clean(m.name); key = "\(c.title.lowercased())|\(c.year ?? m.year ?? 0)" }
            if seen.insert(key).inserted { out.append(m) }
        }
        return out
    }

    private func dedupeSeries(_ list: [XCSeries]) -> [XCSeries] {
        var seen = Set<String>()
        return list.filter { s in
            let key = s.tmdbID.map { "tmdb\($0)" } ?? "\(TitleCleaner.clean(s.name).title.lowercased())|\(s.year ?? 0)"
            return seen.insert(key).inserted
        }
    }

    private static func genres(_ raw: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for g in raw {
            for part in g.split(whereSeparator: { ",/|&".contains($0) }) {
                let name = part.trimmed.capitalized
                if name.count > 1, name.count < 24 { counts[name, default: 0] += 1 }
            }
        }
        return counts.filter { $0.value >= 3 }.sorted { $0.value > $1.value }.map(\.key)
    }

    /// Groups "EN | Action", "EN | Drama", "FR | Action" into sections EN and FR.
    private static func sections(_ cats: [XCCategory]) -> [CategorySection] {
        var order: [String] = []
        var groups: [String: [XCCategory]] = [:]
        for c in cats {
            let group = TitleCleaner.splitCategory(c.name).group ?? "All"
            if groups[group] == nil { order.append(group) }
            groups[group, default: []].append(c)
        }
        // Only split into sections when it actually organizes things.
        if order.count <= 1 || order.count > 40 { return [CategorySection(name: "All", categories: cats)] }
        return order.map { CategorySection(name: $0, categories: groups[$0] ?? []) }
    }

    // MARK: Lookups

    func channel(_ id: Int) -> XCChannel? { channels.first { $0.id == id } }

    func movies(in categoryID: String) -> [XCMovie] { movies.filter { $0.categoryID == categoryID } }
    func series(in categoryID: String) -> [XCSeries] { series.filter { $0.categoryID == categoryID } }

    func categoryName(_ id: String, kind: MediaType) -> String {
        let list = kind == .series ? seriesCategories : (kind == .channel ? liveCategories : movieCategories)
        let raw = list.first { $0.id == id }?.name ?? ""
        return TitleCleaner.splitCategory(raw).name
    }

    /// Finds a Dispatcharr VOD that matches a TMDB/IMDb item so Stremio/TMDB detail pages can offer
    /// "Play from your server" alongside addon streams.
    func matchMovie(tmdbID: Int?, imdbID: String?, title: String, year: Int?) -> XCMovie? {
        if let tmdbID, let m = movies.first(where: { $0.tmdbID == tmdbID }) { return m }
        if let imdbID, let m = movies.first(where: { $0.imdbID == imdbID }) { return m }
        let wanted = title.lowercased()
        return movies.first { m in
            let c = TitleCleaner.clean(m.name)
            return c.title.lowercased() == wanted && (year == nil || (c.year ?? m.year) == nil || (c.year ?? m.year) == year)
        }
    }

    func matchSeries(tmdbID: Int?, imdbID: String?, title: String) -> XCSeries? {
        if let tmdbID, let s = series.first(where: { $0.tmdbID == tmdbID }) { return s }
        if let imdbID, let s = series.first(where: { $0.imdbID == imdbID }) { return s }
        let wanted = title.lowercased()
        return series.first { TitleCleaner.clean($0.name).title.lowercased() == wanted }
    }

    // MARK: EPG

    func epg(for channelID: Int) -> [XCEPGListing] {
        epgCache[channelID]?.1 ?? []
    }

    func nowPlaying(_ channelID: Int) -> XCEPGListing? {
        epg(for: channelID).first { $0.isLive }
    }

    func nextUp(_ channelID: Int) -> XCEPGListing? {
        let now = Date()
        return epg(for: channelID).filter { $0.start > now }.min { $0.start < $1.start }
    }

    /// Loads (and caches for 10 minutes) the programme list for one channel.
    @discardableResult
    func loadEPG(_ channelID: Int, full: Bool = false) async -> [XCEPGListing] {
        if case let (date, list)? = epgCache[channelID], Date().timeIntervalSince(date) < 600,
           !list.isEmpty, (!full || list.count > 12) {
            return list
        }
        if let running = epgInFlight[channelID] { return await running.value }
        guard let client else { return [] }
        let task = Task<[XCEPGListing], Never> {
            let list = (try? await (full ? client.fullEPG(channelID: channelID) : client.shortEPG(channelID: channelID, limit: 12))) ?? []
            return list.sorted { $0.start < $1.start }
        }
        epgInFlight[channelID] = task
        let list = await task.value
        epgInFlight[channelID] = nil
        epgCache[channelID] = (Date(), list)
        return list
    }

    // MARK: Disk cache

    private struct DiskCache: Codable {
        var liveCategories: [XCCategory]
        var channels: [XCChannel]
        var movieCategories: [XCCategory]
        var movies: [XCMovie]
        var seriesCategories: [XCCategory]
        var series: [XCSeries]
        var savedAt: Date
    }

    private func cacheName(_ id: UUID) -> String { "dispatcharr-cache-\(id.uuidString).json" }

    private func loadDiskCache() {
        guard let id = activeServer?.id, let cache = FileStore.load(DiskCache.self, cacheName(id)) else { return }
        applyLive(categories: cache.liveCategories, channels: cache.channels)
        applyVOD(movieCategories: cache.movieCategories, movies: cache.movies, seriesCategories: cache.seriesCategories, series: cache.series)
        liveState = .loaded
        vodState = .loaded
    }

    private func saveDiskCache() {
        guard let id = activeServer?.id else { return }
        let cache = DiskCache(liveCategories: liveCategories.filter { $0.id != "__other" }, channels: channels,
                              movieCategories: movieCategories, movies: movies,
                              seriesCategories: seriesCategories, series: series, savedAt: Date())
        let name = cacheName(id)
        Task.detached(priority: .utility) { FileStore.save(cache, name) }
    }
}

// MARK: - Mapping to MediaItem

extension XCMovie {
    func mediaItem(serverID: UUID) -> MediaItem {
        let c = TitleCleaner.clean(name)
        return MediaItem(
            id: "xc:\(serverID.uuidString.prefix(8)):movie:\(id)",
            type: .movie,
            title: c.title,
            year: year ?? c.year,
            poster: icon,
            backdrop: nil,
            overview: plot,
            rating: rating,
            genres: genre.map { $0.split(separator: ",").map { String($0).trimmed } } ?? [],
            imdbID: imdbID,
            tmdbID: tmdbID,
            origin: .dispatcharrMovie(serverID: serverID, streamID: id, ext: ext),
            added: added.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            categoryID: categoryID)
    }
}

extension XCSeries {
    func mediaItem(serverID: UUID) -> MediaItem {
        let c = TitleCleaner.clean(name)
        return MediaItem(
            id: "xc:\(serverID.uuidString.prefix(8)):series:\(id)",
            type: .series,
            title: c.title,
            year: year ?? c.year,
            poster: cover,
            backdrop: backdrop,
            overview: plot,
            rating: rating,
            genres: genre.map { $0.split(separator: ",").map { String($0).trimmed } } ?? [],
            imdbID: imdbID,
            tmdbID: tmdbID,
            origin: .dispatcharrSeries(serverID: serverID, seriesID: id),
            added: lastModified.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            categoryID: categoryID)
    }
}

extension XCChannel {
    func mediaItem(serverID: UUID) -> MediaItem {
        MediaItem(id: "xc:\(serverID.uuidString.prefix(8)):live:\(id)", type: .channel, title: name, poster: icon,
                  origin: .dispatcharrChannel(serverID: serverID, channelID: id), categoryID: categoryID)
    }
}
