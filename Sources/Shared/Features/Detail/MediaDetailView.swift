import SwiftUI

@MainActor
@Observable
final class DetailModel {
    var details: MediaDetails
    var loading = true
    var season: Int?
    var episodes: [EpisodeRef] = []
    var loadingEpisodes = false
    var sources: SourcesModel?

    init(item: MediaItem) { details = MediaDetails(item: item) }

    func load() async {
        guard loading else { return }
        let d = await MetadataService.shared.details(for: details.item)
        details = d
        loading = false
        // Faces for cast lists that came as plain names; runs alongside sources/episodes.
        Task { await resolveCastPhotos() }
        if d.item.type == .series {
            let lib = LibraryStore.shared
            let resumeSeason = lib.latestEpisodeProgress(for: d.item)?.episode?.season
            let first = d.seasons.first { $0.number > 0 }?.number ?? d.seasons.first?.number
            await selectSeason(resumeSeason ?? first ?? 1)
        } else if d.item.type == .movie {
            let s = SourcesModel(item: d.item, episode: nil)
            sources = s
            await s.load()
        }
    }

    func resolveCastPhotos() async {
        let snapshot = details
        let resolved = await MetadataService.shared.castWithPhotos(for: snapshot)
        guard resolved != details.cast, details.item.id == snapshot.item.id else { return }
        details.cast = resolved
    }

    func selectSeason(_ number: Int) async {
        season = number
        loadingEpisodes = true
        let eps = await MetadataService.shared.episodes(for: details, season: number)
        if season == number { episodes = eps }
        loadingEpisodes = false
    }

    /// Episodes after `episode` in the loaded season, for autoplay.
    func upcoming(after episode: EpisodeRef) -> [EpisodeRef] {
        guard let i = episodes.firstIndex(where: { $0.id == episode.id }) else { return [] }
        return Array(episodes.dropFirst(i + 1))
    }

    /// The episode the big Play button should start.
    func nextEpisodeToWatch() -> EpisodeRef? {
        let lib = LibraryStore.shared
        if let p = lib.latestEpisodeProgress(for: details.item), let ep = p.episode {
            if !p.isFinished, let match = episodes.first(where: { $0.season == ep.season && $0.episode == ep.episode }) { return match }
            if p.isFinished, let index = episodes.firstIndex(where: { $0.id == ep.id }),
               let next = episodes.dropFirst(index + 1).first(where: { !lib.isWatched(details.item, episode: $0) }) { return next }
        }
        return episodes.first { !lib.isWatched(details.item, episode: $0) } ?? episodes.first
    }
}

struct MediaDetailView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var model: DetailModel
    @State private var sourceSheet: SourceSheetContext?
    @State private var downloadSheet: DownloadSheetContext?
    @State private var expandedOverview = false
    @State private var trailer = TrailerController()
    @State private var heroVisible = true
    @State private var pageVisible = false
    @State private var appearedAt = Date()

    init(item: MediaItem) {
        _model = State(initialValue: DetailModel(item: item))
    }

    private var item: MediaItem { model.details.item }

    var body: some View {
        // Every size on this page comes from the live container size (never cached in @State), so
        // rotation, iPad split view and the player's landscape lock/unlock simply lay it out again.
        GeometryReader { geo in
            let layout = detailLayout(for: geo)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(layout)
                    actions
                    if let overview = item.overview, !overview.isEmpty { overviewView(overview) }
                    if item.type == .series { seasonsAndEpisodes(layout) }
                    if item.type == .movie, let sources = model.sources { inlineSources(sources) }
                    if item.type == .movie, let collection = model.details.collection {
                        CollectionRow(collection: collection, currentItem: item)
                    }
                    castRow
                    similarRow
                    infoSection
                    Color.clear.frame(height: 30)
                }
                // Exactly the visible width: a row that can't shrink any further is cut off on
                // its own instead of stretching the whole page past the screen edges.
                .frame(width: layout.width, alignment: .leading)
            }
            .ignoresSafeArea(edges: .top)
        }
        .screenBackground()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .task {
            NewEpisodeTracker.shared.markSeen(item)
            await model.load()
        }
        // Trailer: backdrop first, video ~2.5 s after the page appeared; paused whenever the hero
        // is scrolled away, the app is in the background, a player/sheet covers it or the page is left.
        .onAppear { pageVisible = true; appearedAt = Date() }
        .onDisappear { pageVisible = false }
        .onChange(of: trailerActive, initial: true) { _, active in trailer.setActive(active) }
        .onChange(of: model.details.trailerKeys, initial: true) { _, keys in
            let remaining = TrailerPolicy.startDelay - Date().timeIntervalSince(appearedAt)
            trailer.setKeys(keys, delay: max(0.4, remaining))
        }
        .sheet(item: $sourceSheet) { ctx in
            SourcesSheet(context: ctx)
        }
        #if os(iOS)
        .sheet(item: $downloadSheet) { ctx in
            DownloadSourceSheet(context: ctx)
        }
        #endif
    }

    // MARK: Layout

    /// Sizes for one layout pass, computed from the container (portrait, landscape, split view).
    private struct DetailLayout {
        /// Visible width (inside the horizontal safe area, so clear of the notch in landscape).
        var width: CGFloat
        var heroHeight: CGFloat
        var showsHeroPoster: Bool
        var episodeStillWidth: CGFloat
    }

    private var isRegularWidth: Bool {
        #if os(iOS)
        return horizontalSizeClass == .regular
        #else
        return true
        #endif
    }

    private func detailLayout(for geo: GeometryProxy) -> DetailLayout {
        let width = max(geo.size.width, 1)
        #if os(tvOS)
        return DetailLayout(width: width, heroHeight: 700, showsHeroPoster: false, episodeStillWidth: 320)
        #else
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let regular = isPad && isRegularWidth
        // Same heights as before in portrait / full-screen iPad; in landscape (or any short
        // window) the hero is capped so the title, actions and episodes are not pushed off screen.
        let base: CGFloat = regular ? 560 : 440
        let visibleHeight = geo.size.height + geo.safeAreaInsets.top
        let hero = min(base, max(240, visibleHeight * 0.8))
        // Narrow iPad split views get the phone-sized still; never more than ~40 % of the row.
        let stillBase: CGFloat = regular ? 220 : 140
        let still = min(stillBase, max(96, (width - 2 * Theme.gutter) * 0.42))
        return DetailLayout(width: width, heroHeight: hero, showsHeroPoster: regular && hero >= 400, episodeStillWidth: still)
        #endif
    }

    // MARK: Header

    private var trailerActive: Bool {
        pageVisible && heroVisible && scenePhase == .active
            && player.current == nil && player.multiview == nil && player.sourcePickerRequest == nil
            && sourceSheet == nil && downloadSheet == nil
            && TrailerPolicy.allowsAutoplay
    }

    @ViewBuilder
    private func header(_ layout: DetailLayout) -> some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 20) {
            RemoteImage(url: item.backdrop ?? item.poster)
                .frame(width: layout.width, height: min(layout.width * 9 / 16, layout.heroHeight))
                .overlay { TrailerSurface(controller: trailer) }
                .overlay(alignment: .bottomTrailing) { TrailerControlButton(controller: trailer).padding(16) }
                .clipped()
                .background(HeroVisibilityReader(height: min(layout.width * 9 / 16, layout.heroHeight), isVisible: $heroVisible))
            VStack(alignment: .leading, spacing: 10) {
                Text(item.title).font(.largeTitle.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                metaLine.foregroundStyle(Theme.secondaryText)
                if !model.details.ratings.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(model.details.ratings) { RatingBadgeView(badge: $0) } }
                    }
                }
            }.padding(.horizontal, Theme.gutter)
        }
        #else
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: item.backdrop ?? item.poster)
                .frame(width: layout.width, height: layout.heroHeight)
                .overlay {
                    // Muted trailer over the artwork, edge to edge (setting: Player → Autoplay trailers).
                    TrailerSurface(controller: trailer)
                }
                .clipped()
                .overlay(LinearGradient(colors: [.black.opacity(0.35), .clear, Theme.background.opacity(0.85), Theme.background],
                                        startPoint: .top, endPoint: .bottom))
                .background(HeroVisibilityReader(height: layout.heroHeight, isVisible: $heroVisible))
            HStack(alignment: .bottom, spacing: 18) {
                #if !os(tvOS)
                if layout.showsHeroPoster {
                    RemoteImage(url: item.poster, placeholderText: item.title)
                        .frame(width: 170, height: 255)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(radius: 20)
                }
                #endif
                VStack(alignment: .leading, spacing: 10) {
                    // Like Netflix, the title shrinks a little while the trailer plays.
                    Group {
                        if let logo = item.logo {
                            RemoteImage(url: logo, contentMode: .fit)
                                .frame(maxWidth: logoWidth, maxHeight: logoWidth * 0.38, alignment: .bottomLeading)
                        } else {
                            Text(item.title).font(.largeTitle.weight(.heavy)).lineLimit(3)
                        }
                    }
                    .scaleEffect(trailer.isRevealed ? 0.8 : 1, anchor: .bottomLeading)
                    .animation(.easeInOut(duration: TrailerPolicy.fade), value: trailer.isRevealed)
                    metaLine
                    if !model.details.ratings.isEmpty {
                        // One row of badges; shows fewer on a narrow screen instead of overflowing.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                ForEach(model.details.ratings) { RatingBadgeView(badge: $0) }
                            }
                            HStack(spacing: 8) {
                                ForEach(model.details.ratings.prefix(2)) { RatingBadgeView(badge: $0) }
                            }
                        }
                    }
                    if let tagline = model.details.tagline {
                        Text(tagline).font(.subheadline.italic()).foregroundStyle(Theme.secondaryText)
                            .opacity(trailer.isRevealed ? 0 : 1)
                            .animation(.easeInOut(duration: TrailerPolicy.fade), value: trailer.isRevealed)
                    }
                }
                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                Spacer(minLength: 0)
                TrailerControlButton(controller: trailer)
            }
            .padding(.horizontal, Theme.gutter)
            .frame(width: layout.width, alignment: .leading)
        }
        .frame(width: layout.width, alignment: .bottomLeading)
        #endif
    }

    private var logoWidth: CGFloat {
        #if os(tvOS)
        return 560
        #else
        return 300
        #endif
    }

    private var metaLine: some View {
        let parts: [String] = [
            item.yearText,
            item.runtimeMinutes.map { $0.runtimeText },
            model.details.certification,
            item.type == .series ? (model.details.seasons.isEmpty ? "Series" : "\(model.details.seasons.filter { $0.number > 0 }.count) Seasons") : nil,
        ].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 6) {
            Text(parts.joined(separator: "  ·  ")).font(.subheadline.weight(.semibold))
            if !item.genres.isEmpty {
                Text(item.genres.prefix(4).joined(separator: " · ")).font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        #if os(iOS)
        VStack(spacing: 12) {
            Button { playPrimary() } label: {
                Label(primaryLabel, systemImage: "play.fill")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .disabled(model.loading && item.type == .series)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Button { library.toggleFavorite(item) } label: {
                        Label(library.isFavorite(item) ? "In My List" : "My List", systemImage: library.isFavorite(item) ? "checkmark" : "plus")
                    }
                    if let key = model.details.trailerYouTubeKey, let url = URL(string: "https://www.youtube.com/watch?v=\(key)") {
                        Button { openURL(url) } label: { Label("Trailer", systemImage: "film") }
                    }
                    if item.type == .movie {
                        Button { sourceSheet = SourceSheetContext(item: item, episode: nil, upcoming: []) } label: {
                            Label("Sources", systemImage: "list.bullet")
                        }
                        if DownloadManager.isSupported {
                            DownloadButton(item: item, episode: nil) { downloadSheet = DownloadSheetContext(item: item, episode: nil) }
                                .accessibilityLabel("Download")
                        }
                        Button { library.setWatched(item, !library.isWatched(item)) } label: {
                            Label(library.isWatched(item) ? "Watched" : "Mark watched", systemImage: "checkmark.circle")
                        }
                    }
                }.buttonStyle(.bordered).controlSize(.large).font(.subheadline.weight(.semibold))
            }
        }.padding(.horizontal, Theme.gutter)
        #else
        HStack(spacing: 12) {
            Button { playPrimary() } label: {
                Label(primaryLabel, systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: actionMaxWidth)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(model.loading && item.type == .series)

            if item.type == .movie {
                Button { sourceSheet = SourceSheetContext(item: item, episode: nil, upcoming: []) } label: {
                    Image(systemName: "list.bullet").font(.headline).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
            #if os(iOS)
            // tvOS has no browser to open YouTube links in.
            if let key = model.details.trailerYouTubeKey, let url = URL(string: "https://www.youtube.com/watch?v=\(key)") {
                Button { openURL(url) } label: { Image(systemName: "film").font(.headline).padding(.vertical, 6) }
                    .buttonStyle(.bordered)
            }
            if item.type == .movie, DownloadManager.isSupported {
                DownloadButton(item: item, episode: nil) { downloadSheet = DownloadSheetContext(item: item, episode: nil) }
                    .buttonStyle(.bordered)
            }
            #endif
            Button { library.toggleFavorite(item) } label: {
                Image(systemName: library.isFavorite(item) ? "checkmark" : "plus").font(.headline).padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            if item.type == .movie {
                Button { library.setWatched(item, !library.isWatched(item)) } label: {
                    Image(systemName: library.isWatched(item) ? "eye.fill" : "eye").font(.headline).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, Theme.gutter)
        #endif
    }

    private var actionMaxWidth: CGFloat? {
        #if os(tvOS)
        return 360
        #else
        return .infinity
        #endif
    }

    private var primaryLabel: String {
        if item.type == .series {
            guard let ep = model.nextEpisodeToWatch() else { return "Play" }
            if let p = library.progress(for: item, episode: ep), p.fraction > 0.02 { return "Resume \(ep.code)" }
            return "Play \(ep.code)"
        }
        if let p = library.progress(for: item), p.fraction > 0.02 { return "Resume · \(p.remainingText)" }
        if model.sources?.isLoading == true && model.sources?.sources.isEmpty == true { return "Finding sources…" }
        return "Play"
    }

    private func playPrimary() {
        if item.type == .series {
            if let ep = model.nextEpisodeToWatch() { play(episode: ep) }
            return
        }
        if let best = model.sources?.sorted.first, model.sources?.sorted.count == 1 || best.isCached {
            player.play(PlaybackRequest(item: item, source: best))
        } else {
            sourceSheet = SourceSheetContext(item: item, episode: nil, upcoming: [])
        }
    }

    private func play(episode: EpisodeRef) {
        let upcoming = model.upcoming(after: episode)
        // Episodes hosted on the user's own server start instantly.
        if let eid = episode.dispatcharrEpisodeID, let url = DispatcharrStore.shared.playbackClient(for: item)?.episodeURL(eid, ext: episode.ext ?? "mp4") {
            let source = PlaybackSource(id: "xc-ep-\(eid)", kind: .direct(url, headers: [:]), title: "\(item.title) \(episode.code)",
                                        provider: DispatcharrStore.shared.playbackClient(for: item)?.server.name ?? "Server", isCached: true)
            player.play(PlaybackRequest(item: item, episode: episode, source: source, upcoming: upcoming))
        } else {
            sourceSheet = SourceSheetContext(item: item, episode: episode, upcoming: upcoming)
        }
    }

    // MARK: Overview

    private func overviewView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.body)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(expandedOverview ? nil : 4)
                .frame(maxWidth: 820, alignment: .leading)
            if text.count > 220 {
                Button(expandedOverview ? "Less" : "More") { withAnimation { expandedOverview.toggle() } }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, Theme.gutter)
    }

    // MARK: Series

    @ViewBuilder
    private func seasonsAndEpisodes(_ layout: DetailLayout) -> some View {
        let seasons = model.details.seasons
        VStack(alignment: .leading, spacing: 12) {
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(seasons) { s in
                            Button { Task { await model.selectSeason(s.number) } } label: {
                                Text(s.number == 0 ? "Specials" : "Season \(s.number)")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(model.season == s.number ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                    #if os(tvOS)
                    .padding(.vertical, 16)
                    #endif
                }
            } else if let s = seasons.first {
                SectionHeader(title: s.number == 0 ? "Specials" : "Season \(s.number)")
            }

            if model.loading || model.loadingEpisodes {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if model.episodes.isEmpty {
                Text("No episodes found.").foregroundStyle(Theme.secondaryText).padding(.horizontal, Theme.gutter)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(model.episodes) { ep in
                        EpisodeRow(item: item, episode: ep, onPlay: { play(episode: ep) },
                                   onDownload: { downloadSheet = DownloadSheetContext(item: item, episode: ep) },
                                   stillWidth: layout.episodeStillWidth)
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }
        }
    }

    // MARK: Movie sources

    private func inlineSources(_ sources: SourcesModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Sources",
                          subtitle: sources.isLoading ? "Asking \(max(sources.loadingAddons.count, 1)) source\(sources.loadingAddons.count == 1 ? "" : "s")…" : "\(sources.sorted.count) available",
                          action: sources.sorted.count > 5 ? { sourceSheet = SourceSheetContext(item: item, episode: nil, upcoming: []) } : nil)
            if sources.sorted.isEmpty && !sources.isLoading {
                Text("No sources found. Add stream addons in Settings → Addons, or check your Dispatcharr library.")
                    .font(.footnote).foregroundStyle(Theme.secondaryText).padding(.horizontal, Theme.gutter)
            }
            VStack(spacing: 8) {
                ForEach(sources.sorted.prefix(5)) { s in
                    SourceRow(source: s, estimate: sources.estimate(s)) { player.play(PlaybackRequest(item: item, source: s)) }
                }
            }
            .padding(.horizontal, Theme.gutter)
        }
    }

    // MARK: Cast / similar / info

    @ViewBuilder
    private var castRow: some View {
        if !model.details.cast.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Cast")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(Array(model.details.cast.enumerated()), id: \.offset) { _, person in
                            Button {
                                CastPhotoMemory.remember(person)
                                router.push(.person(id: person.id, name: person.name))
                            } label: {
                                VStack(spacing: 6) {
                                    CastAvatar(url: person.photo, name: person.name, size: castSize)
                                        .animation(.easeInOut(duration: 0.25), value: person.photo)
                                    Text(person.name).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                                    if let role = person.role, !role.isEmpty {
                                        Text(role).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
                                    }
                                }
                                .frame(width: castSize + 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows \(person.name)'s films on your server and in your addons")
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                }
            }
        }
    }

    private var castSize: CGFloat {
        #if os(tvOS)
        return 150
        #else
        return 76
        #endif
    }

    private var similarRow: some View {
        Shelf(title: "More Like This", items: model.details.similar) { s in
            Button { router.push(.detail(s)) } label: { PosterCard(item: s) }
                .cardButtonStyle()
        }
    }

    @ViewBuilder
    private var infoSection: some View {
        let d = model.details
        let rows: [(String, String)] = [
            ("Director", d.directors.joined(separator: ", ")),
            ("Network", d.networks.joined(separator: ", ")),
            ("Status", d.status ?? ""),
            ("Source", originLabel),
        ].filter { !$0.1.isEmpty }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.0) { row in
                    HStack(alignment: .top) {
                        Text(row.0).font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondaryText).frame(width: 90, alignment: .leading)
                        Text(row.1).font(.footnote)
                    }
                }
            }
            .padding(.horizontal, Theme.gutter)
        }
    }

    private var originLabel: String {
        switch item.origin {
        case .dispatcharrMovie, .dispatcharrSeries, .dispatcharrChannel: return DispatcharrStore.shared.activeServer?.name ?? "Dispatcharr"
        case .stremio(let addonID, _): return AddonManager.shared.addons.first { $0.id == addonID }?.manifest.name ?? "Stremio addon"
        case .tmdb: return "TMDB"
        }
    }
}

struct RatingBadgeView: View {
    var badge: RatingBadge
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2.weight(.heavy)).padding(.horizontal, 4).padding(.vertical, 1)
                .background(color, in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.black)
            Text(badge.value).font(.caption.weight(.bold))
        }
    }
    private var label: String {
        switch badge.source {
        case "IMDb": return "IMDb"
        case "Rotten Tomatoes": return "RT"
        case "Metacritic": return "MC"
        default: return badge.source
        }
    }
    private var color: Color {
        switch badge.source {
        case "IMDb": return Theme.gold
        case "Rotten Tomatoes": return Color(red: 0.98, green: 0.36, blue: 0.24)
        case "Metacritic": return Color(red: 0.4, green: 0.8, blue: 0.3)
        default: return Color(red: 0.0, green: 0.82, blue: 0.75)
        }
    }
}

struct EpisodeRow: View {
    var item: MediaItem
    var episode: EpisodeRef
    var onPlay: () -> Void
    /// iOS: offers "Download Episode" in the context menu.
    var onDownload: (() -> Void)? = nil
    /// Width of the episode still; the detail page sizes it from the available width. nil = default.
    var stillWidth: CGFloat? = nil
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let progress = library.progress(for: item, episode: episode)
        let watched = library.isWatched(item, episode: episode)
        Button(action: onPlay) {
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: episode.still ?? item.backdrop, placeholderSymbol: "play.rectangle")
                        .frame(width: still, height: still * 9 / 16)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    if let progress { ProgressLine(fraction: progress.fraction).padding(6) }
                    Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: still, height: still * 9 / 16)
                .clipped()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(episode.episode). \(episode.title)").font(.subheadline.weight(.semibold)).lineLimit(2)
                        Spacer(minLength: 0)
                        if watched { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                    }
                    HStack(spacing: 8) {
                        if let d = episode.airDate { Text(d) }
                        if let r = episode.runtimeMinutes, r > 0 { Text(r.runtimeText) }
                        if episode.dispatcharrEpisodeID != nil { Image(systemName: "server.rack") }
                    }
                    .font(.caption2).foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    if let o = episode.overview {
                        Text(o).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(3)
                    }
                }
                // Takes exactly the room left beside the still (long titles wrap/truncate here).
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { library.setWatched(item, episode: episode, !watched) } label: {
                Label(watched ? "Mark as Unwatched" : "Mark as Watched", systemImage: watched ? "eye.slash" : "eye")
            }
            if DownloadManager.isSupported, let onDownload {
                let record = DownloadManager.shared.record(for: item, episode: episode)
                if let record, record.state == .completed {
                    Button { DownloadManager.shared.play(record) } label: { Label("Play Download", systemImage: "arrow.down.circle.fill") }
                } else if record == nil || record?.state == .failed {
                    Button(action: onDownload) { Label("Download Episode", systemImage: "arrow.down.circle") }
                }
            }
        }
    }

    private var still: CGFloat { stillWidth ?? defaultStillWidth }

    private var defaultStillWidth: CGFloat {
        #if os(tvOS)
        return 320
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? 220 : 140
        #endif
    }
}
