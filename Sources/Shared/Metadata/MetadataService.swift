import Foundation

/// Merges metadata from the IPTV provider, TMDB, Cinemeta, OMDb and Fanart.tv according to the
/// user's priority order, and caches the result.
@MainActor
final class MetadataService {
    static let shared = MetadataService()

    private let detailCache = ResponseCache<MediaDetails>(ttl: 3600, limit: 200)
    private let posterCache = ResponseCache<URL>(ttl: 86_400, limit: 5000)
    private var posterMisses = Set<String>()

    private var settings: AppSettings { AppSettings.shared }
    var tmdb: TMDBClient { TMDBClient(key: settings.tmdbKey, language: settings.values.metadataLanguage) }
    private var omdb: OMDbClient { OMDbClient(key: settings.omdbKey) }
    private var fanart: FanartClient { FanartClient(key: settings.fanartKey) }

    // MARK: Posters for grids

    /// Returns a better poster for items whose provider artwork is missing. Cheap: cached and
    /// skipped entirely when TMDB isn't configured or enrichment is off.
    func enrichedPoster(for item: MediaItem) async -> URL? {
        if let cached = await posterCache.value(item.id) { return cached }
        guard settings.values.enrichPosters, tmdb.isConfigured, !posterMisses.contains(item.id) else { return nil }
        var url: URL?
        if let tmdbID = item.tmdbID, let d = try? await tmdb.details(id: tmdbID, type: item.type) {
            url = TMDBClient.image(d.poster_path, size: "w342")
        } else if let s = try? await tmdb.searchBest(title: item.title, year: item.year, type: item.type) {
            url = TMDBClient.image(s.poster, size: "w342")
        }
        if let url { await posterCache.set(item.id, url) } else { posterMisses.insert(item.id) }
        return url
    }

    // MARK: Details

    func details(for item: MediaItem) async -> MediaDetails {
        if let cached = await detailCache.value(item.id) { return cached }
        var details = MediaDetails(item: item)

        // 1. Provider metadata (Dispatcharr) fills the baseline and gives TMDB/IMDb ids.
        await mergeProvider(&details)

        // 2. Resolve ids we don't have yet.
        if details.item.tmdbID == nil, tmdb.isConfigured {
            if let imdb = details.item.imdbID, let found = try? await tmdb.find(imdbID: imdb) {
                details.item.tmdbID = found.tmdbID
            } else if let s = try? await tmdb.searchBest(title: details.item.title, year: details.item.year, type: details.item.type) {
                details.item.tmdbID = s.id
            }
        }

        // 3. Rich sources in user priority order. Earlier sources win for text/art.
        for source in settings.values.metadataPriority {
            switch source {
            case .tmdb: await mergeTMDB(&details)
            case .cinemeta: await mergeCinemeta(&details)
            case .provider: break
            }
        }
        if settings.values.metadataPriority.first == .provider {
            await mergeProvider(&details, overwrite: true)
        }

        // 4. Ratings + logos.
        if let imdb = details.item.imdbID, omdb.isConfigured, let r = try? await omdb.ratings(imdbID: imdb) {
            details.ratings = r.badges + details.ratings.filter { b in !r.badges.contains { $0.source == b.source } }
            if details.certification == nil { details.certification = r.rated }
        }
        if details.item.logo == nil, let tmdbID = details.item.tmdbID, fanart.isConfigured {
            details.item.logo = await fanart.logo(tmdbID: tmdbID, type: details.item.type, lang: settings.values.metadataLanguage)
        }
        if details.item.logo == nil, let imdb = details.item.imdbID {
            details.item.logo = URL(string: "https://images.metahub.space/logo/medium/\(imdb)/img")
        }

        await detailCache.set(item.id, details)
        return details
    }

    private func mergeProvider(_ d: inout MediaDetails, overwrite: Bool = false) async {
        let store = DispatcharrStore.shared
        guard let client = store.client else { return }
        switch d.item.origin {
        case .dispatcharrMovie(_, let streamID, _):
            guard let info = try? await client.movieInfo(streamID) else { return }
            if overwrite || d.item.overview == nil { d.item.overview = info.plot ?? d.item.overview }
            if overwrite || d.item.poster == nil { d.item.poster = info.cover ?? d.item.poster }
            if overwrite || d.item.backdrop == nil { d.item.backdrop = info.backdrop ?? d.item.backdrop }
            d.item.tmdbID = d.item.tmdbID ?? info.tmdbID.flatMap { $0 > 0 ? $0 : nil }
            d.item.imdbID = d.item.imdbID ?? info.imdbID
            if let secs = info.durationSecs, secs > 0 { d.item.runtimeMinutes = secs / 60 }
            if d.directors.isEmpty, let dir = info.director { d.directors = dir.split(separator: ",").map { String($0).trimmed } }
            if d.cast.isEmpty, let cast = info.cast {
                d.cast = cast.split(separator: ",").prefix(15).enumerated().map { Person(id: -$0.offset - 1, name: String($0.element).trimmed) }
            }
            if d.trailerYouTubeKey == nil, let t = info.trailer, !t.isEmpty { d.trailerYouTubeKey = Self.youtubeKey(t) }
        case .dispatcharrSeries(_, let seriesID):
            guard let info = try? await client.seriesInfo(seriesID) else { return }
            if overwrite || d.item.overview == nil { d.item.overview = info.plot ?? d.item.overview }
            if overwrite || d.item.backdrop == nil { d.item.backdrop = info.backdrop ?? d.item.backdrop }
            d.item.tmdbID = d.item.tmdbID ?? info.tmdbID.flatMap { $0 > 0 ? $0 : nil }
            d.item.imdbID = d.item.imdbID ?? info.imdbID
            if d.trailerYouTubeKey == nil, let t = info.trailer, !t.isEmpty { d.trailerYouTubeKey = Self.youtubeKey(t) }
            // Provider episodes are what's actually playable from the server.
            var seasons: [SeasonInfo] = []
            for (number, eps) in info.episodes.sorted(by: { $0.key < $1.key }) {
                let s = info.seasons.first { $0.number == number }
                seasons.append(SeasonInfo(number: number, name: s?.name ?? "Season \(number)", poster: s?.cover, episodeCount: eps.count))
                d.episodesBySeason[number] = eps.map { e in
                    EpisodeRef(id: "xc-ep-\(e.id)", season: number, episode: e.episode, title: e.title, overview: e.plot,
                               still: e.image, airDate: e.airDate, runtimeMinutes: e.durationSecs.map { $0 / 60 },
                               dispatcharrEpisodeID: e.id, ext: e.ext,
                               stremioVideoID: d.item.imdbID.map { "\($0):\(number):\(e.episode)" })
                }
            }
            d.seasons = seasons
        default:
            break
        }
    }

    private func mergeTMDB(_ d: inout MediaDetails) async {
        guard tmdb.isConfigured, let id = d.item.tmdbID, let t = try? await tmdb.details(id: id, type: d.item.type) else { return }
        let lang = settings.values.metadataLanguage
        if d.item.overview?.isEmpty ?? true { d.item.overview = t.overview }
        if d.item.poster == nil { d.item.poster = TMDBClient.image(t.poster_path, size: "w500") }
        // Provider backdrops are often low-res; TMDB's are reliably good.
        if let b = TMDBClient.image(t.backdrop_path, size: "w1280") { d.item.backdrop = d.item.backdrop ?? b }
        if d.item.year == nil { d.item.year = (t.release_date ?? t.first_air_date).flatMap { Int($0.prefix(4)) } }
        if d.item.genres.isEmpty { d.item.genres = t.genres?.map(\.name) ?? [] }
        d.item.imdbID = d.item.imdbID ?? t.imdb_id ?? t.external_ids?.imdb_id
        d.item.runtimeMinutes = d.item.runtimeMinutes ?? t.runtime ?? t.episode_run_time?.first
        d.tagline = d.tagline ?? t.tagline.flatMap { $0.isEmpty ? nil : $0 }
        d.status = t.status
        d.networks = t.networks?.map(\.name) ?? []
        if d.collection == nil { d.collection = t.belongs_to_collection?.info }
        if let v = t.vote_average, v > 0 {
            d.ratings.append(RatingBadge(source: "TMDB", value: String(format: "%.1f", v)))
            if d.item.rating == nil { d.item.rating = v }
        }
        if let logos = t.images?.logos, !logos.isEmpty {
            let pick = logos.first { $0.iso_639_1 == lang } ?? logos.first { $0.iso_639_1 == "en" } ?? logos.first
            d.item.logo = d.item.logo ?? TMDBClient.image(pick?.file_path, size: "w500")
        }
        if let cast = t.credits?.cast, !cast.isEmpty {
            d.cast = cast.prefix(20).map { Person(id: $0.id, name: $0.name, role: $0.character, photo: TMDBClient.image($0.profile_path, size: "w185")) }
        }
        if let crew = t.credits?.crew {
            let dirs = crew.filter { $0.job == "Director" }.map(\.name)
            if !dirs.isEmpty { d.directors = dirs }
        }
        if let vids = t.videos?.results.filter({ $0.site == "YouTube" }) {
            let trailer = vids.first { $0.type == "Trailer" && $0.official == true } ?? vids.first { $0.type == "Trailer" } ?? vids.first
            d.trailerYouTubeKey = d.trailerYouTubeKey ?? trailer?.key
        }
        d.similar = t.recommendations?.results.elements.prefix(20).map { $0.mediaItem(defaultType: d.item.type) } ?? d.similar
        let region = Locale.current.region?.identifier ?? "US"
        if let rel = t.release_dates?.results {
            let c = rel.first { $0.iso_3166_1 == region } ?? rel.first { $0.iso_3166_1 == "US" }
            d.certification = c?.release_dates.compactMap(\.certification).first { !$0.isEmpty }
        }
        if let cr = t.content_ratings?.results {
            d.certification = (cr.first { $0.iso_3166_1 == region } ?? cr.first { $0.iso_3166_1 == "US" })?.rating
        }
        if d.item.type == .series, let seasons = t.seasons {
            let tmdbSeasons = seasons.filter { $0.season_number > 0 || seasons.count == 1 }.map {
                SeasonInfo(number: $0.season_number, name: $0.name ?? "Season \($0.season_number)",
                           poster: TMDBClient.image($0.poster_path, size: "w342"), episodeCount: $0.episode_count)
            }
            if d.seasons.isEmpty {
                d.seasons = tmdbSeasons
            } else {
                // Keep provider seasons (playable) but borrow TMDB posters.
                d.seasons = d.seasons.map { s in
                    var s = s
                    if s.poster == nil { s.poster = tmdbSeasons.first { $0.number == s.number }?.poster }
                    return s
                }
            }
        }
    }

    private func mergeCinemeta(_ d: inout MediaDetails) async {
        guard let imdb = d.item.imdbID ?? (d.item.stremioID?.hasPrefix("tt") == true ? d.item.stremioID : nil) else {
            if case .stremio(let addonID, let metaID) = d.item.origin,
               case let (_, meta)? = await AddonManager.shared.meta(type: d.item.type.stremioType, id: metaID, preferredAddonID: addonID) {
                apply(meta, to: &d)
            }
            return
        }
        guard case let (_, meta)? = await AddonManager.shared.meta(type: d.item.type.stremioType, id: imdb) else { return }
        apply(meta, to: &d)
    }

    private func apply(_ meta: StremioMetaPreview, to d: inout MediaDetails) {
        if d.item.overview?.isEmpty ?? true { d.item.overview = meta.description }
        d.item.poster = d.item.poster ?? meta.poster
        d.item.backdrop = d.item.backdrop ?? meta.background
        d.item.logo = d.item.logo ?? meta.logo
        d.item.year = d.item.year ?? meta.year
        if d.item.genres.isEmpty { d.item.genres = meta.genres }
        d.item.imdbID = d.item.imdbID ?? meta.imdbID
        if let r = meta.imdbRating, !d.ratings.contains(where: { $0.source == "IMDb" }) {
            d.ratings.insert(RatingBadge(source: "IMDb", value: String(format: "%.1f", r)), at: 0)
        }
        if d.trailerYouTubeKey == nil { d.trailerYouTubeKey = meta.trailers.first { $0.type == "Trailer" }?.source ?? meta.trailers.first?.source }
        if d.cast.isEmpty {
            let names = meta.links.filter { $0.category == "Cast" }.compactMap(\.name)
            d.cast = names.prefix(15).enumerated().map { Person(id: -1000 - $0.offset, name: $0.element) }
        }
        if d.item.type == .series, d.episodesBySeason.isEmpty, !meta.videos.isEmpty {
            let grouped = Dictionary(grouping: meta.videos.map(\.episodeRef), by: \.season)
            for (season, eps) in grouped { d.episodesBySeason[season] = eps.sorted { $0.episode < $1.episode } }
            if d.seasons.isEmpty {
                d.seasons = grouped.keys.sorted().filter { $0 > 0 || grouped.count == 1 }.map {
                    SeasonInfo(number: $0, name: $0 == 0 ? "Specials" : "Season \($0)", episodeCount: grouped[$0]?.count)
                }
            }
        }
    }

    /// Episodes for a season, merging playable provider episodes with TMDB stills and titles.
    func episodes(for details: MediaDetails, season: Int) async -> [EpisodeRef] {
        var eps = details.episodesBySeason[season] ?? []
        guard tmdb.isConfigured, let tvID = details.item.tmdbID, details.item.type == .series,
              let s = try? await tmdb.season(tvID: tvID, season: season) else { return eps }
        if eps.isEmpty {
            return s.episodes.map { e in
                EpisodeRef(id: "tmdb-\(tvID)-\(season)-\(e.episode_number)", season: season, episode: e.episode_number,
                           title: e.name ?? "Episode \(e.episode_number)", overview: e.overview,
                           still: TMDBClient.image(e.still_path, size: "w500"), airDate: e.air_date, runtimeMinutes: e.runtime,
                           stremioVideoID: details.item.imdbID.map { "\($0):\(season):\(e.episode_number)" })
            }
        }
        eps = eps.map { ep in
            var ep = ep
            if let t = s.episodes.first(where: { $0.episode_number == ep.episode }) {
                if ep.still == nil { ep.still = TMDBClient.image(t.still_path, size: "w500") }
                if ep.overview?.isEmpty ?? true { ep.overview = t.overview }
                // Provider titles are often just "Episode 3".
                if let name = t.name, ep.title.lowercased().hasPrefix("episode") || ep.title.contains("S0") { ep.title = name }
                ep.airDate = ep.airDate ?? t.air_date
                ep.runtimeMinutes = ep.runtimeMinutes ?? t.runtime
            }
            return ep
        }
        return eps
    }

    static func youtubeKey(_ raw: String) -> String? {
        if !raw.contains("/") && !raw.contains("=") { return raw }
        if let comps = URLComponents(string: raw) {
            if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value { return v }
            let last = comps.path.split(separator: "/").last.map(String.init)
            return last
        }
        return nil
    }
}
