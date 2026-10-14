import SwiftUI

@MainActor
@Observable
final class SearchModel {
    struct ResultGroup: Identifiable {
        var id: String
        var title: String
        var items: [MediaItem]
    }

    var query = ""
    private(set) var channels: [XCChannel] = []
    private(set) var groups: [ResultGroup] = []
    private(set) var searching = false
    private var task: Task<Void, Never>?

    func run() {
        task?.cancel()
        let q = query.trimmed
        guard q.count >= 2 else {
            channels = []; groups = []; searching = false
            return
        }
        searching = true
        task = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await search(q)
        }
    }

    private func search(_ q: String) async {
        let lower = q.lowercased()
        let store = DispatcharrStore.shared
        let index = VODIndex.shared
        index.rebuildIfNeeded()

        // Local results are instant.
        channels = Array(store.channels.filter { $0.name.lowercased().contains(lower) }.prefix(30))
        var newGroups: [ResultGroup] = []
        let movies = index.movies.filter { $0.title.lowercased().contains(lower) }
        let series = index.series.filter { $0.title.lowercased().contains(lower) }
        if !movies.isEmpty { newGroups.append(ResultGroup(id: "server-movies", title: "Movies on \(store.activeServer?.name ?? "your server")", items: Array(movies.prefix(40)))) }
        if !series.isEmpty { newGroups.append(ResultGroup(id: "server-series", title: "Series on \(store.activeServer?.name ?? "your server")", items: Array(series.prefix(40)))) }
        groups = newGroups

        // Remote results stream in.
        let tmdb = MetadataService.shared.tmdb
        async let tmdbResults: [MediaItem] = tmdb.isConfigured ? ((try? await tmdb.search(q)) ?? []) : []
        async let addonResults = AddonManager.shared.search(q)
        let t = await tmdbResults
        guard !Task.isCancelled, q == query.trimmed else { return }
        if !t.isEmpty { groups.append(ResultGroup(id: "tmdb", title: "TMDB", items: t)) }
        for r in await addonResults {
            guard !Task.isCancelled, q == query.trimmed else { return }
            let typeName = r.catalog.type == "movie" ? "Movies" : r.catalog.type == "series" ? "Series" : r.catalog.type.capitalized
            groups.append(ResultGroup(id: "\(r.addon.id)/\(r.catalog.identity)", title: "\(typeName) · \(r.addon.manifest.name)",
                                items: r.metas.prefix(40).map { $0.mediaItem(addonID: r.addon.id) }))
        }
        searching = false
    }
}

struct SearchView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AddonManager.self) private var addons
    @State private var model = SearchModel()

    var body: some View {
        @Bindable var model = model
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.rowSpacing) {
                #if os(tvOS)
                TextField("Search movies, series, channels", text: $model.query)
                    .padding(.horizontal, Theme.gutter)
                #endif
                if model.query.trimmed.count < 2 {
                    browse
                } else {
                    if !model.channels.isEmpty {
                        Shelf(title: "Live Channels", items: model.channels) { ch in
                            Button { player.playChannel(ch, in: model.channels) } label: { ChannelTile(channel: ch) }
                                .cardButtonStyle()
                        }
                    }
                    ForEach(model.groups) { g in
                        Shelf(title: g.title, items: g.items) { item in
                            Button { router.push(.detail(item)) } label: { PosterCard(item: item) }
                                .cardButtonStyle()
                                .contextMenu { MediaContextMenu(item: item) }
                        }
                    }
                    if model.searching {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    } else if model.groups.isEmpty && model.channels.isEmpty {
                        EmptyStateView(icon: "magnifyingglass", title: "No results", message: "Try another title, or add more addons with search catalogs.")
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .screenBackground()
        .navigationTitle("Search")
        #if os(iOS)
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movies, series, channels")
        #endif
        .onChange(of: model.query) { model.run() }
    }

    /// Shown before typing: addon catalogs to explore.
    private var browse: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Explore Addon Catalogs")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: 10)], spacing: 10) {
                ForEach(addons.catalogs) { entry in
                    let typeName = entry.catalog.type == "movie" ? "Movies" : entry.catalog.type == "series" ? "Series" : entry.catalog.type.capitalized
                    let title = "\(entry.catalog.name ?? entry.catalog.id) \(typeName)"
                    Button {
                        router.push(.addonCatalog(addonID: entry.addon.id, type: entry.catalog.type, catalogID: entry.catalog.id, title: title))
                    } label: {
                        HStack(spacing: 10) {
                            RemoteImage(url: entry.addon.logoURL, contentMode: .fit, placeholderSymbol: "puzzlepiece.extension")
                                .frame(width: 34, height: 34)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(entry.addon.manifest.name).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.gutter)
        }
    }

    private var tileWidth: CGFloat {
        #if os(tvOS)
        return 420
        #else
        return 220
        #endif
    }
}

/// Paginated grid for one Stremio addon catalog, with genre filter when the addon supports it.
struct AddonCatalogView: View {
    var addonID: String
    var type: String
    var catalogID: String
    var title: String
    @Environment(AddonManager.self) private var addons
    @Environment(AppRouter.self) private var router
    @State private var items: [MediaItem] = []
    @State private var loading = false
    @State private var exhausted = false
    @State private var genre: String?

    private var entry: (addon: InstalledAddon, catalog: StremioManifest.Catalog)? {
        guard let addon = addons.addons.first(where: { $0.id == addonID }),
              let cat = addon.manifest.catalogs?.first(where: { $0.id == catalogID && $0.type == type }) else { return nil }
        return (addon, cat)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let genres = entry?.catalog.genreOptions, !genres.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            genreChip(nil, label: "All")
                            ForEach(genres, id: \.self) { genreChip($0, label: $0) }
                        }
                        .padding(.horizontal, Theme.gutter)
                    }
                }
                PosterGrid(items: items, onSelect: { router.push(.detail($0)) }) {
                    Task { await loadMore() }
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding() }
            }
            .padding(.vertical, 12)
        }
        .screenBackground()
        .navigationTitle(title)
        .task(id: genre) {
            items = []
            exhausted = false
            await loadMore()
        }
    }

    private func genreChip(_ value: String?, label: String) -> some View {
        Button { genre = value } label: {
            Text(label).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(genre == value ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func loadMore() async {
        guard let entry, !loading, !exhausted else { return }
        loading = true
        var extra: [String: String] = [:]
        if let genre { extra["genre"] = genre }
        if !items.isEmpty {
            guard entry.catalog.supportsSkip || entry.addon.manifest.id == "com.linvo.cinemeta" else { exhausted = true; loading = false; return }
            extra["skip"] = String(items.count)
        }
        let metas = (try? await addons.catalog(entry.addon, entry.catalog, extra: extra)) ?? []
        let new = metas.map { $0.mediaItem(addonID: entry.addon.id) }.filter { n in !items.contains { $0.id == n.id } }
        if new.isEmpty { exhausted = true }
        items.append(contentsOf: new)
        loading = false
    }
}

struct TMDBListView: View {
    var path: String
    var type: MediaType
    var title: String
    @Environment(AppRouter.self) private var router
    @State private var items: [MediaItem] = []
    @State private var page = 1
    @State private var loading = false

    var body: some View {
        ScrollView {
            PosterGrid(items: items, onSelect: { router.push(.detail($0)) }) { Task { await load() } }
                .padding(.vertical, 12)
            if loading { ProgressView().padding() }
        }
        .screenBackground()
        .navigationTitle(title)
        .task { if items.isEmpty { await load() } }
    }

    private func load() async {
        guard !loading, page <= 20 else { return }
        loading = true
        let new = (try? await MetadataService.shared.tmdb.list(path, type: type, page: page)) ?? []
        items.append(contentsOf: new.filter { n in !items.contains { $0.id == n.id } })
        page += 1
        loading = false
    }
}
