package com.mohamedt.streamforge.metadata

import com.mohamedt.streamforge.core.Details
import com.mohamedt.streamforge.core.Episode
import com.mohamedt.streamforge.core.Http
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.MediaType
import com.mohamedt.streamforge.core.Person
import com.mohamedt.streamforge.core.dbl
import com.mohamedt.streamforge.core.int
import com.mohamedt.streamforge.core.str
import com.mohamedt.streamforge.core.long
import com.mohamedt.streamforge.core.obj
import com.mohamedt.streamforge.core.objects
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.stremio.Addons
import java.util.concurrent.ConcurrentHashMap

/** Merges metadata from the IPTV provider, TMDB and Cinemeta (in that order of preference for playback ids). */
object Metadata {
    private val cache = ConcurrentHashMap<String, Details>()
    val collections = ConcurrentHashMap<String, Pair<Int, String>>()

    suspend fun details(item: MediaItem): Details {
        cache[item.id]?.let { return it }
        var it = item
        var episodes = mutableMapOf<Int, List<Episode>>()
        var cast = emptyList<Person>()
        var directors = emptyList<String>()
        var trailer: String? = null
        var similar = emptyList<MediaItem>()
        var seasons = emptyList<Int>()

        // 1. Provider (Dispatcharr): ids, plot, playable episodes.
        val client = DispatcharrRepo.client
        if (client != null) when (item.origin.kind) {
            "xc-movie" -> runCatching { client.vodInfo(item.origin.id) }.getOrNull()?.let { v ->
                it = it.copy(
                    overview = it.overview ?: v.plot, poster = it.poster ?: v.cover, backdrop = it.backdrop ?: v.backdrop,
                    tmdbId = it.tmdbId ?: v.tmdbId, imdbId = it.imdbId ?: v.imdbId,
                    runtimeMinutes = v.durationSecs?.takeIf { s -> s > 0 }?.div(60) ?: it.runtimeMinutes,
                )
                v.director?.let { d -> directors = d.split(",").map { s -> s.trim() } }
                v.cast?.let { c -> cast = c.split(",").take(15).mapIndexed { i, n -> Person(-i - 1, n.trim()) } }
                trailer = v.trailer?.let { t -> youtubeKey(t) }
            }
            "xc-series" -> runCatching { client.seriesInfo(item.origin.id) }.getOrNull()?.let { s ->
                it = it.copy(overview = it.overview ?: s.plot, backdrop = it.backdrop ?: s.backdrop,
                    tmdbId = it.tmdbId ?: s.tmdbId, imdbId = it.imdbId ?: s.imdbId)
                trailer = s.trailer?.let { t -> youtubeKey(t) }
                for ((season, list) in s.episodes) {
                    episodes[season] = list.map { e ->
                        Episode(id = "xc-ep-${e.id}", season = season, episode = e.episode, title = e.title, overview = e.plot,
                            still = e.image, airDate = e.airDate, runtimeMinutes = e.durationSecs?.div(60),
                            xcEpisodeId = e.id, ext = e.ext, stremioVideoId = it.imdbId?.let { i -> "$i:$season:${e.episode}" })
                    }
                }
                seasons = episodes.keys.sorted()
            }
        }

        // 2. TMDB.
        if (Tmdb.configured && it.type != MediaType.CHANNEL) {
            if (it.tmdbId == null) {
                it = it.copy(tmdbId = it.imdbId?.let { i -> runCatching { Tmdb.findByImdb(i)?.tmdbId }.getOrNull() }
                    ?: runCatching { Tmdb.searchBest(it.title, it.year, it.type) }.getOrNull())
            }
            it.tmdbId?.let { id ->
                runCatching { Tmdb.details(id, it.type) }.getOrNull()?.let { t ->
                    val o = t.raw
                    it = it.copy(
                        overview = it.overview?.takeIf { s -> s.isNotBlank() } ?: o.str("overview"),
                        poster = it.poster ?: Tmdb.image(o.str("poster_path")),
                        backdrop = it.backdrop ?: Tmdb.image(o.str("backdrop_path"), "w1280"),
                        logo = it.logo ?: t.logo, imdbId = it.imdbId ?: t.imdbId,
                        year = it.year ?: (o.str("release_date") ?: o.str("first_air_date"))?.take(4)?.toIntOrNull(),
                        rating = it.rating ?: o.dbl("vote_average")?.takeIf { r -> r > 0 },
                        genres = it.genres.ifEmpty { o.objects("genres").mapNotNull { g -> g.str("name") } },
                        runtimeMinutes = it.runtimeMinutes ?: o.int("runtime"),
                    )
                    if (t.cast.isNotEmpty()) cast = t.cast
                    if (t.directors.isNotEmpty()) directors = t.directors
                    trailer = trailer ?: t.trailer
                    similar = t.similar
                    if (seasons.isEmpty()) seasons = t.seasons
                    if (t.collectionId != null && t.collectionName != null) collections[it.id] = t.collectionId to t.collectionName
                }
            }
        }

        // 3. Cinemeta / addon meta.
        val sid = it.stremioId
        if (sid != null && (it.overview.isNullOrBlank() || it.poster == null || (it.type == MediaType.SERIES && episodes.isEmpty() && !Tmdb.configured))) {
            Addons.meta(it.type.stremio, sid, it.origin.addonId)?.second?.let { m ->
                it = it.copy(overview = it.overview ?: m.description, poster = it.poster ?: m.poster, backdrop = it.backdrop ?: m.background,
                    logo = it.logo ?: m.logo, imdbId = it.imdbId ?: m.imdbId, rating = it.rating ?: m.imdbRating,
                    genres = it.genres.ifEmpty { m.genres })
                if (cast.isEmpty()) cast = m.cast.take(15).mapIndexed { i, n -> Person(-100 - i, n) }
                trailer = trailer ?: m.trailer
                if (episodes.isEmpty() && m.videos.isNotEmpty()) {
                    episodes = m.videos.groupBy { v -> v.season }.mapValues { (_, l) -> l.sortedBy { v -> v.episode } }.toMutableMap()
                    seasons = episodes.keys.filter { s -> s > 0 || episodes.size == 1 }.sorted()
                }
            }
        }
        if (it.logo == null && it.imdbId != null) it = it.copy(logo = "https://images.metahub.space/logo/medium/${it.imdbId}/img")

        val d = Details(item = it, cast = cast, directors = directors, trailerKey = trailer, seasons = seasons,
            episodes = episodes, similar = similar)
        cache[item.id] = d
        return d
    }

    /** Episodes of a season: provider episodes (playable from the server) enriched with TMDB stills/titles. */
    suspend fun episodes(details: Details, season: Int): List<Episode> {
        val own = details.episodes[season] ?: emptyList()
        val tvId = details.item.tmdbId
        if (!Tmdb.configured || tvId == null || details.item.type != MediaType.SERIES) return own
        val tmdb = runCatching { Tmdb.season(tvId, season, details.item.imdbId) }.getOrNull() ?: return own
        if (own.isEmpty()) return tmdb
        return own.map { e ->
            val t = tmdb.firstOrNull { it.episode == e.episode } ?: return@map e
            e.copy(
                still = e.still ?: t.still, overview = e.overview?.takeIf { it.isNotBlank() } ?: t.overview,
                title = if (e.title.lowercase().startsWith("episode") || e.title.contains("S0")) t.title else e.title,
                airDate = e.airDate ?: t.airDate, runtimeMinutes = e.runtimeMinutes ?: t.runtimeMinutes,
            )
        }
    }

    fun youtubeKey(raw: String): String? {
        if (!raw.contains("/") && !raw.contains("=")) return raw
        Regex("""[?&]v=([\w-]{6,})""").find(raw)?.let { return it.groupValues[1] }
        return raw.substringAfterLast('/').takeIf { it.isNotEmpty() }
    }

}

/** Skip intro / recap / credits markers from TheIntroDB (no API key needed). */
object IntroDb {
    data class Segment(val kind: String, val start: Long, val end: Long)

    suspend fun segments(tmdbId: Int?, imdbId: String?, season: Int?, episode: Int?, durationMs: Long?): List<Segment> {
        if (tmdbId == null && imdbId == null) return emptyList()
        val q = buildString {
            append(if (tmdbId != null) "tmdb_id=$tmdbId" else "imdb_id=$imdbId")
            if (season != null && episode != null) append("&season=$season&episode=$episode")
            if (durationMs != null && durationMs > 0) append("&duration_ms=$durationMs")
        }
        val o = runCatching { Http.json("https://api.theintrodb.org/v3/media?$q").obj() }.getOrNull() ?: return emptyList()
        return listOf("intro", "recap", "credits").flatMap { kind ->
            o.objects(kind).mapNotNull { s ->
                val start = s.long("start_ms") ?: 0L
                val end = s.long("end_ms") ?: return@mapNotNull null
                if (end > start) Segment(kind, start, end) else null
            }
        }
    }
}
