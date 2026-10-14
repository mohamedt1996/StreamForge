import SwiftUI

/// A TMDB collection part with its server availability.
struct CollectionPart: Identifiable, Hashable {
    var item: MediaItem
    var serverItem: MediaItem?
    var id: String { item.id }
}

@MainActor
enum CollectionLoader {
    private static var cache: [Int: (TMDBClient.CollectionDetails, Date)] = [:]

    static func parts(collectionID: Int) async -> (details: TMDBClient.CollectionDetails?, parts: [CollectionPart]) {
        let tmdb = MetadataService.shared.tmdb
        guard tmdb.isConfigured else { return (nil, []) }
        var details: TMDBClient.CollectionDetails?
        if let hit = cache[collectionID], Date().timeIntervalSince(hit.1) < 3600 {
            details = hit.0
        } else if let fetched = try? await tmdb.collection(id: collectionID) {
            cache[collectionID] = (fetched, Date())
            details = fetched
        }
        guard let details else { return (nil, []) }
        let summaries = (details.parts?.elements ?? []).sorted { ($0.date ?? "9999") < ($1.date ?? "9999") }
        let parts = KidsFilter.filter(summaries.map { $0.mediaItem(defaultType: .movie) }).map { item in
            CollectionPart(item: item, serverItem: CollectionsIndex.shared.serverItem(tmdbID: item.tmdbID ?? 0, title: item.title, year: item.year))
        }
        return (details, parts)
    }
}

/// "Part of the X Collection" on a movie's detail page.
struct CollectionRow: View {
    var collection: CollectionInfo
    var currentItem: MediaItem
    @Environment(AppRouter.self) private var router
    @State private var parts: [CollectionPart] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Always-present anchor so the task runs even before there is content.
            Color.clear.frame(height: 0)
            if parts.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Part of the \(collection.name.replacingOccurrences(of: " Collection", with: "")) Collection",
                                  subtitle: "\(parts.filter { $0.serverItem != nil }.count) of \(parts.count) on your server",
                                  action: { router.push(.collection(id: collection.id, name: collection.name)) })
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: spacing) {
                            ForEach(parts) { part in
                                CollectionPartCard(part: part, isCurrent: part.item.tmdbID == currentItem.tmdbID)
                            }
                        }
                        .padding(.horizontal, Theme.gutter)
                        #if os(tvOS)
                        .padding(.vertical, 30)
                        #endif
                    }
                    #if os(tvOS)
                    .scrollClipDisabled()
                    #endif
                }
            }
        }
        .task(id: collection.id) {
            parts = await CollectionLoader.parts(collectionID: collection.id).parts
        }
    }

    private var spacing: CGFloat {
        #if os(tvOS)
        return 40
        #else
        return 12
        #endif
    }
}

struct CollectionPartCard: View {
    var part: CollectionPart
    var isCurrent = false
    @Environment(AppRouter.self) private var router

    var body: some View {
        Button { router.push(.detail(part.serverItem ?? part.item)) } label: {
            PosterCard(item: part.item)
                .overlay(alignment: .topLeading) {
                    if isCurrent {
                        Pill(text: "THIS", color: Theme.accent, icon: "eye").padding(6)
                    } else if part.serverItem != nil {
                        Pill(text: "ON SERVER", color: Color.green.opacity(0.85), foreground: .black, icon: "server.rack").padding(6)
                    }
                }
        }
        .cardButtonStyle()
        .disabled(isCurrent)
    }
}

/// Full collection page.
struct CollectionView: View {
    var collectionID: Int
    var name: String
    @State private var details: TMDBClient.CollectionDetails?
    @State private var parts: [CollectionPart] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: TMDBClient.image(details?.backdrop_path, size: "w1280"))
                        .frame(maxWidth: .infinity)
                        .frame(height: bannerHeight)
                        .clipped()
                        .overlay(LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(details?.name ?? name).font(.largeTitle.weight(.heavy))
                        Text("\(parts.count) films · \(parts.filter { $0.serverItem != nil }.count) on your server")
                            .font(.subheadline).foregroundStyle(Theme.secondaryText)
                    }
                    .padding(.horizontal, Theme.gutter)
                }
                if let overview = details?.overview, !overview.isEmpty {
                    Text(overview).foregroundStyle(.white.opacity(0.85)).padding(.horizontal, Theme.gutter).frame(maxWidth: 860, alignment: .leading)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.posterWidth, maximum: Theme.posterWidth * 1.25), spacing: gridSpacing, alignment: .top)],
                          alignment: .leading, spacing: gridSpacing * 1.5) {
                    ForEach(parts) { CollectionPartCard(part: $0) }
                }
                .padding(.horizontal, Theme.gutter)
                if loading { ProgressView().frame(maxWidth: .infinity).padding() }
            }
            .padding(.bottom, 30)
        }
        .ignoresSafeArea(edges: .top)
        .screenBackground()
        .navigationTitle(name)
        .task {
            let result = await CollectionLoader.parts(collectionID: collectionID)
            details = result.details
            parts = result.parts
            loading = false
        }
    }

    private var bannerHeight: CGFloat {
        #if os(tvOS)
        return 520
        #else
        return 300
        #endif
    }

    private var gridSpacing: CGFloat {
        #if os(tvOS)
        return 48
        #else
        return 12
        #endif
    }
}

/// "Collections" shelf for the Movies tab, built from the server library.
struct CollectionsShelf: View {
    @Environment(AppRouter.self) private var router
    private var index: CollectionsIndex { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
            Shelf(title: "Collections", subtitle: index.isBuilding ? "Finding franchises in your library…" : "Franchises in your library",
                  items: index.collections) { entry in
                Button { router.push(.collection(id: entry.info.id, name: entry.info.name)) } label: {
                    LandscapeCard(title: entry.info.name, subtitle: "\(entry.items.count) movies",
                                  image: entry.info.backdrop, fallbackImage: entry.info.poster ?? entry.items.first?.poster,
                                  badge: "\(entry.items.count)", symbol: "film.stack")
                }
                .cardButtonStyle()
            }
        }
        .task(id: DispatcharrStore.shared.movies.count) { await index.buildIfNeeded() }
    }
}
