import SwiftUI

struct VODBrowserView: View {
    var kind: MediaType
    var categoryID: String?
    var title: String

    @Environment(DispatcharrStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @State private var index = VODIndex.shared
    @State private var filter = VODFilter()
    @State private var results: [MediaItem] = []
    @State private var showGrid = false
    @State private var visibleCount = 120
    @State private var section: String?

    private var isRoot: Bool { categoryID == nil }
    private var categories: [XCCategory] { kind == .series ? store.seriesCategories : store.movieCategories }
    private var sections: [CategorySection] { kind == .series ? store.seriesSections : store.movieSections }
    private var genres: [String] { kind == .series ? store.seriesGenres : store.movieGenres }
    private var state: LoadState { store.vodState }
    private var gridMode: Bool { !isRoot || showGrid || filter.isActive || !filter.query.isEmpty }

    var body: some View {
        Group {
            if !store.isConfigured {
                EmptyStateView(icon: kind == .series ? "tv" : "film.stack", title: "No Dispatcharr server",
                               message: "Add your Dispatcharr server to browse its \(kind == .series ? "series" : "movie") library. Addon catalogs live in Home and Search.",
                               actionTitle: "Add Server") { router.push(.settings) }
            } else if case .failed(let msg) = state, index.items(kind, categoryID: nil).isEmpty {
                EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn't load the library", message: msg, actionTitle: "Retry") {
                    Task { await store.refreshAll(force: true) }
                }
            } else if index.items(kind, categoryID: nil).isEmpty {
                if state == .loading || index.isBuilding || state == .idle {
                    LoadingView(text: "Organizing your library…")
                } else {
                    EmptyStateView(icon: "tray", title: "Nothing here yet", message: "Your server has no \(kind == .series ? "series" : "movies").")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        filterBar
                        if gridMode {
                            grid
                        } else {
                            // Lazy: providers have hundreds of categories; only visible shelves (and
                            // their posters) are built.
                            LazyVStack(alignment: .leading, spacing: 14) { shelves }
                        }
                    }
                    .padding(.bottom, 30)
                }
            }
        }
        .screenBackground()
        .navigationTitle(title)
        #if os(iOS)
        .searchable(text: $filter.query, prompt: "Search \(title.lowercased())")
        #endif
        .refreshable { await store.refreshAll(force: true) }
        .task(id: TaskKey(filter: filter, count: index.items(kind, categoryID: categoryID).count, watched: library.watched.count,
                          grid: gridMode, building: index.isBuilding)) {
            // The shelves don't use `results`: only filter the library when the grid is showing.
            guard gridMode else { return }
            // Typing restarts this task: wait for a pause before walking the whole library.
            if !filter.query.trimmed.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
            let items = index.items(kind, categoryID: categoryID)
            let f = filter
            let watched = library.watched
            // Off the main thread and cancelled with this task, so a stale result never lands.
            guard let filtered = await VODIndex.filtered(f, items: items, watched: watched), !Task.isCancelled else { return }
            visibleCount = 120
            results = filtered
        }
    }

    private struct TaskKey: Equatable { var filter: VODFilter; var count: Int; var watched: Int; var grid: Bool; var building: Bool }

    // MARK: Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if isRoot {
                    chip(showGrid ? "Grid" : "Shelves", icon: showGrid ? "square.grid.3x3" : "rectangle.grid.1x2", active: false) {
                        withAnimation { showGrid.toggle() }
                    }
                }
                Menu {
                    Picker("Sort", selection: $filter.sort) {
                        ForEach(VODSort.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                    }
                } label: { chipLabel(filter.sort.rawValue, icon: "arrow.up.arrow.down", active: filter.sort != .added) }

                if !genres.isEmpty {
                    Menu {
                        Button("Any genre") { filter.genre = nil }
                        ForEach(genres.prefix(40), id: \.self) { g in Button(g) { filter.genre = g } }
                    } label: { chipLabel(filter.genre ?? "Genre", icon: "theatermasks", active: filter.genre != nil) }
                }

                Menu {
                    Button("Any year") { filter.decade = nil }
                    ForEach([2020, 2010, 2000, 1990, 1980, 1970, 1960, 1950], id: \.self) { d in Button("\(String(d))s") { filter.decade = d } }
                } label: { chipLabel(filter.decade.map { "\(String($0))s" } ?? "Year", icon: "calendar", active: filter.decade != nil) }

                Menu {
                    ForEach([0.0, 6.0, 7.0, 8.0], id: \.self) { r in
                        Button(r == 0 ? "Any rating" : "\(Int(r))+ ★") { filter.minRating = r }
                    }
                } label: { chipLabel(filter.minRating > 0 ? "\(Int(filter.minRating))+ ★" : "Rating", icon: "star", active: filter.minRating > 0) }

                chip("Unwatched", icon: "eye.slash", active: filter.unwatchedOnly) { filter.unwatchedOnly.toggle() }

                if filter.isActive {
                    chip("Clear", icon: "xmark", active: false) { filter = VODFilter(sort: filter.sort, query: filter.query) }
                }
            }
            .padding(.horizontal, Theme.gutter)
            #if os(tvOS)
            .padding(.vertical, 20)
            #endif
        }
    }

    private func chip(_ text: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(text, icon: icon, active: active) }
            .buttonStyle(.plain)
    }

    private func chipLabel(_ text: String, icon: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(active ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface), in: Capsule())
        .foregroundStyle(.white)
    }

    // MARK: Grid

    private var grid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(results.count) \(kind == .series ? "series" : "movies")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, Theme.gutter)
            PosterGrid(items: Array(results.prefix(visibleCount)), onSelect: { router.push(.detail($0)) }) {
                if visibleCount < results.count { visibleCount += 120 }
            }
        }
    }

    // MARK: Shelves

    @ViewBuilder
    private var shelves: some View {
        let continueItems = library.continueWatching.filter { $0.item.type == kind && isFromServer($0.item) }
        let myList = library.favorites.filter { $0.type == kind }

        if !continueItems.isEmpty {
            Shelf(title: "Continue Watching", items: continueItems) { entry in
                Button { router.resume(entry) } label: {
                    LandscapeCard(title: entry.item.title, subtitle: entry.episode.map { "\($0.code) · \(entry.remainingText)" } ?? entry.remainingText,
                                  image: entry.episode?.still ?? entry.item.backdrop, fallbackImage: entry.item.poster, progress: entry.fraction)
                }
                .cardButtonStyle()
                    .contextMenu { ContinueWatchingMenu(entry: entry) }
            }
        }
        // Pre-built off the main thread by DispatcharrStore (no full-library sort per render).
        Shelf(title: "Recently Added", items: index.recent(kind),
              seeAll: { showGrid = true; filter.sort = .added }) { poster($0) }
        Shelf(title: "Top Rated", items: index.topRated(kind),
              seeAll: { showGrid = true; filter.sort = .rating }) { poster($0) }
        if kind == .movie {
            // TMDB franchises found in the server library (needs a TMDB key).
            CollectionsShelf()
        }
        Shelf(title: "My List", items: myList) { poster($0) }

        // Section picker for providers that prefix categories by language/source (EN | …, FR | …).
        if sections.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sections) { s in
                        chip(s.name, icon: "folder", active: (section ?? sections.first?.name) == s.name) { section = s.name }
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }
        }
        let activeSection = sections.first { $0.name == (section ?? sections.first?.name) }
        ForEach(activeSection?.categories.filter { !library.isHidden(category: "\(kind.rawValue):\($0.id)") } ?? []) { cat in
            let items = index.items(kind, categoryID: cat.id) // already newest first
            let name = TitleCleaner.splitCategory(cat.name).name
            Shelf(title: name, subtitle: "\(items.count) titles", items: Array(items.prefix(20)),
                  seeAll: { router.push(kind == .series ? .series(categoryID: cat.id, title: name) : .movies(categoryID: cat.id, title: name)) }) { poster($0) }
                .contextMenu {
                    Button { library.toggleHidden(category: "\(kind.rawValue):\(cat.id)") } label: { Label("Hide Category", systemImage: "eye.slash") }
                }
        }
        if genres.count > 2 {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Browse by Genre")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: genreTileWidth), spacing: 10)], spacing: 10) {
                    ForEach(genres.prefix(24), id: \.self) { g in
                        Button { filter.genre = g } label: {
                            Text(g).font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity, minHeight: 54)
                                .background(
                                    LinearGradient(colors: [Theme.accent.opacity(0.45), Theme.accent2.opacity(0.25)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }
        }
    }

    private var genreTileWidth: CGFloat {
        #if os(tvOS)
        return 300
        #else
        return 150
        #endif
    }

    private func poster(_ item: MediaItem) -> some View {
        Button { router.push(.detail(item)) } label: { PosterCard(item: item) }
            .cardButtonStyle()
            .contextMenu { MediaContextMenu(item: item) }
    }

    private func isFromServer(_ item: MediaItem) -> Bool {
        switch item.origin {
        case .dispatcharrMovie, .dispatcharrSeries: return true
        default: return false
        }
    }
}
