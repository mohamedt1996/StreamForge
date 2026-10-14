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

    // Unfiltered server data; the published lists above apply adult / kids / channel-profile filters.
    @ObservationIgnored private var rawLiveCategories: [XCCategory] = []
    @ObservationIgnored private var rawChannels: [XCChannel] = []
    @ObservationIgnored private var rawMovieCategories: [XCCategory] = []
    @ObservationIgnored private var rawMovies: [XCMovie] = []
    @ObservationIgnored private var rawSeriesCategories: [XCCategory] = []
    @ObservationIgnored private var rawSeries: [XCSeries] = []
    @ObservationIgnored private var channelIndex: [Int: XCChannel] = [:]

    /// Channel profiles from the REST API (empty without REST access).
    private(set) var channelProfiles: [DispatcharrChannelProfile] = []
    /// Set when the chosen channel profile's membership couldn't be applied.
    private(set) var channelProfileNote: String?
    /// A problem with the account (e.g. Dispatcharr refused the REST API in REST streaming mode).
    private(set) var credentialWarning: String?

    private var epgCache: [Int: (Date, [XCEPGListing])] = [:]
    private var epgInFlight: [Int: Task<[XCEPGListing], Never>] = [:]
    @ObservationIgnored private var rest: DispatcharrREST?
    @ObservationIgnored private var credentialsSyncedFor: UUID?

    var activeServer: DispatcharrServer? {
        servers.first { $0.id == activeServerID } ?? servers.first
    }
    var client: XtreamClient? {
        guard let server = activeServer else { return nil }
        return XtreamClient(server: server, rest: server.usesRESTStreaming ? restClient() : nil)
    }

    /// Shown in Settings when the active server streams without an XC password.
    var streamingModeNote: String? {
        guard let server = activeServer, server.usesRESTStreaming else { return nil }
        return "This Dispatcharr user has no XC password, so StreamForge streams through Dispatcharr's own API and stream proxy. Everything works except catch-up (an Xtream Codes feature)."
    }
    var isConfigured: Bool { activeServer != nil }

    private init() {
        servers = FileStore.load([DispatcharrServer].self, "dispatcharr-servers.json") ?? []
        if let s = UserDefaults.standard.string(forKey: "dispatcharr.active") { activeServerID = UUID(uuidString: s) }
        loadDiskCache()
    }

    // MARK: Server management

    func upsert(_ server: DispatcharrServer, xcPassword: String, webPassword: String, apiKey: String = "") {
        server.xcPassword = xcPassword
        server.webPassword = webPassword
        server.apiKey = apiKey
        credentialsSyncedFor = nil
        if let i = servers.firstIndex(where: { $0.id == server.id }) {
            servers[i] = server
        } else {
            servers.append(server)
        }
        FileStore.save(servers, "dispatcharr-servers.json", mirrorToDefaults: true)
        CloudSync.shared.schedulePush()
        ServerSync.shared.noteLocalChange()
        activate(server.id)
    }

    func remove(_ server: DispatcharrServer) {
        servers.removeAll { $0.id == server.id }
        server.clearSecrets()
        FileStore.save(servers, "dispatcharr-servers.json", mirrorToDefaults: true)
        FileStore.remove(cacheName(server.id))
        FileStore.remove("guide-\(server.id.uuidString).json")
        ServerSync.shared.noteLocalChange()
        if activeServerID == server.id {
            activeServerID = servers.first?.id
            rest = nil
            clear()
            loadDiskCache()
            GuideStore.shared.serverDidChange()
        }
    }

    func activate(_ id: UUID) {
        activeServerID = id
        rest = nil
        channelProfiles = []
        clear()
        loadDiskCache()
        GuideStore.shared.serverDidChange()
        Task {
            await refreshAll()
            await GuideStore.shared.refreshIfStale()
        }
    }

    /// Adds or updates a server received from the sync server. Secrets arrive separately (they are
    /// stored by server id, so they may come before or after the server itself). Only activates
    /// it when this device has no server yet, or when the active server's address changed.
    func upsertSynced(_ incoming: DispatcharrServer, order: Int?) {
        var server = incoming
        var needsActivate = false
        if let i = servers.firstIndex(where: { $0.id == server.id }) {
            let old = servers[i]
            server.channelProfileID = old.channelProfileID
            if server.id == activeServer?.id,
               old.baseURL != server.baseURL || old.username != server.username || old.authMode != server.authMode {
                needsActivate = true
            }
            servers[i] = server
        } else {
            servers.append(server)
            if activeServerID == nil || servers.count == 1 { needsActivate = true }
        }
        if let order, let i = servers.firstIndex(where: { $0.id == server.id }) {
            let target = max(0, min(order, servers.count - 1))
            if target != i {
                let moved = servers.remove(at: i)
                servers.insert(moved, at: target)
            }
        }
        FileStore.save(servers, "dispatcharr-servers.json", mirrorToDefaults: true)
        ServerSync.shared.noteLocalChange()
        if needsActivate { activate(server.id) }
    }

    /// Removes a server deleted on another device.
    func removeSynced(_ id: UUID) {
        guard let server = servers.first(where: { $0.id == id }) else { return }
        remove(server)
    }

    /// Restores servers (with secrets) from a backup or another device.
    func importServers(_ list: [(server: DispatcharrServer, xcPassword: String, webPassword: String, apiKey: String)], activeID: UUID?) {
        for entry in list {
            entry.server.xcPassword = entry.xcPassword
            entry.server.webPassword = entry.webPassword
            entry.server.apiKey = entry.apiKey
            if let i = servers.firstIndex(where: { $0.id == entry.server.id }) {
                servers[i] = entry.server
            } else {
                servers.append(entry.server)
            }
        }
        FileStore.save(servers, "dispatcharr-servers.json", mirrorToDefaults: true)
        ServerSync.shared.noteLocalChange()
        if let id = activeID ?? servers.first?.id, servers.contains(where: { $0.id == id }) { activate(id) }
    }

    /// REST client for DVR, /me and channel profiles: needs an API key or the web password.
    func restClient() -> DispatcharrREST? {
        guard let server = activeServer, server.hasRESTAccess else { return nil }
        if let rest, rest.server == server { return rest }
        let r = DispatcharrREST(server: server)
        rest = r
        return r
    }

    /// Picks the Dispatcharr channel profile to show (nil = all).
    func setChannelProfile(_ id: Int?) {
        guard let server = activeServer, let i = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[i].channelProfileID = id
        FileStore.save(servers, "dispatcharr-servers.json", mirrorToDefaults: true)
        rest = nil
        reapplyFilters()
    }

    func loadChannelProfiles() async {
        guard let rest = restClient() else { channelProfiles = []; return }
        channelProfiles = (try? await rest.channelProfiles()) ?? []
        reapplyFilters()
    }

    /// Account / API-key servers: re-reads the XC password from /me once per launch, so a
    /// password set, changed or removed by the Dispatcharr admin is picked up automatically. A blank
    /// XC password is fine: the server then streams through the REST API (`usesRESTStreaming`).
    func syncCredentials(force: Bool = false) async {
        guard let server = activeServer, server.authMode != .xc, let rest = restClient() else { return }
        if !force, credentialsSyncedFor == server.id { return }
        do {
            let me = try await rest.me()
            credentialsSyncedFor = server.id
            credentialWarning = nil
            let xc = me.xcPassword ?? ""
            // Switches between XC and REST streaming when the password appears or disappears (only
            // trusted when /me actually returned the user's custom properties).
            if xc != server.xcPassword, !xc.isEmpty || me.hasCustomProperties {
                server.xcPassword = xc
            }
            if !me.username.isEmpty, me.username != server.username, let i = servers.firstIndex(where: { $0.id == server.id }) {
                servers[i].username = me.username
                FileStore.save(servers, "dispatcharr-servers.json", mirrorToDefaults: true)
            }
        } catch {
            // Offline or wrong password: keep using the stored XC password.
        }
    }

    private func clear() {
        liveCategories = []; channels = []; channelsByCategory = [:]
        movieCategories = []; movies = []; seriesCategories = []; series = []
        movieGenres = []; seriesGenres = []; movieSections = []; seriesSections = []
        rawLiveCategories = []; rawChannels = []; rawMovieCategories = []; rawMovies = []
        rawSeriesCategories = []; rawSeries = []; channelIndex = [:]
        epgCache = [:]
        liveState = .idle; vodState = .idle
        channelProfileNote = nil
        credentialWarning = nil
    }

    /// Re-runs the adult / kids / channel-profile filters (e.g. after switching profiles).
    func reapplyFilters() {
        applyLive(categories: rawLiveCategories, channels: rawChannels)
        applyVOD(movieCategories: rawMovieCategories, movies: rawMovies, seriesCategories: rawSeriesCategories, series: rawSeries)
    }

    // MARK: Loading

    func refreshAll(force: Bool = false) async {
        guard activeServer != nil else { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 15 * 60, !channels.isEmpty { return }
        await syncCredentials(force: force)
        guard let client else { return }
        if channelProfiles.isEmpty, activeServer?.hasRESTAccess == true {
            Task { await loadChannelProfiles() }
        }
        async let live: Void = refreshLive(client)
        async let vod: Void = refreshVOD(client)
        _ = await (live, vod)
        lastRefresh = Date()
        saveDiskCache()
        if let id = activeServer?.id { NewEpisodeTracker.shared.noteServerSeries(rawSeries, serverID: id) }
        SnapshotPublisher.schedule()
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
            let message = Self.loadErrorMessage(error, server: client.server)
            if client.server.usesRESTStreaming, case HTTPError.unauthorized = error { credentialWarning = message }
            liveState = channels.isEmpty ? .failed(message) : .loaded
        }
    }

    /// Dispatcharr's REST API needs a "standard" user; streamer-level users only have XC access.
    private static func loadErrorMessage(_ error: Error, server: DispatcharrServer) -> String {
        if server.usesRESTStreaming, case HTTPError.unauthorized = error {
            return "Dispatcharr didn't let this account browse channels through its API. Streamer-level users can only use Xtream Codes: ask the admin to set an XC password for your user (Users → edit → XC Password), or to raise your user level."
        }
        return error.localizedDescription
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
            vodState = (movies.isEmpty && series.isEmpty) ? .failed(Self.loadErrorMessage(error, server: client.server)) : .loaded
        }
    }

    private func applyLive(categories: [XCCategory], channels newChannels: [XCChannel]) {
        rawLiveCategories = categories.filter { $0.id != "__other" }
        rawChannels = newChannels
        let profiles = ProfileStore.shared
        let kids = profiles.isKidsMode
        let hideAdult = AppSettings.shared.values.hideAdult || kids
        var visible = newChannels.filter { !(hideAdult && $0.isAdult) }
        // Dispatcharr channel profile membership (REST); skipped when the shape was unclear or
        // nothing would match (ids from a different numbering scheme).
        channelProfileNote = nil
        if let pid = activeServer?.channelProfileID, let profile = channelProfiles.first(where: { $0.id == pid }) {
            if let ids = profile.channelIDs {
                let filtered = visible.filter { ids.contains($0.id) }
                if filtered.isEmpty && !visible.isEmpty && !ids.isEmpty {
                    channelProfileNote = "The “\(profile.name)” profile couldn't be matched to your channels, so all channels are shown."
                } else {
                    visible = filtered
                }
            } else {
                channelProfileNote = "Dispatcharr didn't return the channels of “\(profile.name)”, so all channels are shown."
            }
        }
        if kids {
            let allowed = profiles.activeProfile.allowedCategoryIDs
            let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            visible = visible.filter { ch in
                allowed.contains(ch.categoryID) || KidsFilter.isKidsCategory(names[ch.categoryID] ?? "") || KidsFilter.isKidsCategory(ch.name)
            }
        }
        channels = visible.sorted { ($0.number ?? Int.max, $0.name) < ($1.number ?? Int.max, $1.name) }
        channelIndex = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        channelsByCategory = Dictionary(grouping: channels, by: \.categoryID)
        liveCategories = categories.filter { $0.id != "__other" && channelsByCategory[$0.id]?.isEmpty == false }
        // Channels whose category is missing still need a home.
        let known = Set(liveCategories.map(\.id))
        if channels.contains(where: { !known.contains($0.categoryID) }) {
            let orphans = channels.filter { !known.contains($0.categoryID) }
            channelsByCategory["__other"] = orphans
            liveCategories.append(XCCategory(id: "__other", name: "Other"))
        }
    }

    private func applyVOD(movieCategories mc: [XCCategory], movies mv: [XCMovie], seriesCategories sc: [XCCategory], series sv: [XCSeries]) {
        rawMovieCategories = mc
        rawMovies = mv
        rawSeriesCategories = sc
        rawSeries = sv
        let kids = ProfileStore.shared.isKidsMode
        let hideAdult = AppSettings.shared.values.hideAdult || kids
        var mvVisible = mv.filter { !(hideAdult && $0.isAdult) }
        var svVisible = sv
        if kids {
            let movieCatNames = Dictionary(mc.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            let seriesCatNames = Dictionary(sc.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            mvVisible = mvVisible.filter { KidsFilter.allows(genre: $0.genre, categoryName: movieCatNames[$0.categoryID]) }
            svVisible = svVisible.filter { KidsFilter.allows(genre: $0.genre, categoryName: seriesCatNames[$0.categoryID]) }
        }
        movies = dedupeMovies(mvVisible)
        series = dedupeSeries(svVisible)
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
                let name = String(part).trimmed.capitalized
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

    /// Every live category on the server (unfiltered), for the kids-profile editor.
    var liveCategoriesForKidsPicker: [XCCategory] {
        _ = liveCategories
        return rawLiveCategories
    }

    func channel(_ id: Int) -> XCChannel? {
        _ = channels
        return channelIndex[id]
    }

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

    /// Bulk XMLTV guide when it covers the channel, else the per-channel XC short EPG.
    func epg(for channelID: Int) -> [XCEPGListing] {
        if let ch = channel(channelID), let bulk = GuideStore.shared.listings(for: ch) { return bulk }
        return epgCache[channelID]?.1 ?? []
    }

    func nowPlaying(_ channelID: Int) -> XCEPGListing? {
        if let ch = channel(channelID), let bulk = GuideStore.shared.listings(for: ch) {
            return GuideStore.programme(in: bulk, at: Date())
        }
        return epg(for: channelID).first { $0.isLive }
    }

    func nextUp(_ channelID: Int) -> XCEPGListing? {
        let now = Date()
        if let ch = channel(channelID), let bulk = GuideStore.shared.listings(for: ch) {
            return GuideStore.next(in: bulk, after: now)
        }
        return epg(for: channelID).filter { $0.start > now }.min { $0.start < $1.start }
    }

    /// Loads (and caches for 10 minutes) the programme list for one channel. Returns the bulk
    /// guide immediately when it covers the channel.
    @discardableResult
    func loadEPG(_ channelID: Int, full: Bool = false) async -> [XCEPGListing] {
        if let ch = channel(channelID), let bulk = GuideStore.shared.listings(for: ch) { return bulk }
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
        let cache = DiskCache(liveCategories: rawLiveCategories, channels: rawChannels,
                              movieCategories: rawMovieCategories, movies: rawMovies,
                              seriesCategories: rawSeriesCategories, series: rawSeries, savedAt: Date())
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
