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
import com.mohamedt.streamforge.core.cleanYouTubeKey
import com.mohamedt.streamforge.core.normalizeName
import java.util.Optional
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

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
        val trailers = mutableListOf<String>()
        fun addTrailers(raw: List<String?>, atFront: Boolean = false) {
            val keys = raw.mapNotNull { k -> cleanYouTubeKey(k) }.distinct().filter { k -> k !in trailers }
            if (atFront) trailers.addAll(0, keys) else trailers.addAll(keys)
        }
        var similar = emptyList<MediaItem>()
        var seasons = emptyList<Int>()

        // 1. Provider (Dispatcharr): ids, plot, playable episodes.
        val client = DispatcharrRepo.playbackClient(item)
        if (client != null) when (item.origin.kind) {
            "xc-movie" -> runCatching { client.vodInfo(item.origin.id) }.getOrNull()?.let { v ->
                it = it.copy(
                    overview = it.overview ?: v.plot, poster = it.poster ?: v.cover, backdrop = it.backdrop ?: v.backdrop,
                    tmdbId = it.tmdbId ?: v.tmdbId, imdbId = it.imdbId ?: v.imdbId,
                    runtimeMinutes = v.durationSecs?.takeIf { s -> s > 0 }?.div(60) ?: it.runtimeMinutes,
                )
                v.director?.let { d -> directors = d.split(",").map { s -> s.trim() } }
                v.cast?.let { c -> cast = castNames(c).take(20).mapIndexed { i, n -> Person(-i - 1, n) } }
                addTrailers(listOf(v.trailer))
            }
            "xc-series" -> runCatching { client.seriesInfo(item.origin.id) }.getOrNull()?.let { s ->
                it = it.copy(overview = it.overview ?: s.plot, backdrop = it.backdrop ?: s.backdrop,
                    tmdbId = it.tmdbId ?: s.tmdbId, imdbId = it.imdbId ?: s.imdbId)
                addTrailers(listOf(s.trailer))
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
                    if (t.cast.isNotEmpty()) {
                        // TMDB credits carry photos and person ids: they replace plain provider names.
                        val earlier = cast.filter { p -> p.photo != null }.associateBy { p -> normalizeName(p.name) }
                        cast = t.cast.map { p -> if (p.photo == null) p.copy(photo = earlier[normalizeName(p.name)]?.photo) else p }
                    }
                    if (t.directors.isNotEmpty()) directors = t.directors
                    // TMDB's ranked trailers first; provider/addon ids stay as fallbacks.
                    addTrailers(t.trailers, atFront = true)
                    similar = t.similar
                    if (seasons.isEmpty()) seasons = t.seasons
                    if (t.collectionId != null && t.collectionName != null) collections[it.id] = t.collectionId to t.collectionName
                }
            }
        }

        // 3. Cinemeta / addon meta: fills gaps, and is also asked when the cast still has no faces
        //    or there is no trailer (Cinemeta's metas carry cast photos and trailer ids).
        val sid = it.stremioId
        val castNeedsFaces = cast.isEmpty() || cast.none { p -> p.photo != null }
        if (sid != null && (it.overview.isNullOrBlank() || it.poster == null || castNeedsFaces || trailers.isEmpty() ||
                (it.type == MediaType.SERIES && episodes.isEmpty() && !Tmdb.configured))) {
            val preferred = it.origin.addonId ?: if (sid.startsWith("tt")) CINEMETA_ID else null
            Addons.meta(it.type.stremio, sid, preferred)?.second?.let { m ->
                it = it.copy(overview = it.overview ?: m.description, poster = it.poster ?: m.poster, backdrop = it.backdrop ?: m.background,
                    logo = it.logo ?: m.logo, imdbId = it.imdbId ?: m.imdbId, rating = it.rating ?: m.imdbRating,
                    genres = it.genres.ifEmpty { m.genres })
                cast = mergeAddonCast(cast, m.people, m.cast)
                addTrailers(m.trailers)
                if (episodes.isEmpty() && m.videos.isNotEmpty()) {
                    episodes = m.videos.groupBy { v -> v.season }.mapValues { (_, l) -> l.sortedBy { v -> v.episode } }.toMutableMap()
                    seasons = episodes.keys.filter { s -> s > 0 || episodes.size == 1 }.sorted()
                }
            }
        }
        if (it.logo == null && it.imdbId != null) it = it.copy(logo = "https://images.metahub.space/logo/medium/${it.imdbId}/img")

        val d = Details(item = it, cast = cast, directors = directors, trailerKey = trailers.firstOrNull(), seasons = seasons,
            episodes = episodes, similar = similar, trailerKeys = trailers.toList())
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

    private const val CINEMETA_ID = "com.linvo.cinemeta"

    /** Addon cast: faces (people) replace plain names; otherwise borrow missing faces by name. */
    private fun mergeAddonCast(current: List<Person>, people: List<Person>, names: List<String>): List<Person> {
        val top = people.take(20)
        val hasFaces = top.any { it.photo != null }
        if (current.isEmpty()) {
            return top.ifEmpty { names.map { it.trim() }.filter { it.isNotEmpty() }.take(20).mapIndexed { i, n -> Person(-100 - i, n) } }
        }
        if (!hasFaces) return current
        if (current.all { it.photo == null && it.id <= 0 }) return top
        val byName = top.associateBy { normalizeName(it.name) }
        val usedIds = current.map { it.id }.toMutableSet()
        return current.map { p ->
            if (p.photo != null) return@map p
            val m = byName[normalizeName(p.name)] ?: return@map p
            val newId = if (p.id <= 0 && m.id > 0 && usedIds.add(m.id)) m.id else p.id
            p.copy(id = newId, photo = m.photo, role = p.role ?: m.role)
        }
    }

    /** "Keanu Reeves (Neo), Carrie-Anne Moss / Laurence Fishburne as Morpheus" → names. */
    fun castNames(raw: String): List<String> = raw.split(',', ';', '/', '|', '\n')
        .map { part ->
            var n = part.replace(Regex("""\s*[(\[][^)\]]*[)\]]"""), "")
            val asIdx = n.indexOf(" as ", ignoreCase = true)
            if (asIdx > 0) n = n.substring(0, asIdx)
            n.trim()
        }
        .filter { it.isNotEmpty() && !it.equals("n/a", ignoreCase = true) }

    // Cast photos for names-only lists: the title's own TMDB credits first, then a person
    // search per name (cached, at most 20 lookups, 6 at a time).
    private val personCache = ConcurrentHashMap<String, Optional<Person>>()
    private val creditsCache = ConcurrentHashMap<String, List<Person>>()
    private val imdbCache = ConcurrentHashMap<String, Optional<Pair<Int, MediaType>>>()

    /** Details with faces filled in for cast entries that came as plain names. Returns [details] unchanged when nothing can be added. */
    suspend fun castWithPhotos(details: Details): Details {
        val cast = details.cast
        val targets = cast.indices.take(20).filter { cast[it].photo == null && cast[it].id <= 0 }
        if (!Tmdb.configured || targets.isEmpty()) return details
        val result = cast.toMutableList()
        val usedIds = cast.map { it.id }.toMutableSet()
        fun apply(i: Int, m: Person) {
            val p = result[i]
            val newId = if (p.id <= 0 && m.id > 0 && usedIds.add(m.id)) m.id else p.id
            result[i] = p.copy(id = newId, photo = p.photo ?: m.photo, role = p.role ?: m.role)
        }
        // 1. The title's credits (one request covers the whole list).
        val item = details.item
        var titleId = item.tmdbId
        var titleType = item.type
        val imdb = item.imdbId
        if (titleId == null && imdb != null && imdb.startsWith("tt")) {
            val cachedFind = imdbCache[imdb]
            val found: Pair<Int, MediaType>? = if (cachedFind != null) cachedFind.orElse(null) else {
                val r = runCatching { Tmdb.findByImdb(imdb) }
                val pair = r.getOrNull()?.let { f -> f.tmdbId?.let { id -> id to f.type } }
                if (r.isSuccess) imdbCache[imdb] = Optional.ofNullable(pair)
                pair
            }
            if (found != null) {
                titleId = found.first
                titleType = found.second
            }
        }
        var pending = targets
        val tid = titleId
        if (tid != null) {
            val key = "${titleType.name}:$tid"
            val credits = creditsCache[key] ?: runCatching { Tmdb.credits(tid, titleType) }.getOrNull()?.also { creditsCache[key] = it } ?: emptyList()
            val byName = credits.associateBy { normalizeName(it.name) }
            pending = targets.filter { i ->
                val m = byName[normalizeName(result[i].name)]
                if (m != null) apply(i, m)
                result[i].photo == null
            }
        }
        // 2. Person search by name, bounded concurrency.
        if (pending.isNotEmpty()) {
            val gate = Semaphore(6)
            val found = coroutineScope {
                pending.map { i ->
                    async { gate.withPermit { i to lookupPerson(result[i].name) } }
                }.awaitAll()
            }
            found.forEach { (i, m) -> if (m != null) apply(i, m) }
        }
        if (result == cast) return details
        val updated = details.copy(cast = result)
        val cached = cache[item.id]
        if (cached != null) cache[item.id] = cached.copy(cast = result)
        return updated
    }

    private suspend fun lookupPerson(name: String): Person? {
        val key = normalizeName(name)
        if (key.isEmpty()) return null
        personCache[key]?.let { return it.orElse(null) }
        return try {
            val p = Tmdb.findPerson(name)
            if (personCache.size > 3000) personCache.clear()
            personCache[key] = Optional.ofNullable(p)
            p
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null // network error: not cached, retried next time
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
