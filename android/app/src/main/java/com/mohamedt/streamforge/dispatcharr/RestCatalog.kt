package com.mohamedt.streamforge.dispatcharr

import com.mohamedt.streamforge.core.HttpException
import com.mohamedt.streamforge.core.Store
import com.mohamedt.streamforge.core.bool
import com.mohamedt.streamforge.core.buildUrl
import com.mohamedt.streamforge.core.child
import com.mohamedt.streamforge.core.dbl
import com.mohamedt.streamforge.core.int
import com.mohamedt.streamforge.core.long
import com.mohamedt.streamforge.core.str
import com.mohamedt.streamforge.core.strings
import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.temporal.ChronoUnit
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/*
 * REST streaming mode: account / API-key users whose Dispatcharr user has no XC password.
 *
 * Dispatcharr's XC endpoints (player_api.php, xmltv.php, /live, /movie, /series, /timeshift) reject a
 * user whose stored xc_password is empty, and only admins may set one (PATCH /api/accounts/users/{id}/
 * is IsAdmin; /users/me/ strips xc_password). Everything else the app needs works without it:
 *  - channels: /api/channels/channels/summary/ (or /api/channels/channels/ on older servers), groups:
 *    /api/channels/groups/, logos: /api/channels/logos/{id}/cache/ (public)
 *  - guide: /output/epg (no auth, "M3U / EPG" network setting) and /api/epg/programs/search/
 *  - movies / series: /api/vod/all/, /api/vod/categories/, /api/vod/{movies|series}/{id}/provider-info/
 *  - playback: /proxy/ts/stream/{channel uuid}, /proxy/vod/{movie|episode}/{uuid} (AllowAny, "Streams"
 *    network setting), so the player needs no auth header.
 * Ids are the same numbers the XC API uses (Channel.id, Movie.id, Episode.id); series use Series.id.
 */

/** Numeric Dispatcharr id → UUID (the proxy URLs need it), persisted per server. */
object DispatcharrUuids {
    const val CHANNEL = 'c'
    const val MOVIE = 'm'
    const val EPISODE = 'e'

    private val serializer = MapSerializer(String.serializer(), String.serializer())
    private val maps = HashMap<String, MutableMap<String, String>>()

    private fun fileName(serverId: String) = "dispatcharr-uuids-$serverId.json"

    private fun map(serverId: String): MutableMap<String, String> =
        maps.getOrPut(serverId) { (Store.load(serializer, fileName(serverId)) ?: emptyMap()).toMutableMap() }

    @Synchronized
    fun uuid(kind: Char, id: Long, serverId: String): String? = map(serverId)["$kind$id"]

    @Synchronized
    fun record(kind: Char, entries: Map<Long, String>, serverId: String) {
        if (entries.isEmpty()) return
        val m = map(serverId)
        var changed = false
        for ((id, uuid) in entries) {
            if (uuid.isEmpty()) continue
            val key = "$kind$id"
            if (m[key] != uuid) { m[key] = uuid; changed = true }
        }
        if (changed) Store.save(serializer, HashMap(m), fileName(serverId))
    }

    @Synchronized
    fun remove(serverId: String) {
        maps.remove(serverId)
        Store.file(fileName(serverId)).delete()
    }
}

class RestVodLibrary(
    val movieCategories: List<Category>,
    val movies: List<Movie>,
    val seriesCategories: List<Category>,
    val series: List<Series>,
)

/** The four XC-style VOD calls share one load. */
private object RestVodCache {
    private val mutex = Mutex()
    private var serverId: String? = null
    private var loadedAt = 0L
    private var library: RestVodLibrary? = null

    suspend fun get(id: String, load: suspend () -> RestVodLibrary): RestVodLibrary = mutex.withLock {
        val cached = library
        if (cached != null && serverId == id && System.currentTimeMillis() - loadedAt < 120_000) return@withLock cached
        val fresh = load()
        serverId = id
        loadedAt = System.currentTimeMillis()
        library = fresh
        fresh
    }
}

/** Answers the XC-style calls from Dispatcharr's REST API, in the same models. */
class RestCatalog(private val server: Server, private val rest: DispatcharrRest) {
    private val base: String get() = server.url ?: throw IllegalStateException("Invalid server address")

    private fun objects(e: JsonElement?): List<JsonObject> = (e as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()

    /** A plain list, or every page of a paginated one ({results, next}: a URL in DRF, a Boolean in /api/vod/all/). */
    private suspend fun list(path: String, query: Map<String, String?> = emptyMap(), timeoutSeconds: Long? = null, maxPages: Int = 1000): List<JsonObject> {
        val out = mutableListOf<JsonObject>()
        val q = LinkedHashMap(query)
        var page = query["page"]?.toIntOrNull() ?: 1
        while (true) {
            val root = rest.get(path, q, timeoutSeconds)
            if (root is JsonArray) return out + objects(root)
            val obj = root as? JsonObject ?: return out
            val results = objects(obj["results"] ?: return out)
            out += results
            val next = obj["next"] as? JsonPrimitive
            val more = when {
                next == null || next is JsonNull -> false
                next.isString -> next.content.isNotEmpty()
                else -> next.booleanOrNull ?: false
            }
            if (!more || results.isEmpty() || page >= maxPages) return out
            page += 1
            q["page"] = page.toString()
        }
    }

    private fun absolute(path: String?): String? {
        val s = path?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        return if (s.startsWith("http://") || s.startsWith("https://")) s else buildUrl(base, s)
    }

    // Live

    suspend fun liveCategories(): List<Category> = list("api/channels/groups/").mapNotNull { g ->
        val id = g.long("id") ?: return@mapNotNull null
        Category(id.toString(), g.str("name") ?: "Group $id")
    }

    /** Channels this user may watch; non-admins limited to channel profiles get those profiles' channels. */
    suspend fun channels(): List<Channel> {
        val me = runCatching { rest.me() }.getOrNull()
        val profiles = if (me != null && me.userLevel < 10) me.channelProfileIds else emptyList()
        val rows = if (profiles.isEmpty()) {
            channelRows(null)
        } else {
            val seen = HashSet<Long>()
            profiles.flatMap { channelRows(it) }.filter { r -> r.long("id")?.let { seen.add(it) } == true }
        }
        val uuids = HashMap<Long, String>()
        val out = rows.mapNotNull { r ->
            val id = r.long("id") ?: return@mapNotNull null
            val uuid = r.str("uuid") ?: return@mapNotNull null
            uuids[id] = uuid
            val number = r.dbl("channel_number")
            val group = r.long("channel_group_id") ?: r.child("channel_group")?.long("id") ?: r.long("channel_group")
            val logo = r.long("logo_id") ?: r.child("logo")?.long("id") ?: r.long("logo")
            Channel(
                id = id,
                number = number?.toInt(),
                name = r.str("name") ?: "Channel $id",
                icon = logo?.let { buildUrl(base, "api/channels/logos/$it/cache/") },
                // /output/epg names channels by number (or by id when there's none).
                epgId = number?.let { n -> if (n % 1.0 == 0.0) n.toLong().toString() else n.toString() } ?: id.toString(),
                categoryId = group?.toString() ?: "0",
                isAdult = r.bool("is_adult"),
            )
        }
        DispatcharrUuids.record(DispatcharrUuids.CHANNEL, uuids, server.id)
        return out
    }

    private suspend fun channelRows(profileId: Long?): List<JsonObject> {
        val q = mapOf("channel_profile_id" to profileId?.toString())
        return try {
            list("api/channels/channels/summary/", q, 120)
        } catch (e: HttpException) {
            if (e.code == 404 || e.code == 405) list("api/channels/channels/", q, 180) else throw e
        }
    }

    suspend fun programmes(channelId: Long, includePast: Boolean, limit: Int): List<Programme> {
        val from = System.currentTimeMillis() - if (includePast) 86_400_000L else 0L
        val rows = list("api/epg/programs/search/", mapOf("channel_id" to channelId.toString(), "end_after" to iso(from),
            "page_size" to limit.coerceIn(1, 500).toString()), maxPages = 1)
        return rows.mapNotNull { r ->
            val s = parseIso(r.str("start_time")) ?: return@mapNotNull null
            val e = parseIso(r.str("end_time")) ?: return@mapNotNull null
            Programme(s, e, r.str("title") ?: "", r.str("description"), r.str("sub_title"))
        }.sortedBy { it.start }
    }

    // VOD

    suspend fun vodLibrary(): RestVodLibrary = RestVodCache.get(server.id) { loadVodLibrary() }

    private class CategoryJob(val id: String, val filter: String, val isSeries: Boolean)

    private suspend fun loadVodLibrary(): RestVodLibrary {
        val categories = runCatching { list("api/vod/categories/") }.getOrDefault(emptyList())
        val items = vodItems()

        val movieCats = mutableListOf<Category>()
        val seriesCats = mutableListOf<Category>()
        val jobs = mutableListOf<CategoryJob>()
        for (c in categories) {
            val id = c.long("id") ?: continue
            val name = c.str("name") ?: continue
            val isSeries = (c.str("category_type") ?: "movie").lowercase() == "series"
            (if (isSeries) seriesCats else movieCats).add(Category(id.toString(), name))
            jobs += CategoryJob(id.toString(), "$name|${if (isSeries) "series" else "movie"}", isSeries)
        }
        // Category membership: /api/vod/all/ filtered per category ("name|type"), six at a time.
        val gate = Semaphore(6)
        val members = coroutineScope {
            jobs.map { job -> async { gate.withPermit { job to categoryMembers(job) } } }.awaitAll()
        }
        val movieCategory = HashMap<Long, String>()
        val seriesCategory = HashMap<Long, String>()
        for ((job, ids) in members) {
            val target = if (job.isSeries) seriesCategory else movieCategory
            for (id in ids) if (id !in target) target[id] = job.id
        }

        val movies = mutableListOf<Movie>()
        val series = mutableListOf<Series>()
        val movieUuids = HashMap<Long, String>()
        for (item in items) {
            val id = item.long("id") ?: continue
            val props = item.child("custom_properties")
            val art = poster(item, props)
            val tmdb = (item.int("tmdb_id") ?: props?.int("tmdb_id"))?.takeIf { it > 0 }
            val imdb = item.str("imdb_id") ?: props?.str("imdb_id")
            val plot = item.str("description") ?: props?.str("plot")
            if (item.str("content_type") == "series") {
                series += Series(
                    id = id, name = item.str("name") ?: "Untitled", cover = art,
                    backdrop = props?.strings("backdrop_path")?.firstOrNull { it.startsWith("http") },
                    plot = plot, genre = item.str("genre"), year = item.int("year"),
                    rating = item.dbl("rating")?.takeIf { it > 0 }, categoryId = seriesCategory[id] ?: "0",
                    lastModified = (parseIso(item.str("updated_at")) ?: parseIso(item.str("created_at")))?.div(1000),
                    tmdbId = tmdb, imdbId = imdb,
                )
            } else {
                item.str("uuid")?.let { movieUuids[id] = it }
                movies += Movie(
                    id = id, name = item.str("name") ?: "Untitled", icon = art,
                    rating = item.dbl("rating")?.takeIf { it > 0 }, added = parseIso(item.str("created_at"))?.div(1000),
                    tmdbId = tmdb, imdbId = imdb, plot = plot, genre = item.str("genre"), year = item.int("year"),
                    categoryId = movieCategory[id] ?: "0", ext = props?.str("container_extension") ?: "mp4",
                    isAdult = item.bool("is_adult"),
                )
            }
        }
        DispatcharrUuids.record(DispatcharrUuids.MOVIE, movieUuids, server.id)
        if (movies.any { it.categoryId == "0" }) movieCats += Category("0", "Uncategorized")
        if (series.any { it.categoryId == "0" }) seriesCats += Category("0", "Uncategorized")
        return RestVodLibrary(movieCats, movies, seriesCats, series)
    }

    private suspend fun categoryMembers(job: CategoryJob): List<Long> {
        val rows = runCatching { list("api/vod/all/", mapOf("category" to job.filter, "page_size" to "5000"), 120) }.getOrDefault(emptyList())
        val wanted = if (job.isSeries) "series" else "movie"
        return rows.filter { (it.str("content_type") ?: wanted) == wanted }.mapNotNull { it.long("id") }
    }

    /** Every movie and series: /api/vod/all/ (any page size) on current Dispatcharr, else the paginated per-type lists. */
    private suspend fun vodItems(): List<JsonObject> = try {
        list("api/vod/all/", mapOf("page_size" to "5000"), 180)
    } catch (e: HttpException) {
        if (e.code != 404 && e.code != 405) throw e
        listOf("api/vod/movies/" to "movie", "api/vod/series/" to "series").flatMap { (path, type) ->
            runCatching { list(path, mapOf("page_size" to "100"), 120) }.getOrDefault(emptyList())
                .map { JsonObject(it + ("content_type" to JsonPrimitive(type))) }
        }
    }

    /** The provider's own image when it's an absolute URL, else Dispatcharr's cached copy. */
    private fun poster(item: JsonObject, props: JsonObject?): String? {
        item.child("logo")?.let { logo ->
            logo.str("url")?.takeIf { it.startsWith("http") }?.let { return it }
            absolute(logo.str("cache_url"))?.let { return it }
        }
        for (key in listOf("cover_big", "movie_image", "cover", "poster", "logo_url")) {
            (props?.str(key) ?: item.str(key))?.takeIf { it.startsWith("http") }?.let { return it }
        }
        return null
    }

    /** Looks up UUIDs this device hasn't recorded yet (e.g. Continue Watching from another device). */
    suspend fun resolveUuids(movieId: Long?, episodeId: Long?) {
        if (movieId != null && DispatcharrUuids.uuid(DispatcharrUuids.MOVIE, movieId, server.id) == null) {
            runCatching { (rest.get("api/vod/movies/$movieId/") as? JsonObject)?.str("uuid") }.getOrNull()
                ?.let { DispatcharrUuids.record(DispatcharrUuids.MOVIE, mapOf(movieId to it), server.id) }
        }
        if (episodeId != null && DispatcharrUuids.uuid(DispatcharrUuids.EPISODE, episodeId, server.id) == null) {
            runCatching { (rest.get("api/vod/episodes/$episodeId/") as? JsonObject)?.str("uuid") }.getOrNull()
                ?.let { DispatcharrUuids.record(DispatcharrUuids.EPISODE, mapOf(episodeId to it), server.id) }
        }
    }

    suspend fun vodInfo(id: Long): VodInfo {
        val d = (
            try {
                rest.get("api/vod/movies/$id/provider-info/", timeoutSeconds = 60) as? JsonObject
            } catch (e: Exception) {
                rest.get("api/vod/movies/$id/") as? JsonObject
            }
            ) ?: throw IllegalStateException("No movie info")
        val props = d.child("custom_properties")
        if (d.long("id") == id) d.str("uuid")?.let { DispatcharrUuids.record(DispatcharrUuids.MOVIE, mapOf(id to it), server.id) }
        fun s(key: String) = d.str(key) ?: props?.str(key)
        return VodInfo(
            plot = s("plot") ?: s("description"),
            cover = s("cover_big") ?: s("movie_image") ?: d.child("logo")?.str("url"),
            backdrop = d.strings("backdrop_path").firstOrNull() ?: props?.strings("backdrop_path")?.firstOrNull(),
            tmdbId = (d.int("tmdb_id") ?: props?.int("tmdb_id"))?.takeIf { it > 0 },
            imdbId = s("imdb_id"),
            durationSecs = d.int("duration_secs") ?: props?.int("duration_secs"),
            cast = s("actors") ?: s("cast"),
            director = s("director"),
            trailer = s("youtube_trailer"),
        )
    }

    suspend fun seriesInfo(id: Long): SeriesInfo {
        val d = (
            try {
                rest.get("api/vod/series/$id/provider-info/", mapOf("include_episodes" to "true"), 120) as? JsonObject
            } catch (e: Exception) {
                runCatching { rest.get("api/vod/series/$id/") as? JsonObject }.getOrNull()
            }
            ) ?: JsonObject(emptyMap())
        val props = d.child("custom_properties")
        fun s(key: String) = d.str(key) ?: props?.str(key)

        // {"1": [...], "2": [...]} from provider-info, else the flat /episodes/ list.
        val raw = mutableListOf<Pair<Int?, JsonObject>>()
        val bySeason = d.child("episodes")
        if (bySeason != null && bySeason.isNotEmpty()) {
            bySeason.forEach { (k, v) -> objects(v).forEach { raw += k.toIntOrNull() to it } }
        } else {
            runCatching { list("api/vod/series/$id/episodes/", timeoutSeconds = 120) }.getOrNull()?.forEach { raw += null to it }
        }
        if (raw.isEmpty() && d.isEmpty()) throw IllegalStateException("No series info")

        val uuids = HashMap<Long, String>()
        val eps = mutableMapOf<Int, MutableList<XcEpisode>>()
        for ((seasonKey, o) in raw) {
            val eid = o.long("id") ?: continue
            o.str("uuid")?.let { uuids[eid] = it }
            val ep = o.child("custom_properties")
            val season = o.int("season_number") ?: seasonKey ?: 1
            eps.getOrPut(season) { mutableListOf() }.add(
                XcEpisode(
                    id = eid, season = season, episode = o.int("episode_number") ?: 0,
                    title = o.str("title") ?: o.str("name") ?: "Episode",
                    ext = o.str("container_extension") ?: ep?.str("container_extension") ?: "mp4",
                    plot = o.str("plot") ?: o.str("description"),
                    image = o.str("movie_image") ?: ep?.str("movie_image"),
                    durationSecs = o.int("duration_secs"),
                    airDate = o.str("air_date"),
                ),
            )
        }
        DispatcharrUuids.record(DispatcharrUuids.EPISODE, uuids, server.id)
        return SeriesInfo(
            episodes = eps.mapValues { (_, list) -> list.sortedBy { it.episode } },
            plot = s("description") ?: s("plot"),
            backdrop = d.strings("backdrop_path").firstOrNull() ?: props?.strings("backdrop_path")?.firstOrNull(),
            tmdbId = (d.int("tmdb_id") ?: props?.int("tmdb_id"))?.takeIf { it > 0 },
            imdbId = s("imdb_id"),
            trailer = s("youtube_trailer"),
        )
    }

    companion object {
        fun iso(ms: Long): String = Instant.ofEpochMilli(ms).truncatedTo(ChronoUnit.SECONDS).toString()

        /** ISO 8601 with an offset ("…Z", "…+02:00"); a bare local time is taken as UTC. */
        fun parseIso(s: String?): Long? {
            if (s.isNullOrBlank()) return null
            return runCatching { OffsetDateTime.parse(s).toInstant().toEpochMilli() }.getOrNull()
                ?: runCatching { LocalDateTime.parse(s.take(19)).toInstant(ZoneOffset.UTC).toEpochMilli() }.getOrNull()
        }
    }
}
