import SwiftUI

@MainActor
@Observable
final class HomeModel {
    struct CatalogShelf: Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var items: [MediaItem]
        var route: Route
    }

    private(set) var trendingMovies: [MediaItem] = []
    private(set) var trendingSeries: [MediaItem] = []
    private(set) var catalogShelves: [CatalogShelf] = []
    private(set) var hero: [MediaItem] = []
    private var loadedAt: Date?

    func load(force: Bool = false) async {
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 600 { return }
        loadedAt = Date()
        let tmdb = MetadataService.shared.tmdb
        async let movies: [MediaItem] = tmdb.isConfigured ? ((try? await tmdb.trending(.movie)) ?? []) : []
        async let series: [MediaItem] = tmdb.isConfigured ? ((try? await tmdb.trending(.series)) ?? []) : []
        async let shelves = loadCatalogs()
        trendingMovies = await movies
        trendingSeries = await series
        catalogShelves = await shelves
        rebuildHero()
    }

    private func loadCatalogs() async -> [CatalogShelf] {
        let manager = AddonManager.shared
        let targets = Array(manager.catalogs.prefix(10))
        var shelves: [CatalogShelf] = []
        await withTaskGroup(of: (Int, CatalogShelf?).self) { group in
            for (i, t) in targets.enumerated() {
                group.addTask {
                    let metas = (try? await manager.catalog(t.addon, t.catalog)) ?? []
                    guard !metas.isEmpty else { return (i, nil) }
                    let items = metas.prefix(30).map { $0.mediaItem(addonID: t.addon.id) }
                    let typeName = t.catalog.type == "movie" ? "Movies" : t.catalog.type == "series" ? "Series" : t.catalog.type.capitalized
                    let title = "\(t.catalog.name ?? t.catalog.id) \(typeName)"
                    return (i, CatalogShelf(id: "\(t.addon.id)/\(t.catalog.identity)", title: title, subtitle: t.addon.manifest.name,
                                            items: Array(items),
                                            route: .addonCatalog(addonID: t.addon.id, type: t.catalog.type, catalogID: t.catalog.id, title: title)))
                }
            }
            var results: [(Int, CatalogShelf)] = []
            for await (i, shelf) in group { if let shelf { results.append((i, shelf)) } }
            shelves = results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return shelves
    }

    private func rebuildHero() {
        var pool = (trendingMovies.prefix(4) + trendingSeries.prefix(3)).filter { $0.backdrop != nil }
        if pool.count < 3 {
            pool += catalogShelves.flatMap { $0.items.prefix(4) }.filter { $0.backdrop != nil }
        }
        if pool.count < 3 {
            let store = DispatcharrStore.shared
            if let id = store.activeServer?.id {
                pool += store.movies.sorted { ($0.added ?? 0) > ($1.added ?? 0) }.prefix(6).map { $0.mediaItem(serverID: id) }
            }
        }
        var seen = Set<String>()
        hero = Array(pool.filter { seen.insert($0.id).inserted }.prefix(7))
    }
}

struct HomeView: View {
    @Environment(DispatcharrStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(TraktService.self) private var trakt
    @Environment(AddonManager.self) private var addons
    @Environment(AppRouter.self) private var router
    @Environment(PlayerCoordinator.self) private var player
    @State private var model = HomeModel()
    @State private var showSetup = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.rowSpacing) {
                if !model.hero.isEmpty {
                    HeroCarousel(items: model.hero) { router.push(.detail($0)) }
                }
                if !store.isConfigured && addons.addons.count <= 2 {
                    welcomeCard
                }
                continueWatching
                favoriteChannels
                recentlyAdded
                Shelf(title: "Your Trakt Watchlist", items: trakt.watchlist) { item in
                    posterButton(item)
                }
                Shelf(title: "Trending Movies", subtitle: "This week on TMDB", items: model.trendingMovies,
                      seeAll: { router.push(.tmdbList(path: "trending/movie/week", type: .movie, title: "Trending Movies")) }) { item in
                    posterButton(item)
                }
                Shelf(title: "Trending Series", subtitle: "This week on TMDB", items: model.trendingSeries,
                      seeAll: { router.push(.tmdbList(path: "trending/tv/week", type: .series, title: "Trending Series")) }) { item in
                    posterButton(item)
                }
                ForEach(model.catalogShelves) { shelf in
                    Shelf(title: shelf.title, subtitle: shelf.subtitle, items: shelf.items, seeAll: { router.push(shelf.route) }) { item in
                        posterButton(item)
                    }
                }
                Color.clear.frame(height: 30)
            }
        }
        .screenBackground()
        .refreshable {
            await store.refreshAll(force: true)
            await model.load(force: true)
        }
        .task { await model.load() }
        #if os(iOS)
        .navigationTitle("StreamForge")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { router.push(.library) } label: { Image(systemName: "books.vertical") }
                Button { router.push(.settings) } label: { Image(systemName: "gearshape") }
            }
        }
        #endif
    }

    private func posterButton(_ item: MediaItem) -> some View {
        Button { router.push(.detail(item)) } label: { PosterCard(item: item) }
            .cardButtonStyle()
            .contextMenu { MediaContextMenu(item: item) }
    }

    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image("Logo").resizable().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 14))
            Text("Welcome to StreamForge").font(.title2.weight(.bold))
            Text("Connect your Dispatcharr server for live TV, guide and VOD, add Stremio addons for more catalogs and streams, and add a TMDB key for rich artwork.")
                .font(.subheadline).foregroundStyle(Theme.secondaryText)
            HStack {
                Button { router.push(.settings) } label: {
                    Label("Get started", systemImage: "arrow.right.circle.fill").font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.accent2.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var continueWatching: some View {
        let entries = library.continueWatching
        Shelf(title: "Continue Watching", items: entries) { entry in
            Button { resume(entry) } label: {
                LandscapeCard(title: entry.item.title,
                              subtitle: entry.episode.map { "\($0.code) · \(entry.remainingText)" } ?? entry.remainingText,
                              image: entry.episode?.still ?? entry.item.backdrop, fallbackImage: entry.item.poster,
                              progress: entry.fraction)
            }
            .cardButtonStyle()
            .contextMenu {
                Button { router.push(.detail(entry.item)) } label: { Label("Details", systemImage: "info.circle") }
                Button(role: .destructive) { library.clearProgress(entry.key) } label: { Label("Remove", systemImage: "xmark") }
            }
        }
    }

    private func resume(_ entry: WatchProgress) {
        // Re-resolve sources so expired debrid/torrent links still work; detail view handles the picking.
        if case .dispatcharrMovie(_, let id, let ext) = entry.item.origin, let url = store.client?.movieURL(id, ext: ext) {
            player.play(PlaybackRequest(item: entry.item, episode: nil,
                                        source: PlaybackSource(id: "resume", kind: .direct(url, headers: [:]), title: entry.item.title, provider: "Server"),
                                        startPosition: entry.position - 5))
        } else if let ep = entry.episode, let eid = ep.dispatcharrEpisodeID, let url = store.client?.episodeURL(eid, ext: ep.ext ?? "mp4") {
            player.play(PlaybackRequest(item: entry.item, episode: ep,
                                        source: PlaybackSource(id: "resume", kind: .direct(url, headers: [:]), title: entry.item.title, provider: "Server"),
                                        startPosition: entry.position - 5))
        } else {
            router.push(.detail(entry.item))
        }
    }

    @ViewBuilder
    private var favoriteChannels: some View {
        let ids = library.favoriteChannelIDs.isEmpty ? Array(library.recentChannelIDs.prefix(12)) : library.favoriteChannelIDs
        let channels = ids.compactMap { store.channel($0) }
        Shelf(title: library.favoriteChannelIDs.isEmpty ? "Recent Channels" : "Favorite Channels", items: channels,
              seeAll: { router.tab = .live }) { channel in
            Button { player.playChannel(channel, in: channels) } label: {
                ChannelTile(channel: channel)
            }
            .cardButtonStyle()
        }
    }

    @ViewBuilder
    private var recentlyAdded: some View {
        if let serverID = store.activeServer?.id {
            let movies = store.movies.sorted { ($0.added ?? 0) > ($1.added ?? 0) }.prefix(24).map { $0.mediaItem(serverID: serverID) }
            let series = store.series.sorted { ($0.lastModified ?? 0) > ($1.lastModified ?? 0) }.prefix(24).map { $0.mediaItem(serverID: serverID) }
            Shelf(title: "Recently Added Movies", subtitle: store.activeServer?.name, items: Array(movies),
                  seeAll: { router.tab = .movies }) { posterButton($0) }
            Shelf(title: "Recently Updated Series", subtitle: store.activeServer?.name, items: Array(series),
                  seeAll: { router.tab = .series }) { posterButton($0) }
        }
    }
}

/// Channel tile with the live programme and its progress.
struct ChannelTile: View {
    var channel: XCChannel
    @Environment(DispatcharrStore.self) private var store

    var body: some View {
        let now = store.nowPlaying(channel.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ChannelLogo(url: channel.icon, name: channel.name, size: tileLogo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(now?.title ?? "Live").font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
            }
            ProgressLine(fraction: now?.progress ?? 0, height: 3).opacity(now == nil ? 0 : 1)
        }
        .padding(12)
        .frame(width: Theme.landscapeWidth * 0.85, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: channel.id) { await store.loadEPG(channel.id) }
    }

    private var tileLogo: CGFloat {
        #if os(tvOS)
        return 70
        #else
        return 42
        #endif
    }
}

/// Auto-advancing hero banner.
struct HeroCarousel: View {
    var items: [MediaItem]
    var onSelect: (MediaItem) -> Void
    @State private var index = 0

    private var height: CGFloat {
        #if os(tvOS)
        return 620
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? 460 : 300
        #endif
    }

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                Button { onSelect(item) } label: { HeroSlide(item: item, height: height) }
                    .buttonStyle(.plain)
                    .tag(i)
            }
        }
        #if os(iOS)
        .tabViewStyle(.page(indexDisplayMode: .always))
        #else
        .tabViewStyle(.page)
        #endif
        .frame(height: height)
        .task(id: items.count) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                withAnimation(.easeInOut(duration: 0.6)) { index = items.isEmpty ? 0 : (index + 1) % items.count }
            }
        }
    }
}

struct HeroSlide: View {
    var item: MediaItem
    var height: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: item.backdrop ?? item.poster)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()
            LinearGradient(colors: [.clear, Theme.background.opacity(0.6), Theme.background], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                if let logo = item.logo {
                    RemoteImage(url: logo, contentMode: .fit).frame(maxWidth: 260, maxHeight: 90, alignment: .leading)
                } else {
                    Text(item.title).font(.largeTitle.weight(.heavy)).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let r = item.rating { RatingView(rating: r) }
                    if let y = item.yearText { Text(y) }
                    Text(item.type == .series ? "Series" : "Movie")
                    if let g = item.genres.first { Text(g) }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                if let overview = item.overview {
                    Text(overview).font(.subheadline).foregroundStyle(.white.opacity(0.8)).lineLimit(2).frame(maxWidth: 560, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 34)
        }
        .contentShape(Rectangle())
    }
}
