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
    private var loadedProfile: UUID?

    func load(force: Bool = false) async {
        let profile = ProfileStore.shared.activeProfileID
        if !force, loadedProfile == profile, let loadedAt, Date().timeIntervalSince(loadedAt) < 600 { return }
        loadedAt = Date()
        loadedProfile = profile
        let tmdb = MetadataService.shared.tmdb
        async let movies: [MediaItem] = tmdb.isConfigured ? ((try? await tmdb.trending(.movie)) ?? []) : []
        async let series: [MediaItem] = tmdb.isConfigured ? ((try? await tmdb.trending(.series)) ?? []) : []
        async let shelves = loadCatalogs()
        trendingMovies = KidsFilter.filter(await movies)
        trendingSeries = KidsFilter.filter(await series)
        catalogShelves = (await shelves).compactMap { shelf -> CatalogShelf? in
            var s = shelf
            s.items = KidsFilter.filter(shelf.items)
            return s.items.isEmpty ? nil : s
        }
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
                upNext
                liveSports
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
            await trakt.refreshUpNext(force: true)
            await GuideStore.shared.refreshIfStale()
        }
        .task(id: ProfileStore.shared.activeProfileID) { await model.load() }
        #if os(iOS)
        .navigationTitle("StreamForge")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { ProfileStore.shared.needsSelection = true } label: {
                    ProfileAvatar(profile: ProfileStore.shared.activeProfile, size: 30)
                }
                .accessibilityLabel("Switch profile")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { router.push(.torrents) } label: {
                    Image(systemName: "arrow.down.circle")
                        .overlay(alignment: .topTrailing) {
                            let count = TorrentEngine.shared.activeCount + DownloadManager.shared.activeCount
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Theme.live, in: Capsule())
                                    .offset(x: 8, y: -6)
                            }
                        }
                }
                .accessibilityLabel("Activity")
                Button { router.push(.library) } label: { Image(systemName: "books.vertical") }
                Button { router.push(.settings) } label: { Image(systemName: "gearshape") }
            }
        }
        #else
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { ProfileStore.shared.needsSelection = true } label: {
                    Label(ProfileStore.shared.activeProfile.name, systemImage: "person.crop.circle")
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private var upNext: some View {
        Shelf(title: "Up Next", subtitle: "Next episodes from Trakt", items: trakt.upNext,
              seeAll: trakt.upNext.count > 6 ? { router.push(.upNext) } : nil) { entry in
            Button { router.push(.detail(entry.item)) } label: {
                LandscapeCard(title: entry.item.title, subtitle: "\(entry.episode.code) · \(entry.episode.title)",
                              image: entry.item.backdrop, fallbackImage: entry.item.poster,
                              badge: entry.isNew ? "NEW" : nil)
            }
            .cardButtonStyle()
        }
    }

    @ViewBuilder
    private var liveSports: some View {
        let entries = GuideStore.shared.liveSportsNow(channels: store.channels)
        Shelf(title: "Live Sports Now", subtitle: "Matches and events on air", items: entries,
              seeAll: { router.tab = .live }) { entry in
            Button { player.playChannel(entry.channel, in: entries.map(\.channel)) } label: {
                SportsTile(entry: entry)
            }
            .cardButtonStyle()
        }
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
        router.resume(entry)
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

/// "Live Sports Now" tile: channel, programme and progress.
struct SportsTile: View {
    var entry: LiveProgrammeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ChannelLogo(url: entry.channel.icon, name: entry.channel.name, size: logo)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        SportBadge()
                        Text(entry.channel.name).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    Text(entry.programme.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                }
            }
            ProgressLine(fraction: entry.programme.progress, height: 3)
            Text(entry.programme.timeRangeText).font(.caption2).foregroundStyle(Theme.secondaryText)
        }
        .padding(12)
        .frame(width: Theme.landscapeWidth * 0.95, alignment: .leading)
        .background(
            LinearGradient(colors: [Color.green.opacity(0.22), Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var logo: CGFloat {
        #if os(tvOS)
        return 70
        #else
        return 42
        #endif
    }
}

struct SportBadge: View {
    var body: some View {
        Text("SPORT")
            .font(.system(size: 9, weight: .heavy))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(.black)
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

/// Auto-advancing hero banner. The visible slide plays its trailer (muted, after a short
/// delay) like Netflix's billboard; the carousel holds still while it plays.
struct HeroCarousel: View {
    var items: [MediaItem]
    var onSelect: (MediaItem) -> Void
    @Environment(PlayerCoordinator.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @State private var index = 0
    @State private var trailer = TrailerController()
    @State private var heroVisible = true
    @State private var pageVisible = false

    private var height: CGFloat {
        #if os(tvOS)
        return 620
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? 460 : 300
        #endif
    }

    private var trailerActive: Bool {
        pageVisible && heroVisible && scenePhase == .active
            && player.current == nil && player.multiview == nil && player.sourcePickerRequest == nil
            && TrailerPolicy.allowsAutoplay
    }

    private var currentID: String? { items.indices.contains(index) ? items[index].id : nil }

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                Button { onSelect(item) } label: {
                    HeroSlide(item: item, height: height, trailer: i == index ? trailer : nil)
                }
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
        #if os(iOS)
        .overlay(alignment: .bottomTrailing) {
            // Outside the slide buttons so a tap mutes instead of opening the title.
            TrailerControlButton(controller: trailer)
                .padding(.trailing, Theme.gutter)
                .padding(.bottom, 40)
        }
        #endif
        .background(HeroVisibilityReader(height: height, isVisible: $heroVisible))
        .onAppear { pageVisible = true }
        .onDisappear { pageVisible = false }
        .onChange(of: trailerActive, initial: true) { _, active in trailer.setActive(active) }
        .task(id: currentID) {
            // New slide: back to its artwork, then look up its trailer while the backdrop shows.
            trailer.setKeys([])
            guard let id = currentID, let item = items.first(where: { $0.id == id }) else { return }
            let shownAt = Date()
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, TrailerPolicy.allowsAutoplay else { return }
            let keys = await MetadataService.shared.trailerKeys(for: item)
            guard !Task.isCancelled, currentID == id else { return }
            trailer.setKeys(keys, delay: max(0.3, TrailerPolicy.startDelay - Date().timeIntervalSince(shownAt)))
        }
        .task(id: items.count) {
            // Advance every 7 s of artwork; hold while a trailer loads or plays.
            var idle: TimeInterval = 0
            var shown = index
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                if shown != index { shown = index; idle = 0 }
                switch trailer.phase {
                case .loading, .playing:
                    idle = 0
                case .idle, .ended, .unavailable:
                    idle += 0.5
                }
                if idle >= 7, !items.isEmpty {
                    idle = 0
                    withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % items.count }
                }
            }
        }
    }
}

struct HeroSlide: View {
    var item: MediaItem
    var height: CGFloat
    /// Set only on the visible slide.
    var trailer: TrailerController?

    private var playing: Bool { trailer?.isRevealed ?? false }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: item.backdrop ?? item.poster)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .overlay {
                    if let trailer { TrailerSurface(controller: trailer) }
                }
                .clipped()
            LinearGradient(colors: [.clear, Theme.background.opacity(0.6), Theme.background], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let logo = item.logo {
                        RemoteImage(url: logo, contentMode: .fit).frame(maxWidth: 260, maxHeight: 90, alignment: .leading)
                    } else {
                        Text(item.title).font(.largeTitle.weight(.heavy)).lineLimit(2)
                    }
                }
                .scaleEffect(playing ? 0.8 : 1, anchor: .bottomLeading)
                .animation(.easeInOut(duration: TrailerPolicy.fade), value: playing)
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
                        .opacity(playing ? 0 : 1)
                        .animation(.easeInOut(duration: TrailerPolicy.fade), value: playing)
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 34)
        }
        .contentShape(Rectangle())
    }
}
