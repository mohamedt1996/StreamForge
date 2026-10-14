package com.mohamedt.streamforge.stremio

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.mohamedt.streamforge.core.Episode
import com.mohamedt.streamforge.core.Http
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.MediaType
import com.mohamedt.streamforge.core.Origin
import com.mohamedt.streamforge.core.Person
import com.mohamedt.streamforge.core.normalizeName
import com.mohamedt.streamforge.metadata.Tmdb
import com.mohamedt.streamforge.core.Store
import com.mohamedt.streamforge.core.arr
import com.mohamedt.streamforge.core.bool
import com.mohamedt.streamforge.core.child
import com.mohamedt.streamforge.core.dbl
import com.mohamedt.streamforge.core.int
import com.mohamedt.streamforge.core.list
import com.mohamedt.streamforge.core.long
import com.mohamedt.streamforge.core.obj
import com.mohamedt.streamforge.core.objects
import com.mohamedt.streamforge.core.parseJson
import com.mohamedt.streamforge.core.str
import com.mohamedt.streamforge.core.strings
import com.mohamedt.streamforge.sync.RemoteSync
import java.net.URLEncoder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

@Serializable
data class CatalogDef(
    val type: String,
    val id: String,
    val name: String? = null,
    val supportsSearch: Boolean = false,
    val requiresExtra: Boolean = false,
    val supportsSkip: Boolean = false,
    val genres: List<String> = emptyList(),
)

@Serializable
data class ResourceDef(val name: String, val types: List<String>? = null, val idPrefixes: List<String>? = null)

@Serializable
data class Addon(
    val id: String,
    val baseUrl: String, // without "/manifest.json"
    val name: String,
    val version: String? = null,
    val description: String? = null,
    val logo: String? = null,
    val types: List<String> = emptyList(),
    val idPrefixes: List<String>? = null,
    val resources: List<ResourceDef> = emptyList(),
    val catalogs: List<CatalogDef> = emptyList(),
    val enabled: Boolean = true,
) {
    fun supports(resource: String, type: String, id: String): Boolean {
        for (r in resources.filter { it.name == resource }) {
            val types = r.types ?: this.types
            if (types.isNotEmpty() && type !in types) continue
            val prefixes = r.idPrefixes ?: idPrefixes
            if (prefixes.isNullOrEmpty() || prefixes.any { id.startsWith(it) }) return true
        }
        return false
    }

    val hasStreams get() = resources.any { it.name == "stream" }
    val hasSubtitles get() = resources.any { it.name == "subtitles" }
}

data class Meta(
    val id: String,
    val type: String,
    val name: String,
    val poster: String?,
    val background: String?,
    val logo: String?,
    val description: String?,
    val releaseInfo: String?,
    val imdbRating: Double?,
    val genres: List<String>,
    val runtime: String?,
    val videos: List<Episode>,
    val imdbId: String?,
    val cast: List<String>,
    val trailer: String?,
    /** Cast with faces: Cinemeta `app_extras.cast` (photo URLs) merged with `credits_cast` (TMDB profile paths/ids). */
    val people: List<Person> = emptyList(),
    /** Every trailer id the addon lists, trailers before other clips. */
    val trailers: List<String> = listOfNotNull(trailer),
) {
    val year: Int? get() = releaseInfo?.take(4)?.toIntOrNull()

    fun toItem(addonId: String) = MediaItem(
        id = if (id.startsWith("tt")) id else "stremio:$addonId:$id",
        type = MediaType.fromStremio(type), title = name, year = year, poster = poster, backdrop = background,
        logo = logo, overview = description, rating = imdbRating, genres = genres, imdbId = imdbId,
        origin = Origin("stremio", addonId = addonId, metaId = id),
        runtimeMinutes = runtime?.filter { it.isDigit() }?.toIntOrNull(),
    )
}

data class Stream(
    val url: String?,
    val infoHash: String?,
    val fileIdx: Int?,
    val externalUrl: String?,
    val name: String?,
    val title: String?,
    val description: String?,
    val trackers: List<String>,
    val filename: String?,
    val videoSize: Long?,
    val bingeGroup: String?,
    val headers: Map<String, String>,
    val subtitles: List<Subtitle>,
)

data class Subtitle(val id: String, val url: String, val lang: String)

/** Installs and queries Stremio addons (catalog / meta / stream / subtitles). */
object Addons {
    const val CINEMETA = "https://v3-cinemeta.strem.io/manifest.json"
    const val OPENSUBTITLES = "https://opensubtitles-v3.strem.io/manifest.json"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    var addons by mutableStateOf(Store.load(ListSerializer(Addon.serializer()), "addons.json") ?: emptyList()); private set
    val enabled: List<Addon> get() = addons.filter { it.enabled }

    fun init() {
        if (!Store.prefs.getBoolean("addons.defaults", false)) {
            scope.launch {
                for (u in listOf(CINEMETA, OPENSUBTITLES)) runCatching { install(u) }
                Store.prefs.edit().putBoolean("addons.defaults", true).apply()
            }
        }
    }

    private fun save() {
        Store.save(ListSerializer(Addon.serializer()), addons, "addons.json")
        RemoteSync.changed()
    }

    /** Manifest URL, the addon's identity for sync. */
    fun manifestUrl(addon: Addon): String = addon.baseUrl + "/manifest.json"

    /** Replaces the whole list (sync: reordering after pulled changes). */
    internal fun replaceAllFromSync(list: List<Addon>) { addons = list; save() }

    fun normalize(raw: String): String {
        var s = raw.trim()
        if (s.lowercase().startsWith("stremio://")) s = "https://" + s.substring("stremio://".length)
        if (!s.contains("://")) s = "https://$s"
        if (!s.endsWith("manifest.json")) s = s.trimEnd('/') + "/manifest.json"
        return s
    }

    suspend fun install(raw: String): Addon {
        val url = normalize(raw)
        val o = Http.json(url).obj() ?: throw IllegalStateException("Not an addon manifest")
        if (o.child("behaviorHints")?.bool("configurationRequired") == true) {
            throw IllegalStateException("This addon must be configured on its website first. Paste the configured link.")
        }
        val resources = o.list("resources").mapNotNull { r ->
            when (r) {
                is JsonPrimitive -> ResourceDef(r.content)
                is JsonObject -> r.str("name")?.let { ResourceDef(it, r.strings("types").ifEmpty { null }, r.strings("idPrefixes").ifEmpty { null }) }
                else -> null
            }
        }
        val catalogs = o.objects("catalogs").mapNotNull { c ->
            val extras = c.objects("extra")
            CatalogDef(
                type = c.str("type") ?: return@mapNotNull null,
                id = c.str("id") ?: return@mapNotNull null,
                name = c.str("name"),
                supportsSearch = extras.any { it.str("name") == "search" } || "search" in c.strings("extraSupported"),
                requiresExtra = extras.any { it.bool("isRequired") } || c.strings("extraRequired").isNotEmpty(),
                supportsSkip = extras.any { it.str("name") == "skip" } || "skip" in c.strings("extraSupported"),
                genres = extras.firstOrNull { it.str("name") == "genre" }?.strings("options") ?: emptyList(),
            )
        }
        val addon = Addon(
            id = o.str("id") ?: url, baseUrl = url.removeSuffix("/manifest.json"), name = o.str("name") ?: "Addon",
            version = o.str("version"), description = o.str("description"), logo = o.str("logo"),
            types = o.strings("types"), idPrefixes = o.strings("idPrefixes").ifEmpty { null },
            resources = resources, catalogs = catalogs,
        )
        val existing = addons.firstOrNull { it.id == addon.id }
        addons = if (existing != null) addons.map { if (it.id == addon.id) addon.copy(enabled = existing.enabled) else it } else addons + addon
        save()
        return addon
    }

    fun remove(addon: Addon) { addons = addons.filter { it.id != addon.id }; save() }
    fun setEnabled(addon: Addon, on: Boolean) { addons = addons.map { if (it.id == addon.id) it.copy(enabled = on) else it }; save() }
    fun move(addon: Addon, up: Boolean) {
        val list = addons.toMutableList()
        val i = list.indexOfFirst { it.id == addon.id }
        val j = if (up) i - 1 else i + 1
        if (i < 0 || j !in list.indices) return
        list[i] = list[j].also { list[j] = list[i] }
        addons = list
        save()
    }

    private fun encId(id: String) = URLEncoder.encode(id, "UTF-8").replace("+", "%20").replace("%3A", ":")

    private fun resourceUrl(a: Addon, resource: String, type: String, id: String, extra: Map<String, String> = emptyMap()): String {
        var path = "${a.baseUrl}/$resource/$type/${encId(id)}"
        if (extra.isNotEmpty()) {
            path += "/" + extra.entries.sortedBy { it.key }.joinToString("&") { (k, v) -> "$k=${URLEncoder.encode(v, "UTF-8").replace("+", "%20")}" }
        }
        return "$path.json"
    }

    data class CatalogEntry(val addon: Addon, val catalog: CatalogDef) {
        val title: String
            get() {
                val t = when (catalog.type) { "movie" -> "Movies"; "series" -> "Series"; else -> catalog.type.replaceFirstChar { it.uppercase() } }
                return "${catalog.name ?: catalog.id} $t"
            }
    }

    val catalogs: List<CatalogEntry> get() = enabled.flatMap { a -> a.catalogs.filter { !it.requiresExtra }.map { CatalogEntry(a, it) } }
    private val searchable: List<CatalogEntry> get() = enabled.flatMap { a -> a.catalogs.filter { it.supportsSearch }.map { CatalogEntry(a, it) } }

    suspend fun catalog(entry: CatalogEntry, extra: Map<String, String> = emptyMap()): List<Meta> {
        val o = Http.json(resourceUrl(entry.addon, "catalog", entry.catalog.type, entry.catalog.id, extra)).obj()
        return o?.objects("metas")?.mapNotNull { parseMeta(it) } ?: emptyList()
    }

    suspend fun search(query: String): List<Pair<CatalogEntry, List<Meta>>> = coroutineScope {
        searchable.map { e -> async { e to (runCatching { withTimeoutOrNull(15_000) { catalog(e, mapOf("search" to query)) } }.getOrNull() ?: emptyList()) } }
            .awaitAll().filter { it.second.isNotEmpty() }
    }

    suspend fun meta(type: String, id: String, preferred: String? = null): Pair<Addon, Meta>? {
        val candidates = enabled.filter { it.supports("meta", type, id) }.sortedBy { if (it.id == preferred) 0 else 1 }
        for (a in candidates) {
            val m = runCatching { Http.json(resourceUrl(a, "meta", type, id)).obj()?.child("meta")?.let { parseMeta(it) } }.getOrNull()
            if (m != null) return a to m
        }
        return null
    }

    /** Streams from every enabled addon in parallel, delivered as each addon answers. */
    suspend fun streams(type: String, id: String, onBatch: suspend (Addon, List<Stream>) -> Unit) = coroutineScope {
        enabled.filter { it.supports("stream", type, id) }.map { a ->
            async {
                val list = runCatching {
                    withTimeoutOrNull(25_000) { Http.json(resourceUrl(a, "stream", type, id)).obj()?.objects("streams")?.map { parseStream(it) } }
                }.getOrNull() ?: emptyList()
                onBatch(a, list)
            }
        }.awaitAll()
    }

    suspend fun subtitles(type: String, id: String, size: Long? = null, filename: String? = null): List<Subtitle> = coroutineScope {
        val extra = buildMap { size?.let { put("videoSize", it.toString()) }; filename?.let { put("filename", it) } }
        enabled.filter { it.supports("subtitles", type, id) }.map { a ->
            async {
                runCatching { Http.json(resourceUrl(a, "subtitles", type, id, extra)).obj()?.objects("subtitles")?.mapNotNull { parseSub(it) } }
                    .getOrNull() ?: emptyList()
            }
        }.awaitAll().flatten().distinctBy { it.url }
    }

    private fun parseSub(o: JsonObject): Subtitle? {
        val url = o.str("url") ?: return null
        return Subtitle(o.str("id") ?: url, url, o.str("lang") ?: "und")
    }

    private fun parseMeta(o: JsonObject): Meta? {
        val id = o.str("id") ?: return null
        val videos = o.objects("videos").mapNotNull { v ->
            val vid = v.str("id") ?: return@mapNotNull null
            Episode(
                id = vid, season = v.int("season") ?: 0, episode = v.int("episode") ?: v.int("number") ?: 0,
                title = v.str("title") ?: v.str("name") ?: vid, overview = v.str("overview") ?: v.str("description"),
                still = v.str("thumbnail"), airDate = v.str("released")?.take(10), stremioVideoId = vid,
            )
        }
        val trailerObjs = o.objects("trailers")
        val trailers = (trailerObjs.filter { it.str("type") == "Trailer" } + trailerObjs.filter { it.str("type") != "Trailer" })
            .mapNotNull { it.str("source") }.distinct()
        val trailer = trailers.firstOrNull()
        return Meta(
            id = id, type = o.str("type") ?: "movie", name = o.str("name") ?: id, poster = o.str("poster"),
            background = o.str("background"), logo = o.str("logo"), description = o.str("description"),
            releaseInfo = o.str("releaseInfo") ?: o.str("year"), imdbRating = o.dbl("imdbRating"),
            genres = o.strings("genres") + o.strings("genre"), runtime = o.str("runtime"), videos = videos,
            imdbId = o.str("imdb_id") ?: id.takeIf { it.startsWith("tt") },
            cast = o.objects("links").filter { it.str("category") == "Cast" }.mapNotNull { it.str("name") }
                .ifEmpty { o.strings("cast") },
            trailer = trailer,
            people = parsePeople(o),
            trailers = trailers,
        )
    }

    private fun parsePeople(o: JsonObject): List<Person> {
        fun person(c: JsonObject, i: Int): Person? {
            val name = c.str("name") ?: return null
            val photo = c.str("photo")?.takeIf { it.startsWith("http") } ?: Tmdb.image(c.str("profile_path"), Tmdb.PROFILE_SIZE)
            val id = c.int("id")?.takeIf { it > 0 } ?: (-1000 - i)
            return Person(id, name, c.str("character"), photo)
        }
        val extras = o.child("app_extras")?.objects("cast")?.mapIndexedNotNull { i, c -> person(c, i) } ?: emptyList()
        val credits = o.objects("credits_cast").mapIndexedNotNull { i, c -> person(c, 500 + i) }
        if (credits.isEmpty()) return extras
        if (extras.isEmpty()) return credits
        val byName = credits.associateBy { normalizeName(it.name) }
        val used = mutableSetOf<String>()
        val merged = extras.map { p ->
            val key = normalizeName(p.name)
            val other = byName[key] ?: return@map p
            used.add(key)
            p.copy(id = if (p.id > 0) p.id else other.id, photo = p.photo ?: other.photo, role = p.role ?: other.role)
        }
        return merged + credits.filter { normalizeName(it.name) !in used }
    }

    private fun parseStream(o: JsonObject): Stream {
        val hints = o.child("behaviorHints")
        val headers = hints?.child("proxyHeaders")?.child("request")?.mapNotNull { (k, v) -> (v as? JsonPrimitive)?.content?.let { k to it } }?.toMap() ?: emptyMap()
        return Stream(
            url = o.str("url"), infoHash = o.str("infoHash")?.lowercase(), fileIdx = o.int("fileIdx"),
            externalUrl = o.str("externalUrl"), name = o.str("name"), title = o.str("title"), description = o.str("description"),
            trackers = o.strings("sources").filter { it.startsWith("tracker:") }.map { it.removePrefix("tracker:") },
            filename = hints?.str("filename"), videoSize = hints?.long("videoSize"), bingeGroup = hints?.str("bingeGroup"),
            headers = headers, subtitles = o.objects("subtitles").mapNotNull { parseSub(it) },
        )
    }

    @Suppress("unused")
    private fun parseAny(text: String) = parseJson(text)?.arr()
}
