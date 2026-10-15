package com.mohamedt.streamforge.dispatcharr

import com.mohamedt.streamforge.core.Http
import com.mohamedt.streamforge.core.HttpException
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.MediaType
import com.mohamedt.streamforge.core.Origin
import com.mohamedt.streamforge.core.Store
import com.mohamedt.streamforge.core.TitleCleaner
import com.mohamedt.streamforge.core.arr
import com.mohamedt.streamforge.core.base64Decoded
import com.mohamedt.streamforge.core.bool
import com.mohamedt.streamforge.core.buildUrl
import com.mohamedt.streamforge.core.child
import com.mohamedt.streamforge.core.dbl
import com.mohamedt.streamforge.core.enc
import com.mohamedt.streamforge.core.int
import com.mohamedt.streamforge.core.list
import com.mohamedt.streamforge.core.long
import com.mohamedt.streamforge.core.normalizedBase
import com.mohamedt.streamforge.core.obj
import com.mohamedt.streamforge.core.objects
import com.mohamedt.streamforge.core.str
import com.mohamedt.streamforge.core.strings
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

@Serializable
enum class AuthMode { ACCOUNT, API_KEY, XC }

/** A Dispatcharr server. Secrets live in private prefs, keyed by the server id. */
@Serializable
data class Server(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val baseUrl: String,
    val username: String,
    val authMode: AuthMode = AuthMode.ACCOUNT,
) {
    val url: String? get() = normalizedBase(baseUrl)

    var xcPassword: String
        get() = Store.secret("dispatcharr.xc.$id")
        set(v) = Store.setSecret("dispatcharr.xc.$id", v)
    var webPassword: String
        get() = Store.secret("dispatcharr.web.$id")
        set(v) = Store.setSecret("dispatcharr.web.$id", v)
    var apiKey: String
        get() = Store.secret("dispatcharr.apikey.$id")
        set(v) = Store.setSecret("dispatcharr.apikey.$id", v.trim())

    val hasRest: Boolean
        get() = when (authMode) {
            AuthMode.API_KEY -> apiKey.isNotEmpty()
            else -> webPassword.isNotEmpty()
        }

    /**
     * Account / API-key servers whose Dispatcharr user has no XC password: channels, guide and VOD come
     * from the REST API and playback goes through Dispatcharr's proxy (see RestCatalog). No catch-up.
     */
    val usesRestStreaming: Boolean
        get() = authMode != AuthMode.XC && xcPassword.isEmpty()
}

@Serializable
data class Category(val id: String, val name: String)

@Serializable
data class Channel(
    val id: Long,
    val number: Int? = null,
    val name: String,
    val icon: String? = null,
    val epgId: String? = null,
    val categoryId: String,
    val isAdult: Boolean = false,
    val hasArchive: Boolean = false,
    val archiveDays: Int = 0,
)

@Serializable
data class Movie(
    val id: Long,
    val name: String,
    val icon: String? = null,
    val rating: Double? = null,
    val added: Long? = null,
    val tmdbId: Int? = null,
    val imdbId: String? = null,
    val plot: String? = null,
    val genre: String? = null,
    val year: Int? = null,
    val categoryId: String,
    val ext: String = "mp4",
    val isAdult: Boolean = false,
)

@Serializable
data class Series(
    val id: Long,
    val name: String,
    val cover: String? = null,
    val backdrop: String? = null,
    val plot: String? = null,
    val genre: String? = null,
    val year: Int? = null,
    val rating: Double? = null,
    val categoryId: String,
    val lastModified: Long? = null,
    val tmdbId: Int? = null,
    val imdbId: String? = null,
)

data class XcEpisode(
    val id: Long,
    val season: Int,
    val episode: Int,
    val title: String,
    val ext: String,
    val plot: String?,
    val image: String?,
    val durationSecs: Int?,
    val airDate: String?,
)

data class SeriesInfo(
    val episodes: Map<Int, List<XcEpisode>>,
    val plot: String?,
    val backdrop: String?,
    val tmdbId: Int?,
    val imdbId: String?,
    val trailer: String?,
)

data class VodInfo(
    val plot: String?,
    val cover: String?,
    val backdrop: String?,
    val tmdbId: Int?,
    val imdbId: String?,
    val durationSecs: Int?,
    val cast: String?,
    val director: String?,
    val trailer: String?,
)

@Serializable
data class Programme(
    val start: Long, // epoch ms
    val end: Long,
    val title: String,
    val desc: String? = null,
    val subtitle: String? = null,
    val categories: List<String> = emptyList(),
    val hasArchive: Boolean = false,
) {
    val isLive: Boolean get() = System.currentTimeMillis().let { it in start until end }
    val progress: Float
        get() {
            val total = (end - start).toFloat()
            if (total <= 0) return 0f
            return ((System.currentTimeMillis() - start) / total).coerceIn(0f, 1f)
        }
}

/**
 * Dispatcharr's Xtream Codes API: channels, EPG, movies, series, catch-up. Servers in REST streaming
 * mode (no XC password) get the same answers from the REST API instead (RestCatalog).
 */
class XtreamClient(val server: Server, private val rest: DispatcharrRest? = null) {
    private val base: String get() = server.url ?: throw IllegalStateException("Invalid server address")

    private val catalog: RestCatalog?
        get() = if (server.usesRestStreaming) RestCatalog(server, rest ?: DispatcharrRest(server)) else null

    private fun api(action: String?, params: Map<String, String?> = emptyMap()): String {
        val q = linkedMapOf<String, String?>("username" to server.username, "password" to server.xcPassword)
        if (action != null) q["action"] = action
        q.putAll(params)
        return buildUrl(base, "player_api.php", q)
    }

    suspend fun authenticate(): JsonObject {
        val root = Http.json(api(null), timeoutSeconds = 15).obj() ?: throw IllegalStateException("Unexpected response")
        val info = root.child("user_info")
        if (info == null || !info.bool("auth")) throw IllegalStateException("Wrong username or XC password")
        return root
    }

    suspend fun liveCategories(): List<Category> = catalog?.liveCategories() ?: categories("get_live_categories")
    suspend fun vodCategories(): List<Category> = catalog?.vodLibrary()?.movieCategories ?: categories("get_vod_categories")
    suspend fun seriesCategories(): List<Category> = catalog?.vodLibrary()?.seriesCategories ?: categories("get_series_categories")

    private suspend fun categories(action: String): List<Category> =
        Http.json(api(action)).arr()?.mapNotNull { it.obj() }?.map {
            Category(it.str("category_id") ?: "0", it.str("category_name") ?: "Uncategorized")
        } ?: emptyList()

    suspend fun channels(): List<Channel> = catalog?.channels() ?: xcChannels()

    private suspend fun xcChannels(): List<Channel> =
        Http.json(api("get_live_streams"), timeoutSeconds = 120).arr()?.mapNotNull { e ->
            val o = e.obj() ?: return@mapNotNull null
            val id = o.long("stream_id") ?: return@mapNotNull null
            Channel(
                id = id,
                number = o.int("num"),
                name = o.str("name") ?: "Channel $id",
                icon = o.str("stream_icon"),
                epgId = o.str("epg_channel_id"),
                categoryId = o.str("category_id") ?: "0",
                isAdult = o.bool("is_adult"),
                hasArchive = o.bool("tv_archive"),
                archiveDays = o.int("tv_archive_duration") ?: 0,
            )
        } ?: emptyList()

    suspend fun movies(): List<Movie> = catalog?.vodLibrary()?.movies ?: xcMovies()

    private suspend fun xcMovies(): List<Movie> =
        Http.json(api("get_vod_streams"), timeoutSeconds = 180).arr()?.mapNotNull { e ->
            val o = e.obj() ?: return@mapNotNull null
            val id = o.long("stream_id") ?: return@mapNotNull null
            Movie(
                id = id,
                name = o.str("name") ?: "Untitled",
                icon = o.str("stream_icon"),
                rating = o.dbl("rating")?.takeIf { it > 0 },
                added = o.long("added"),
                tmdbId = o.int("tmdb_id")?.takeIf { it > 0 },
                imdbId = o.str("imdb_id"),
                plot = o.str("plot"),
                genre = o.str("genre"),
                year = o.int("year") ?: (o.str("release_date") ?: o.str("releasedate"))?.take(4)?.toIntOrNull(),
                categoryId = o.str("category_id") ?: "0",
                ext = o.str("container_extension") ?: "mp4",
                isAdult = o.bool("is_adult"),
            )
        } ?: emptyList()

    suspend fun series(): List<Series> = catalog?.vodLibrary()?.series ?: xcSeries()

    private suspend fun xcSeries(): List<Series> =
        Http.json(api("get_series"), timeoutSeconds = 180).arr()?.mapNotNull { e ->
            val o = e.obj() ?: return@mapNotNull null
            val id = o.long("series_id") ?: return@mapNotNull null
            Series(
                id = id,
                name = o.str("name") ?: "Untitled",
                cover = o.str("cover"),
                backdrop = o.strings("backdrop_path").firstOrNull(),
                plot = o.str("plot"),
                genre = o.str("genre"),
                year = o.int("year") ?: (o.str("release_date") ?: o.str("releaseDate"))?.take(4)?.toIntOrNull(),
                rating = o.dbl("rating")?.takeIf { it > 0 },
                categoryId = o.str("category_id") ?: "0",
                lastModified = o.long("last_modified"),
                tmdbId = o.int("tmdb_id")?.takeIf { it > 0 },
                imdbId = o.str("imdb_id"),
            )
        } ?: emptyList()

    suspend fun seriesInfo(id: Long): SeriesInfo {
        catalog?.let { return it.seriesInfo(id) }
        val root = Http.json(api("get_series_info", mapOf("series_id" to id.toString()))).obj()
            ?: throw IllegalStateException("No series info")
        val eps = mutableMapOf<Int, MutableList<XcEpisode>>()
        fun add(o: JsonObject, seasonKey: Int?) {
            val eid = o.long("id") ?: return
            val info = o.child("info")
            val season = o.int("season") ?: seasonKey ?: 1
            eps.getOrPut(season) { mutableListOf() }.add(
                XcEpisode(
                    id = eid, season = season, episode = o.int("episode_num") ?: 0,
                    title = o.str("title") ?: "Episode", ext = o.str("container_extension") ?: "mp4",
                    plot = info?.str("overview") ?: info?.str("plot"), image = info?.str("movie_image"),
                    durationSecs = info?.int("duration_secs"),
                    airDate = info?.str("air_date") ?: info?.str("release_date") ?: info?.str("releasedate"),
                ),
            )
        }
        when (val e = root["episodes"]) {
            is JsonObject -> e.forEach { (k, v) -> v.arr()?.forEach { it.obj()?.let { o -> add(o, k.toIntOrNull()) } } }
            is kotlinx.serialization.json.JsonArray -> e.forEach { item ->
                item.obj()?.let { add(it, null) } ?: item.arr()?.forEach { it.obj()?.let { o -> add(o, null) } }
            }
            else -> {}
        }
        val info = root.child("info")
        return SeriesInfo(
            episodes = eps.mapValues { (_, list) -> list.sortedBy { it.episode } },
            plot = info?.str("plot"),
            backdrop = info?.strings("backdrop_path")?.firstOrNull(),
            tmdbId = info?.int("tmdb")?.takeIf { it > 0 },
            imdbId = info?.str("imdb"),
            trailer = info?.str("youtube_trailer"),
        )
    }

    suspend fun vodInfo(id: Long): VodInfo {
        catalog?.let { return it.vodInfo(id) }
        val root = Http.json(api("get_vod_info", mapOf("vod_id" to id.toString()))).obj()
        val info = root?.child("info")
        return VodInfo(
            plot = info?.str("plot") ?: info?.str("description"),
            cover = info?.str("cover_big") ?: info?.str("movie_image"),
            backdrop = info?.strings("backdrop_path")?.firstOrNull(),
            tmdbId = info?.int("tmdb_id")?.takeIf { it > 0 },
            imdbId = info?.str("imdb_id"),
            durationSecs = info?.int("duration_secs"),
            cast = info?.str("cast") ?: info?.str("actors"),
            director = info?.str("director"),
            trailer = info?.str("youtube_trailer"),
        )
    }

    /** Per-channel guide fallback when the full XMLTV guide isn't loaded. */
    suspend fun channelGuide(channelId: Long): List<Programme> {
        catalog?.let { return it.programmes(channelId, includePast = true, limit = 200) }
        val root = Http.json(api("get_simple_data_table", mapOf("stream_id" to channelId.toString())), timeoutSeconds = 60).obj()
        return root?.objects("epg_listings")?.mapNotNull { o ->
            val s = o.long("start_timestamp") ?: return@mapNotNull null
            val e = o.long("stop_timestamp") ?: return@mapNotNull null
            Programme(s * 1000, e * 1000, (o.str("title") ?: "").base64Decoded(), (o.str("description") ?: "").base64Decoded().ifEmpty { null },
                hasArchive = o.bool("has_archive"))
        }?.sortedBy { it.start } ?: emptyList()
    }

    /**
     * The XMLTV guide. REST streaming servers use the public /output/epg export (no credentials; only
     * Dispatcharr's "M3U / EPG" network setting applies), whose channel ids are channel numbers too.
     */
    fun xmltvUrl(days: Int, prevDays: Int): String {
        val range = mapOf("days" to days.coerceAtLeast(1).toString(), "prev_days" to prevDays.takeIf { it > 0 }?.toString())
        if (server.usesRestStreaming) return buildUrl(base, "output/epg", range)
        return buildUrl(base, "xmltv.php", mapOf("username" to server.username, "password" to server.xcPassword) + range)
    }

    // Playback URLs. REST streaming servers play through Dispatcharr's proxy, addressed by UUID; those
    // endpoints are open (AllowAny, "Streams" network setting), so no auth header (an expired JWT would
    // get a reconnect rejected). Null when the UUID isn't known yet (see preparePlayback).
    private val u get() = enc(server.username)
    private val p get() = enc(server.xcPassword)

    private fun proxyUrl(kind: Char, id: Long, path: String): String? =
        DispatcharrUuids.uuid(kind, id, server.id)?.let { "${base}/$path/$it" }

    fun liveUrl(channelId: Long): String? =
        if (server.usesRestStreaming) proxyUrl(DispatcharrUuids.CHANNEL, channelId, "proxy/ts/stream") else "${base}/live/$u/$p/$channelId"

    fun movieUrl(id: Long, ext: String): String? =
        if (server.usesRestStreaming) proxyUrl(DispatcharrUuids.MOVIE, id, "proxy/vod/movie") else "${base}/movie/$u/$p/$id.$ext"

    fun episodeUrl(id: Long, ext: String): String? =
        if (server.usesRestStreaming) proxyUrl(DispatcharrUuids.EPISODE, id, "proxy/vod/episode") else "${base}/series/$u/$p/$id.$ext"

    /** REST streaming mode: fetches UUIDs this device hasn't seen yet. A no-op for XC servers. */
    suspend fun preparePlayback(movieId: Long? = null, episodeId: Long? = null) {
        catalog?.resolveUuids(movieId, episodeId)
    }

    /** XC timeshift; not available in REST streaming mode. */
    fun catchupUrl(channelId: Long, start: Long, end: Long): String? {
        if (server.usesRestStreaming) return null
        val f = SimpleDateFormat("yyyy-MM-dd:HH-mm", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        val minutes = ((end - start) / 60000).coerceAtLeast(1)
        return "${base}/timeshift/$u/$p/$minutes/${f.format(Date(start))}/$channelId.ts"
    }
}

/** REST API: account login (JWT) or API key; /me (XC password), DVR, and REST streaming mode. */
class DispatcharrRest(private val server: Server) {
    private var access: String? = null
    private val base: String get() = server.url ?: throw IllegalStateException("Invalid server address")

    private suspend fun headers(): Map<String, String> {
        if (server.authMode == AuthMode.API_KEY) return mapOf("X-API-Key" to server.apiKey)
        if (access == null) login()
        return mapOf("Authorization" to "Bearer $access")
    }

    /** Runs [block] with auth headers; an expired JWT (401/403) triggers one fresh login and a retry. */
    private suspend fun <T> authed(block: suspend (Map<String, String>) -> T): T =
        try {
            block(headers())
        } catch (e: HttpException) {
            if (server.authMode == AuthMode.API_KEY || (e.code != 401 && e.code != 403)) throw e
            access = null
            login()
            block(headers())
        }

    suspend fun login() {
        if (server.authMode == AuthMode.API_KEY) return
        val body = """{"username":${jsonString(server.username)},"password":${jsonString(server.webPassword)}}"""
        val res = Http.json(buildUrl(base, "api/accounts/token/"), method = "POST", body = body).obj()
        access = res?.str("access") ?: throw IllegalStateException("Login failed")
    }

    data class Me(
        val id: Long?,
        val username: String,
        val xcPassword: String?,
        val userLevel: Int,
        val channelProfileIds: List<Long> = emptyList(),
        /** Whether /me returned custom_properties (so a missing xc_password really means none). */
        val hasCustomProperties: Boolean = false,
    )

    suspend fun me(): Me {
        val o = authed { h -> Http.json(buildUrl(base, "api/accounts/users/me/"), h) }.obj() ?: throw IllegalStateException("No user")
        val props = o.child("custom_properties")
        val profiles = o.list("channel_profiles").mapNotNull { e ->
            (e as? kotlinx.serialization.json.JsonPrimitive)?.content?.toLongOrNull() ?: e.obj()?.long("id")
        }
        return Me(o.long("id"), o.str("username") ?: server.username, props?.str("xc_password"), o.int("user_level") ?: 0,
            profiles, props != null)
    }

    /** Authenticated GET on any REST path (REST streaming mode). */
    suspend fun get(path: String, query: Map<String, String?> = emptyMap(), timeoutSeconds: Long? = null): JsonElement =
        authed { h -> Http.json(buildUrl(base, path, query), h, timeoutSeconds = timeoutSeconds) }

    /**
     * Sets a user's XC password. Admin only: Dispatcharr's PATCH /api/accounts/users/{id}/ is IsAdmin and
     * /users/me/ strips xc_password. Dispatcharr merges custom_properties, so other properties stay.
     */
    suspend fun setXcPassword(userId: Long, password: String) {
        val body = """{"custom_properties":{"xc_password":${jsonString(password)}}}"""
        authed { h -> Http.json(buildUrl(base, "api/accounts/users/$userId/"), h, method = "PATCH", body = body) }
    }

    data class Recording(val id: Long, val channelId: Long?, val start: Long, val end: Long, val title: String)

    suspend fun recordings(): List<Recording> {
        val root = authed { h -> Http.json(buildUrl(base, "api/channels/recordings/"), h) }
        val list = root.arr()?.mapNotNull { it.obj() } ?: root.obj()?.objects("results") ?: emptyList()
        val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        fun parse(s: String?): Long = s?.let { runCatching { iso.parse(it.take(19))?.time }.getOrNull() } ?: 0L
        return list.map { o ->
            val program = o.child("custom_properties")?.child("program")
            Recording(o.long("id") ?: 0, o.long("channel"), parse(o.str("start_time")), parse(o.str("end_time")),
                program?.str("title") ?: "Recording")
        }.sortedByDescending { it.start }
    }

    suspend fun scheduleRecording(channelId: Long, p: Programme) {
        val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        val body = """{"channel":$channelId,"start_time":"${iso.format(Date(p.start))}","end_time":"${iso.format(Date(p.end))}",""" +
            """"custom_properties":{"program":{"title":${jsonString(p.title)},"description":${jsonString(p.desc ?: "")}}}}"""
        authed { h -> Http.text(buildUrl(base, "api/channels/recordings/"), h, method = "POST", body = body) }
    }

    /** mpv sends these itself and can't refresh them, so hand it a freshly issued token. */
    suspend fun recordingHeaders(): Map<String, String> {
        if (server.authMode != AuthMode.API_KEY) { access = null; login() }
        return headers()
    }
    fun recordingUrl(id: Long) = buildUrl(base, "api/channels/recordings/$id/file/")

    private fun jsonString(s: String) = kotlinx.serialization.json.JsonPrimitive(s).toString()
}

// Mapping to MediaItem

fun Movie.toItem(serverId: String): MediaItem = toItem(serverId, TitleCleaner.clean(name))

/** [cleaned] is TitleCleaner.clean(name), passed in when the caller already has it (regex work is the costly part). */
fun Movie.toItem(serverId: String, cleaned: Pair<String, Int?>): MediaItem {
    val (title, y) = cleaned
    return MediaItem(
        id = "xc:${serverId.take(8)}:movie:$id", type = MediaType.MOVIE, title = title, year = year ?: y,
        poster = icon, overview = plot, rating = rating,
        genres = genre?.split(",")?.map { it.trim() }?.filter { it.isNotEmpty() } ?: emptyList(),
        imdbId = imdbId, tmdbId = tmdbId, origin = Origin("xc-movie", id, ext), added = added, categoryId = categoryId,
    )
}

fun Series.toItem(serverId: String): MediaItem = toItem(serverId, TitleCleaner.clean(name))

fun Series.toItem(serverId: String, cleaned: Pair<String, Int?>): MediaItem {
    val (title, y) = cleaned
    return MediaItem(
        id = "xc:${serverId.take(8)}:series:$id", type = MediaType.SERIES, title = title, year = year ?: y,
        poster = cover, backdrop = backdrop, overview = plot, rating = rating,
        genres = genre?.split(",")?.map { it.trim() }?.filter { it.isNotEmpty() } ?: emptyList(),
        imdbId = imdbId, tmdbId = tmdbId, origin = Origin("xc-series", id), added = lastModified, categoryId = categoryId,
    )
}

fun Channel.toItem(serverId: String) = MediaItem(
    id = "xc:${serverId.take(8)}:live:$id", type = MediaType.CHANNEL, title = name, poster = icon,
    origin = Origin("xc-channel", id), categoryId = categoryId,
)
