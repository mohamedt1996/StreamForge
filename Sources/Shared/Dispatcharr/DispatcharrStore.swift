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
    /// Ready-made MediaItems for the browse screens (built off the main thread with the library).
    private(set) var movieItems: [MediaItem] = []
    private(set) var seriesItems: [MediaItem] = []
    /// Per-category slices, newest first.
    private(set) var movieItemsByCategory: [String: [MediaItem]] = [:]
    private(set) var seriesItemsByCategory: [String: [MediaItem]] = [:]
    /// Newest 30 (by added / last update) and best rated (7+) 30, for Home and the VOD shelves.
    private(set) var recentMovieItems: [MediaItem] = []
    private(set) var recentSeriesItems: [MediaItem] = []
    private(set) var topMovieItems: [MediaItem] = []
    private(set) var topSeriesItems: [MediaItem] = []
    /// True while the VOD library is being (re)built in the background.
    private(set) var isBuildingVOD = false

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
    // O(1) lookups (matchMovie / matchSeries / categoryName), published together with the lists they index.
    @ObservationIgnored private var movieIndex = VODMatchIndex()
    @ObservationIgnored private var seriesIndex = VODMatchIndex()
    @ObservationIgnored private var movieCategoryNames: [String: String] = [:]
    @ObservationIgnored private var seriesCategoryNames: [String: String] = [:]
    @ObservationIgnored private var liveCategoryNames: [String: String] = [:]
    // Background work: a build that finishes after a newer one started (or a server switch) is dropped,
    // and cached data never replaces data that already came from the network.
    @ObservationIgnored private var vodGeneration = 0
    @ObservationIgnored private var vodBuildTask: Task<Bool, Never>?
    @ObservationIgnored private var diskLoadTask: Task<Void, Never>?
    @ObservationIgnored private var liveFromNetwork = false
    @ObservationIgnored private var vodFromNetwork = false

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
        // Channel profiles only filter live channels: no need to rebuild the VOD library.
        applyLive(categories: rawLiveCategories, channels: rawChannels)
    }

    func loadChannelProfiles() async {
        guard let rest = restClient() else { channelProfiles = []; return }
        channelProfiles = (try? await rest.channelProfiles()) ?? []
        applyLive(categories: rawLiveCategories, channels: rawChannels)
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
        movieItems = []; seriesItems = []; movieItemsByCategory = [:]; seriesItemsByCategory = [:]
        recentMovieItems = []; recentSeriesItems = []; topMovieItems = []; topSeriesItems = []
        movieIndex = VODMatchIndex(); seriesIndex = VODMatchIndex()
        movieCategoryNames = [:]; seriesCategoryNames = [:]; liveCategoryNames = [:]
        vodGeneration += 1
        vodBuildTask?.cancel(); vodBuildTask = nil
        diskLoadTask?.cancel(); diskLoadTask = nil
        isBuildingVOD = false
        liveFromNetwork = false; vodFromNetwork = false
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
            guard activeServer?.id == client.server.id else { return }
            liveFromNetwork = true
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
            guard activeServer?.id == client.server.id else { return }
            vodFromNetwork = true
            // Decoding already happened off the main thread (nonisolated client); dedupe, MediaItems,
            // slices and indexes are built in the background too. Wait for them so the cache save and
            // `vodState` follow the published library.
            _ = await applyVOD(movieCategories: mcv, movies: mv, seriesCategories: scv, series: sv)?.value
            guard activeServer?.id == client.server.id else { return }
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
        liveCategoryNames = Dictionary(liveCategories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// Stores the raw library and rebuilds everything derived from it (filters, dedupe, MediaItems,
    /// per-category slices, shelves, match indexes) off the main thread, publishing it in one go.
    /// The returned task finishes with true when this build was published.
    @discardableResult
    private func applyVOD(movieCategories mc: [XCCategory], movies mv: [XCMovie], seriesCategories sc: [XCCategory], series sv: [XCSeries]) -> Task<Bool, Never>? {
        rawMovieCategories = mc
        rawMovies = mv
        rawSeriesCategories = sc
        rawSeries = sv
        guard let serverID = activeServer?.id else { return nil }
        let kids = ProfileStore.shared.isKidsMode
        let input = VODBuildInput(serverID: serverID, movieCategories: mc, movies: mv, seriesCategories: sc, series: sv,
                                  kids: kids, hideAdult: AppSettings.shared.values.hideAdult || kids)
        vodGeneration += 1
        let generation = vodGeneration
        vodBuildTask?.cancel()
        isBuildingVOD = true
        let task = Task<Bool, Never> {
            // `build` runs detached (never on main) and gives up early when this task is cancelled
            // by a newer build or a server switch.
            guard let built = await VODLibraryBuilder.build(input),
                  !Task.isCancelled, generation == self.vodGeneration else { return false }
            self.publish(built)
            self.isBuildingVOD = false
            return true
        }
        vodBuildTask = task
        return task
    }

    private func publish(_ b: VODLibrary) {
        movieIndex = b.movieIndex
        seriesIndex = b.seriesIndex
        movieCategoryNames = Dictionary(b.movieCategories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        seriesCategoryNames = Dictionary(b.seriesCategories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        movies = b.movies
        series = b.series
        movieCategories = b.movieCategories
        seriesCategories = b.seriesCategories
        movieGenres = b.movieGenres
        seriesGenres = b.seriesGenres
        movieSections = b.movieSections
        seriesSections = b.seriesSections
        movieItemsByCategory = b.movieItemsByCategory
        seriesItemsByCategory = b.seriesItemsByCategory
        recentMovieItems = b.recentMovieItems
        recentSeriesItems = b.recentSeriesItems
        topMovieItems = b.topMovieItems
        topSeriesItems = b.topSeriesItems
        movieItems = b.movieItems
        seriesItems = b.seriesItems
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

    /// O(1): called per channel by the guide's filters.
    func categoryName(_ id: String, kind: MediaType) -> String {
        let raw: String?
        switch kind {
        case .series: _ = seriesCategories; raw = seriesCategoryNames[id]
        case .channel: _ = liveCategories; raw = liveCategoryNames[id]
        default: _ = movieCategories; raw = movieCategoryNames[id]
        }
        return TitleCleaner.splitCategory(raw ?? "").name
    }

    /// Finds a Dispatcharr VOD that matches a TMDB/IMDb item so Stremio/TMDB detail pages can offer
    /// "Play from your server" alongside addon streams.
    /// O(1) via indexes built with the library (keyed by TMDB id, IMDb id and normalized title).
    /// Detail pages, person filmographies and source lists call this once per credit / item.
    func matchMovie(tmdbID: Int?, imdbID: String?, title: String, year: Int?) -> XCMovie? {
        let list = movies
        guard let i = movieIndex.position(tmdbID: tmdbID, imdbID: imdbID, title: title, year: year, checkYear: true),
              i < list.count else { return nil }
        return list[i]
    }

    func matchSeries(tmdbID: Int?, imdbID: String?, title: String) -> XCSeries? {
        let list = series
        guard let i = seriesIndex.position(tmdbID: tmdbID, imdbID: imdbID, title: title, year: nil, checkYear: false),
              i < list.count else { return nil }
        return list[i]
    }

    /// Like matchMovie / matchSeries, but returns the ready-made MediaItem (no title cleaning).
    /// `movieItems[i]` / `seriesItems[i]` are built from `movies[i]` / `series[i]`.
    func matchMovieItem(tmdbID: Int?, imdbID: String?, title: String, year: Int?) -> MediaItem? {
        let list = movieItems
        guard let i = movieIndex.position(tmdbID: tmdbID, imdbID: imdbID, title: title, year: year, checkYear: true),
              i < list.count else { return nil }
        return list[i]
    }

    func matchSeriesItem(tmdbID: Int?, imdbID: String?, title: String) -> MediaItem? {
        let list = seriesItems
        guard let i = seriesIndex.position(tmdbID: tmdbID, imdbID: imdbID, title: title, year: nil, checkYear: false),
              i < list.count else { return nil }
        return list[i]
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

    private func cacheName(_ id: UUID) -> String { "dispatcharr-cache-\(id.uuidString).json" }

    /// Reads (and decompresses / decodes) the cache off the main thread, then applies it unless the
    /// network already delivered fresher data. The VOD part is built in the background as well.
    private func loadDiskCache() {
        guard let id = activeServer?.id else { return }
        let name = cacheName(id)
        diskLoadTask?.cancel()
        diskLoadTask = Task {
            guard let cache = await DispatcharrDiskCacheIO.read(name),
                  !Task.isCancelled, self.activeServer?.id == id else { return }
            if !self.liveFromNetwork, self.rawChannels.isEmpty {
                self.applyLive(categories: cache.liveCategories, channels: cache.channels)
                self.liveState = .loaded
                SnapshotPublisher.schedule() // widgets / top shelf resolve channels by id
            }
            if !self.vodFromNetwork, self.rawMovies.isEmpty, self.rawSeries.isEmpty,
               let task = self.applyVOD(movieCategories: cache.movieCategories, movies: cache.movies,
                                        seriesCategories: cache.seriesCategories, series: cache.series) {
                if await task.value, !self.vodFromNetwork, self.activeServer?.id == id { self.vodState = .loaded }
            }
        }
    }

    private func saveDiskCache() {
        guard let id = activeServer?.id else { return }
        let cache = DispatcharrDiskCache(liveCategories: rawLiveCategories, channels: rawChannels,
                                         movieCategories: rawMovieCategories, movies: rawMovies,
                                         seriesCategories: rawSeriesCategories, series: rawSeries, savedAt: Date())
        let name = cacheName(id)
        Task.detached(priority: .utility) { DispatcharrDiskCacheIO.write(cache, name) }
    }
}

// MARK: - Background work

/// Runs `work` on a detached task (never on the main actor) and forwards cancellation of the
/// calling task to it, so `Task.isCancelled` inside `work` sees a superseded request.
func detachedCancellable<T: Sendable>(priority: TaskPriority = .userInitiated,
                                      _ work: @escaping @Sendable () async -> T) async -> T {
    let task = Task.detached(priority: priority, operation: work)
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

// MARK: - VOD library build (off the main thread)

struct VODBuildInput: Sendable {
    var serverID: UUID
    var movieCategories: [XCCategory]
    var movies: [XCMovie]
    var seriesCategories: [XCCategory]
    var series: [XCSeries]
    var kids: Bool
    var hideAdult: Bool
}

/// O(1) lookups for matchMovie / matchSeries. Values are positions in the published (deduped) list.
struct VODMatchIndex: Sendable {
    struct TitleEntry: Sendable {
        var position: Int
        var year: Int?
    }

    var byTMDB: [Int: Int] = [:]
    var byIMDB: [String: Int] = [:]
    /// Normalized cleaned title → entries in library order.
    var byTitle: [String: [TitleEntry]] = [:]

    /// The first item wins, like the linear searches this replaces.
    mutating func add(position: Int, tmdbID: Int?, imdbID: String?, cleanedTitle: String, year: Int?) {
        if let tmdbID, byTMDB[tmdbID] == nil { byTMDB[tmdbID] = position }
        if let imdbID, !imdbID.isEmpty, byIMDB[imdbID] == nil { byIMDB[imdbID] = position }
        let key = Self.normalize(cleanedTitle)
        if !key.isEmpty { byTitle[key, default: []].append(TitleEntry(position: position, year: year)) }
    }

    func position(tmdbID: Int?, imdbID: String?, title: String, year: Int?, checkYear: Bool) -> Int? {
        if let tmdbID, let i = byTMDB[tmdbID] { return i }
        if let imdbID, !imdbID.isEmpty, let i = byIMDB[imdbID] { return i }
        let key = Self.normalize(title)
        guard !key.isEmpty, let entries = byTitle[key] else { return nil }
        guard checkYear, let year else { return entries.first?.position }
        return entries.first { $0.year == nil || $0.year == year }?.position
    }

    private static let kept = CharacterSet.alphanumerics

    /// Letters and digits only, case and accents folded: "Amélie" = "amelie", "Spider-Man" = "Spiderman".
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var scalars = String.UnicodeScalarView()
        for u in folded.unicodeScalars where kept.contains(u) { scalars.append(u) }
        return String(scalars).lowercased()
    }
}

/// The visible VOD library and everything derived from it, ready to publish.
struct VODLibrary: Sendable {
    var movies: [XCMovie] = []
    var series: [XCSeries] = []
    var movieCategories: [XCCategory] = []
    var seriesCategories: [XCCategory] = []
    var movieGenres: [String] = []
    var seriesGenres: [String] = []
    var movieSections: [CategorySection] = []
    var seriesSections: [CategorySection] = []
    var movieIndex = VODMatchIndex()
    var seriesIndex = VODMatchIndex()
    var movieItems: [MediaItem] = []
    var seriesItems: [MediaItem] = []
    var movieItemsByCategory: [String: [MediaItem]] = [:]
    var seriesItemsByCategory: [String: [MediaItem]] = [:]
    var recentMovieItems: [MediaItem] = []
    var recentSeriesItems: [MediaItem] = []
    var topMovieItems: [MediaItem] = []
    var topSeriesItems: [MediaItem] = []
}

enum VODLibraryBuilder {
    /// Filters (adult / kids), dedupes, cleans every title exactly once (regex work), maps to
    /// MediaItems and builds slices, shelves and indexes. Runs detached; nil when cancelled.
    static func build(_ input: VODBuildInput) async -> VODLibrary? {
        await detachedCancellable { VODLibraryBuilder.make(input) }
    }

    private static func make(_ input: VODBuildInput) -> VODLibrary? {
        var mvVisible = input.movies.filter { !(input.hideAdult && $0.isAdult) }
        var svVisible = input.series
        if input.kids {
            let movieCatNames = Dictionary(input.movieCategories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            let seriesCatNames = Dictionary(input.seriesCategories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            mvVisible = mvVisible.filter { KidsFilter.allows(genre: $0.genre, categoryName: movieCatNames[$0.categoryID]) }
            svVisible = svVisible.filter { KidsFilter.allows(genre: $0.genre, categoryName: seriesCatNames[$0.categoryID]) }
        }
        if Task.isCancelled { return nil }

        var out = VODLibrary()
        let serverID = input.serverID

        // Providers often list the same film in several categories; keep one per TMDB/IMDb id or title+year.
        var seen = Set<String>()
        out.movies.reserveCapacity(mvVisible.count)
        out.movieItems.reserveCapacity(mvVisible.count)
        for (n, m) in mvVisible.enumerated() {
            if n % 2048 == 0, Task.isCancelled { return nil }
            let c = TitleCleaner.clean(m.name)
            let key: String
            if let t = m.tmdbID { key = "tmdb\(t)" }
            else if let i = m.imdbID, !i.isEmpty { key = i }
            else { key = "\(c.title.lowercased())|\(c.year ?? m.year ?? 0)" }
            guard seen.insert(key).inserted else { continue }
            out.movieIndex.add(position: out.movies.count, tmdbID: m.tmdbID, imdbID: m.imdbID, cleanedTitle: c.title, year: c.year ?? m.year)
            out.movies.append(m)
            out.movieItems.append(m.mediaItem(serverID: serverID, cleaned: c))
        }
        seen.removeAll()
        out.series.reserveCapacity(svVisible.count)
        out.seriesItems.reserveCapacity(svVisible.count)
        for (n, s) in svVisible.enumerated() {
            if n % 2048 == 0, Task.isCancelled { return nil }
            let c = TitleCleaner.clean(s.name)
            let key = s.tmdbID.map { "tmdb\($0)" } ?? "\(c.title.lowercased())|\(s.year ?? 0)"
            guard seen.insert(key).inserted else { continue }
            out.seriesIndex.add(position: out.series.count, tmdbID: s.tmdbID, imdbID: s.imdbID, cleanedTitle: c.title, year: nil)
            out.series.append(s)
            out.seriesItems.append(s.mediaItem(serverID: serverID, cleaned: c))
        }
        if Task.isCancelled { return nil }

        let movieCats = Set(out.movies.map(\.categoryID))
        let seriesCats = Set(out.series.map(\.categoryID))
        out.movieCategories = input.movieCategories.filter { movieCats.contains($0.id) }
        out.seriesCategories = input.seriesCategories.filter { seriesCats.contains($0.id) }
        out.movieGenres = genres(out.movies.compactMap(\.genre))
        out.seriesGenres = genres(out.series.compactMap(\.genre))
        out.movieSections = sections(out.movieCategories)
        out.seriesSections = sections(out.seriesCategories)

        let newestFirst: (MediaItem, MediaItem) -> Bool = { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
        let bestFirst: (MediaItem, MediaItem) -> Bool = { ($0.rating ?? 0) > ($1.rating ?? 0) }
        out.movieItemsByCategory = Dictionary(grouping: out.movieItems) { $0.categoryID ?? "0" }.mapValues { $0.sorted(by: newestFirst) }
        out.seriesItemsByCategory = Dictionary(grouping: out.seriesItems) { $0.categoryID ?? "0" }.mapValues { $0.sorted(by: newestFirst) }
        if Task.isCancelled { return nil }
        out.recentMovieItems = Array(out.movieItems.sorted(by: newestFirst).prefix(30))
        out.recentSeriesItems = Array(out.seriesItems.sorted(by: newestFirst).prefix(30))
        out.topMovieItems = Array(out.movieItems.filter { ($0.rating ?? 0) >= 7 }.sorted(by: bestFirst).prefix(30))
        out.topSeriesItems = Array(out.seriesItems.filter { ($0.rating ?? 0) >= 7 }.sorted(by: bestFirst).prefix(30))
        return out
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
}

// MARK: - Disk cache (compressed, read and written off the main thread)

struct DispatcharrDiskCache: Codable, Sendable {
    var liveCategories: [XCCategory]
    var channels: [XCChannel]
    var movieCategories: [XCCategory]
    var movies: [XCMovie]
    var seriesCategories: [XCCategory]
    var series: [XCSeries]
    var savedAt: Date
}

enum DispatcharrDiskCacheIO {
    /// Reads, decompresses and decodes the cache on a detached task. Plain JSON written by older
    /// versions is read too.
    static func read(_ name: String) async -> DispatcharrDiskCache? {
        await detachedCancellable { DispatcharrDiskCacheIO.readNow(name) }
    }

    private static func readNow(_ name: String) -> DispatcharrDiskCache? {
        guard let raw = try? Data(contentsOf: FileStore.url(name), options: .mappedIfSafe) else { return nil }
        var data = raw
        // LZFSE streams start with a "bvx" block magic; JSON never does.
        if raw.starts(with: [0x62, 0x76, 0x78]) {
            guard let plain = try? (raw as NSData).decompressed(using: .lzfse) as Data else { return nil }
            data = plain
        }
        if Task.isCancelled { return nil }
        return try? JSONDecoder().decode(DispatcharrDiskCache.self, from: data)
    }

    /// Blocking: call from a background task.
    static func write(_ cache: DispatcharrDiskCache, _ name: String) {
        guard let json = try? JSONEncoder().encode(cache) else { return }
        let data = (try? (json as NSData).compressed(using: .lzfse) as Data) ?? json
        try? data.write(to: FileStore.url(name), options: .atomic)
    }
}

// MARK: - Mapping to MediaItem

extension XCMovie {
    func mediaItem(serverID: UUID) -> MediaItem {
        mediaItem(serverID: serverID, cleaned: TitleCleaner.clean(name))
    }

    /// `c` is `TitleCleaner.clean(name)`, passed in when the caller already has it (the regex work
    /// is the expensive part of mapping a big library).
    func mediaItem(serverID: UUID, cleaned c: (title: String, year: Int?)) -> MediaItem {
        MediaItem(
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
        mediaItem(serverID: serverID, cleaned: TitleCleaner.clean(name))
    }

    func mediaItem(serverID: UUID, cleaned c: (title: String, year: Int?)) -> MediaItem {
        MediaItem(
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
