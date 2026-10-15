package com.mohamedt.streamforge.sync

import com.mohamedt.streamforge.core.Episode
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.MediaType
import com.mohamedt.streamforge.core.Origin
import com.mohamedt.streamforge.core.Settings
import com.mohamedt.streamforge.core.SettingsValues
import com.mohamedt.streamforge.core.child
import com.mohamedt.streamforge.core.dbl
import com.mohamedt.streamforge.core.int
import com.mohamedt.streamforge.core.long
import com.mohamedt.streamforge.core.normalizedBase
import com.mohamedt.streamforge.core.str
import com.mohamedt.streamforge.dispatcharr.AuthMode
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.dispatcharr.Server
import com.mohamedt.streamforge.library.Library
import com.mohamedt.streamforge.library.Progress
import com.mohamedt.streamforge.stremio.Addon
import com.mohamedt.streamforge.stremio.Addons
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** Android has no profiles: every profile-scoped record uses this. */
internal const val PROFILE = "default"

/** Collection of managed items a user continues without (PROTOCOL.md §5, Dismissals). */
internal const val DISMISSED = "dismissed"

/** Sync bookkeeping persisted in sync-state.json. Keys are "<collection>/<id>". */
@Serializable
internal data class SyncState(
    var lastRev: Long = 0,
    /** False until the first diff after install recorded what already existed (stamped as old). */
    var baselined: Boolean = false,
    /** Fingerprint of each record's data as last synced or seen locally. */
    val known: MutableMap<String, String> = mutableMapOf(),
    /** updatedAt of the local copy of each record (LWW). */
    val stamps: MutableMap<String, Long> = mutableMapOf(),
    /** Favourite channel ids per Dispatcharr server UUID (the local Library only keeps the active server's). */
    val channelFavs: MutableMap<String, List<Long>> = mutableMapOf(),
    var lastActiveServer: String? = null,
    /** First 8 chars of a server UUID → full UUID (local item ids only carry the prefix). */
    val serverIds: MutableMap<String, String> = mutableMapOf(),
    /** Canonical item key → when it was favourited. */
    val favoriteAddedAt: MutableMap<String, Long> = mutableMapOf(),
    /** Record keys the server admin manages for this user (PROTOCOL.md §5). */
    val managed: MutableSet<String> = mutableSetOf(),
    /** Values of managed settings (put back when the user keeps the managed value). */
    val managedSettings: MutableMap<String, JsonElement> = mutableMapOf(),
    /** Display names of managed items by record key. */
    val managedNames: MutableMap<String, String> = mutableMapOf(),
    /** Active dismissals "<collection>|<id>" → dismissedAt (ms), synced as `dismissed` records. */
    val dismissed: MutableMap<String, Long> = mutableMapOf(),
    /** Managed servers/addons removed on this device without a dismissal (record keys). */
    val locallyRemoved: MutableSet<String> = mutableSetOf(),
    /** Managed records sync brought back after a local removal, waiting for the user's answer. */
    val held: MutableMap<String, HeldRecord> = mutableMapOf(),
    /** False for state saved before managed records were tracked: pull everything again once. */
    var managedTracked: Boolean = false,
)

/** A pulled managed record kept out of the stores until the user answers the restore prompt. */
@Serializable
internal data class HeldRecord(
    val collection: String,
    val id: String,
    val data: JsonObject? = null,
    val updatedAt: Long,
)

@Serializable
internal data class OutboxEntry(
    val collection: String,
    val id: String,
    val data: JsonObject? = null,
    val deleted: Boolean = false,
    val updatedAt: Long,
) {
    val key: String get() = rk(collection, id)
}

internal class LocalRecord(
    val collection: String,
    val id: String,
    val data: JsonObject,
    /** Time the content itself says it changed (progress / watched), used instead of "now". */
    val natural: Long? = null,
)

internal fun rk(collection: String, id: String) = "$collection/$id"

/** One setting key of protocol §3 mapped onto SettingsValues. */
private class SettingMap(
    val key: String,
    val read: (SettingsValues) -> JsonPrimitive,
    val write: (SettingsValues, JsonPrimitive) -> SettingsValues?,
)

private fun JsonPrimitive.text(): String? = if (this is JsonNull) null else contentOrNull
private fun JsonPrimitive.flag(): Boolean? = if (this is JsonNull) null else booleanOrNull ?: content.toBooleanStrictOrNull()
private fun JsonPrimitive.whole(): Int? = if (this is JsonNull) null else longOrNull?.toInt() ?: doubleOrNull?.toInt() ?: content.toDoubleOrNull()?.toInt()
private fun JsonPrimitive.number(): Double? = if (this is JsonNull) null else doubleOrNull ?: content.toDoubleOrNull()

private val settingsMap: List<SettingMap> = listOf(
    SettingMap("metadataLanguage", { JsonPrimitive(it.metadataLanguage) }, { s, v -> v.text()?.takeIf { t -> t.isNotBlank() }?.let { s.copy(metadataLanguage = it) } }),
    SettingMap("maxResolution", { JsonPrimitive(it.maxResolution) }, { s, v -> v.whole()?.let { s.copy(maxResolution = it) } }),
    SettingMap("excludeCam", { JsonPrimitive(it.excludeCam) }, { s, v -> v.flag()?.let { s.copy(excludeCam = it) } }),
    SettingMap("trailerAutoplay", { JsonPrimitive(it.trailerAutoplay) }, { s, v -> v.flag()?.let { s.copy(trailerAutoplay = it) } }),
    SettingMap("autoplayNext", { JsonPrimitive(it.autoplayNext) }, { s, v -> v.flag()?.let { s.copy(autoplayNext = it) } }),
    SettingMap("seekStep", { JsonPrimitive(it.seekStep) }, { s, v -> v.whole()?.takeIf { n -> n > 0 }?.let { s.copy(seekStep = it) } }),
    SettingMap("skipIntros", { JsonPrimitive(it.skipIntros) }, { s, v -> v.flag()?.let { s.copy(skipIntros = it) } }),
    SettingMap("autoSkip", { JsonPrimitive(it.autoSkip) }, { s, v -> v.flag()?.let { s.copy(autoSkip = it) } }),
    SettingMap("audioLanguage", { JsonPrimitive(it.audioLanguage) }, { s, v -> v.text()?.let { s.copy(audioLanguage = it) } }),
    SettingMap("subtitleLanguage", { JsonPrimitive(it.subtitleLanguage) }, { s, v -> v.text()?.let { s.copy(subtitleLanguage = it) } }),
    SettingMap("autoSubtitles", { JsonPrimitive(it.autoSubtitles) }, { s, v -> v.flag()?.let { s.copy(autoSubtitles = it) } }),
    // Float → Double via its decimal text so 0.8f is sent as 0.8, not 0.800000011920929.
    SettingMap("subtitleScale", { JsonPrimitive(it.subtitleScale.toString().toDouble()) }, { s, v -> v.number()?.takeIf { n -> n > 0 }?.let { s.copy(subtitleScale = it.toFloat()) } }),
    SettingMap("hideAdult", { JsonPrimitive(it.hideAdult) }, { s, v -> v.flag()?.let { s.copy(hideAdult = it) } }),
    SettingMap("torrentMode", { JsonPrimitive(if (it.torrentEmbedded) "embedded" else "remote") }, { s, v ->
        when (v.text()) {
            "embedded" -> s.copy(torrentEmbedded = true)
            "remote" -> s.copy(torrentEmbedded = false)
            else -> null
        }
    }),
    SettingMap("remoteTorrServer", { JsonPrimitive(it.remoteTorrServer) }, { s, v -> v.text()?.let { s.copy(remoteTorrServer = it) } }),
)

/** Local data ⇄ protocol records (§3). Everything here runs on the main thread. */
internal object SyncMapping {

    // MARK: Canonical item key

    private fun typeName(type: MediaType): String? = when (type) {
        MediaType.MOVIE -> "movie"
        MediaType.SERIES -> "series"
        MediaType.CHANNEL -> null
        MediaType.OTHER -> null
    }

    /** Remembers every local server's UUID by its 8-char prefix (kept after a server is removed). */
    fun learnServers(st: SyncState) {
        for (s in DispatcharrRepo.servers) learnServer(st, s.id)
    }

    private fun learnServer(st: SyncState, id: String) {
        val full = id.lowercase()
        if (full.length >= 8) st.serverIds[full.take(8)] = full
    }

    /** "xc:<8 chars of server id>:movie:<id>" → full server UUID. */
    private fun dispatcharrServerId(item: MediaItem, st: SyncState): String? {
        val parts = item.id.split(":")
        if (parts.size < 4 || parts[0] != "xc") return null
        val prefix = parts[1].lowercase()
        DispatcharrRepo.servers.firstOrNull { it.id.lowercase().startsWith(prefix) }?.let { return it.id.lowercase() }
        return st.serverIds[prefix]
    }

    /** IMDb → TMDB → Dispatcharr → addon meta id (protocol §3). Null for things that never sync. */
    fun itemKey(item: MediaItem, st: SyncState): String? {
        val t = typeName(item.type) ?: return null
        // Same IMDb detection as the Apple app: explicit id, then a "tt…" addon meta id or item id.
        val imdb = item.imdbId?.trim()?.takeIf { it.startsWith("tt") && it.length > 2 }
            ?: item.origin.metaId?.trim()?.takeIf { it.startsWith("tt") && ':' !in it }
            ?: item.id.takeIf { it.startsWith("tt") && ':' !in it && '#' !in it }
        imdb?.let { return "$t:$it" }
        (item.tmdbId?.takeIf { it > 0 } ?: item.origin.takeIf { it.kind == "tmdb" }?.id?.toInt()?.takeIf { it > 0 })
            ?.let { return "$t:tmdb:$it" }
        if (item.origin.kind == "xc-movie" || item.origin.kind == "xc-series") {
            val sid = dispatcharrServerId(item, st) ?: return null
            return "$t:dispatcharr:$sid:${item.origin.id}"
        }
        item.origin.metaId?.trim()?.takeIf { it.isNotEmpty() }?.let { return "$t:meta:$it" }
        return null
    }

    fun episodeKey(base: String, season: Int, episode: Int) = "$base:s${season}e$episode"

    private val episodeSuffix = Regex(":s(\\d+)e(\\d+)$")

    /** "series:tt1:s1e2" → ("series:tt1", 1 to 2). */
    fun splitKey(key: String): Pair<String, Pair<Int, Int>?> {
        val m = episodeSuffix.find(key) ?: return key to null
        val s = m.groupValues[1].toIntOrNull() ?: return key to null
        val e = m.groupValues[2].toIntOrNull() ?: return key to null
        return key.substring(0, m.range.first) to (s to e)
    }

    // MARK: Item JSON

    fun itemJson(item: MediaItem, key: String, st: SyncState): JsonObject = buildJsonObject {
        put("key", key)
        put("type", typeName(item.type) ?: "movie")
        put("title", item.title)
        item.year?.let { put("year", it) }
        item.poster?.let { put("poster", it) }
        item.backdrop?.let { put("backdrop", it) }
        item.logo?.let { put("logo", it) }
        item.imdbId?.takeIf { it.startsWith("tt") }?.let { put("imdbId", it) }
        item.tmdbId?.takeIf { it > 0 }?.let { put("tmdbId", it) }
        item.runtimeMinutes?.takeIf { it > 0 }?.let { put("runtimeMinutes", it) }
        put("origin", buildJsonObject {
            when (item.origin.kind) {
                "xc-movie", "xc-series" -> {
                    put("kind", if (item.origin.kind == "xc-movie") "dispatcharrMovie" else "dispatcharrSeries")
                    dispatcharrServerId(item, st)?.let { put("serverId", it) }
                    put("streamId", item.origin.id)
                    item.origin.ext?.let { put("ext", it) }
                }
                "stremio" -> {
                    put("kind", "addon")
                    item.origin.addonId?.let { put("addonId", it) }
                    item.origin.metaId?.let { put("metaId", it) }
                    put("metaType", item.type.stremio)
                }
                "tmdb" -> put("kind", "tmdb")
                else -> put("kind", "other")
            }
        })
    }

    private fun localServerId(uuid: String): String? = DispatcharrRepo.servers.firstOrNull { it.id.equals(uuid, ignoreCase = true) }?.id

    private fun xcItem(type: MediaType, serverId: String, streamId: Long, ext: String?, base: MediaItem): MediaItem {
        val movie = type == MediaType.MOVIE
        return base.copy(
            id = "xc:${serverId.take(8)}:${if (movie) "movie" else "series"}:$streamId",
            origin = Origin(if (movie) "xc-movie" else "xc-series", streamId, ext = ext),
        )
    }

    /** Builds a local item from a remote Item so the card renders (and plays when the source exists here). */
    fun itemFromJson(o: JsonObject, st: SyncState): MediaItem? {
        val key = o.str("key")
        val type = when (o.str("type") ?: key?.substringBefore(':')) {
            "movie" -> MediaType.MOVIE
            "series" -> MediaType.SERIES
            else -> return null
        }
        val imdb = o.str("imdbId")?.takeIf { it.startsWith("tt") }
        val tmdb = o.int("tmdbId")?.takeIf { it > 0 }
        val base = MediaItem(
            id = "", type = type, title = o.str("title") ?: "", year = o.int("year"), poster = o.str("poster"),
            backdrop = o.str("backdrop"), logo = o.str("logo"), imdbId = imdb, tmdbId = tmdb,
            origin = Origin("tmdb"), runtimeMinutes = o.int("runtimeMinutes"),
        )
        val origin = o.child("origin") ?: JsonObject(emptyMap())
        when (origin.str("kind")) {
            "dispatcharrMovie", "dispatcharrSeries" -> {
                val uuid = origin.str("serverId")?.lowercase()
                val streamId = origin.long("streamId")
                if (uuid != null) learnServer(st, uuid)
                val local = uuid?.let { localServerId(it) }
                // Only usable as a Dispatcharr item when this device has that server.
                if (local != null && streamId != null) return xcItem(type, local, streamId, origin.str("ext"), base)
                if (imdb == null && tmdb == null && uuid != null && streamId != null) return xcItem(type, uuid, streamId, origin.str("ext"), base)
            }
            "addon" -> {
                val metaId = origin.str("metaId") ?: imdb
                if (metaId != null) {
                    val addonId = origin.str("addonId")
                    val id = if (metaId.startsWith("tt") || addonId == null) metaId else "stremio:$addonId:$metaId"
                    return base.copy(id = id, origin = Origin("stremio", addonId = addonId, metaId = metaId))
                }
            }
            "tmdb" -> if (tmdb != null) return tmdbItem(base, tmdb)
            else -> Unit
        }
        if (imdb != null) return base.copy(id = imdb, origin = Origin("stremio", metaId = imdb))
        if (tmdb != null) return tmdbItem(base, tmdb)
        return key?.let { stubItem(splitKey(it).first, st)?.copy(title = base.title, poster = base.poster, backdrop = base.backdrop, logo = base.logo, year = base.year) }
    }

    private fun tmdbItem(base: MediaItem, tmdb: Int) =
        base.copy(id = "tmdb:${base.type.name.lowercase()}:$tmdb", origin = Origin("tmdb", tmdb.toLong()))

    /** An item rebuilt from a canonical key alone (watched marks carry no Item). */
    fun stubItem(baseKey: String, st: SyncState): MediaItem? {
        val type = when (baseKey.substringBefore(':')) {
            "movie" -> MediaType.MOVIE
            "series" -> MediaType.SERIES
            else -> return null
        }
        val rest = baseKey.substringAfter(':', "")
        val empty = MediaItem(id = "", type = type, title = "", origin = Origin("tmdb"))
        return when {
            rest.startsWith("tt") -> empty.copy(id = rest, imdbId = rest, origin = Origin("stremio", metaId = rest))
            rest.startsWith("tmdb:") -> rest.removePrefix("tmdb:").toIntOrNull()?.let { tmdbItem(empty.copy(tmdbId = it), it) }
            rest.startsWith("dispatcharr:") -> {
                val parts = rest.removePrefix("dispatcharr:").split(":")
                val uuid = parts.getOrNull(0)?.lowercase() ?: return null
                val streamId = parts.getOrNull(1)?.toLongOrNull() ?: return null
                learnServer(st, uuid)
                xcItem(type, localServerId(uuid) ?: uuid, streamId, null, empty)
            }
            rest.startsWith("meta:") -> rest.removePrefix("meta:").takeIf { it.isNotEmpty() }?.let { m ->
                empty.copy(id = m, origin = Origin("stremio", metaId = m))
            }
            else -> null
        }
    }

    private fun episodeJson(e: Episode): JsonObject = buildJsonObject {
        put("season", e.season)
        put("episode", e.episode)
        put("title", e.title)
        e.still?.let { put("still", it) }
        e.xcEpisodeId?.let { put("dispatcharrEpisodeId", it) }
        e.ext?.let { put("ext", it) }
    }

    private fun episodeFor(item: MediaItem, season: Int, number: Int, o: JsonObject?): Episode {
        val xcId = o?.long("dispatcharrEpisodeId")?.takeIf { item.origin.kind == "xc-series" }
        val videoId = item.imdbId?.let { "$it:$season:$number" }
        return Episode(
            id = xcId?.let { "xc-ep-$it" } ?: videoId ?: "sync-$season-$number",
            season = season, episode = number, title = o?.str("title") ?: "Episode $number",
            still = o?.str("still"), xcEpisodeId = xcId, ext = o?.str("ext"), stremioVideoId = videoId,
        )
    }

    // MARK: Local → records

    /**
     * Every local record keyed by "<collection>/<id>". Also keeps the per-server channel favourites in
     * [st] current (swapping the Library's list when the active server changed).
     */
    fun collect(st: SyncState): LinkedHashMap<String, LocalRecord> {
        val out = LinkedHashMap<String, LocalRecord>()
        fun add(r: LocalRecord) {
            val k = rk(r.collection, r.id)
            if (k !in out) out[k] = r
        }
        learnServers(st)

        // Progress: newest first so duplicates (same film from two sources) keep the latest.
        for (p in Library.syncProgress.values.sortedByDescending { it.updatedAt }) {
            val base = itemKey(p.item, st) ?: continue
            val key = p.episode?.let { episodeKey(base, it.season, it.episode) } ?: base
            add(LocalRecord("progress", "$PROFILE|$key", buildJsonObject {
                put("profile", PROFILE)
                put("item", itemJson(p.item, base, st))
                p.episode?.let { put("episode", episodeJson(it)) }
                put("position", p.position / 1000.0)
                put("duration", p.duration / 1000.0)
            }, natural = p.updatedAt))
        }

        // Watched marks (only those with item info; very old marks have none).
        val info = Library.syncWatchedInfo
        for (k in Library.watched) {
            val w = info[k] ?: continue
            val base = itemKey(w.item, st) ?: continue
            val key = w.episode?.let { episodeKey(base, it.season, it.episode) } ?: base
            add(LocalRecord("watched", "$PROFILE|$key", buildJsonObject {
                put("profile", PROFILE)
                put("key", key)
            }, natural = w.updatedAt))
        }

        // Favourites.
        val now = System.currentTimeMillis()
        val favKeys = HashSet<String>()
        for (item in Library.favorites) {
            val key = itemKey(item, st) ?: continue
            if (!favKeys.add(key)) continue
            val added = st.favoriteAddedAt.getOrPut(key) { now }
            add(LocalRecord("favorites", "$PROFILE|$key", buildJsonObject {
                put("profile", PROFILE)
                put("item", itemJson(item, key, st))
                put("addedAt", added)
            }))
        }
        st.favoriteAddedAt.keys.retainAll(favKeys)

        // Channel favourites, per server.
        val serverIds = DispatcharrRepo.servers.map { it.id.lowercase() }.toSet()
        val active = DispatcharrRepo.active?.id?.lowercase()
        if (active != null) {
            if (st.lastActiveServer != active) {
                val saved = st.channelFavs[active]
                if (saved != null && st.lastActiveServer != null) Library.syncReplaceFavoriteChannels(saved)
                else st.channelFavs[active] = Library.favoriteChannels.toList()
                st.lastActiveServer = active
            } else {
                st.channelFavs[active] = Library.favoriteChannels.toList()
            }
        }
        st.channelFavs.keys.retainAll(serverIds)
        for ((sid, list) in st.channelFavs) for (ch in list.distinct()) {
            add(LocalRecord("channels", "$PROFILE|$sid|$ch", buildJsonObject {
                put("profile", PROFILE)
                put("serverId", sid)
                put("channelId", ch)
                put("favorite", true)
            }))
        }

        // Addons, in priority order.
        Addons.addons.forEachIndexed { i, a ->
            val url = Addons.manifestUrl(a)
            add(LocalRecord("addons", url, buildJsonObject {
                put("transportUrl", url)
                put("name", a.name)
                put("enabled", a.enabled)
                put("order", i)
            }))
        }

        // Dispatcharr servers + their secrets.
        DispatcharrRepo.servers.forEachIndexed { i, s ->
            val id = s.id.lowercase()
            add(LocalRecord("servers", id, buildJsonObject {
                put("name", s.name)
                put("url", s.url ?: s.baseUrl)
                put("username", s.username)
                put("authMode", authModeName(s.authMode))
                put("order", i)
            }))
            add(LocalRecord("secrets", "server:$id", buildJsonObject {
                put("xcPassword", s.xcPassword)
                put("webPassword", s.webPassword)
                put("apiKey", s.apiKey)
            }))
        }
        Settings.tmdbKey.takeIf { it.isNotBlank() }?.let { key ->
            add(LocalRecord("secrets", "key:tmdb", buildJsonObject { put("value", key) }))
        }

        // Settings.
        for ((key, value) in settingValues()) add(LocalRecord("settings", key, buildJsonObject { put("value", value) }))

        // Admin-managed items this account continues without.
        for ((did, at) in st.dismissed) {
            val c = did.substringBefore('|')
            val id = did.substringAfter('|', "")
            add(LocalRecord(DISMISSED, did, buildJsonObject {
                put("collection", c)
                put("id", id)
                put("dismissedAt", at)
            }, natural = at))
        }

        return out
    }

    /** The synced settings of this device: key → value. */
    fun settingValues(): Map<String, JsonPrimitive> {
        val values = Settings.values
        return settingsMap.associate { it.key to it.read(values) }
    }

    /** Applies a managed value to [values]; null when this device can't use it. */
    fun settingWith(values: SettingsValues, key: String, value: JsonElement): SettingsValues? {
        val m = settingsMap.firstOrNull { it.key == key } ?: return null
        val v = value as? JsonPrimitive ?: return null
        return m.write(values, v)
    }

    private fun authModeName(mode: AuthMode): String = when (mode) {
        AuthMode.XC -> "xc"
        AuthMode.ACCOUNT -> "web"
        AuthMode.API_KEY -> "apiKey"
    }

    private fun authMode(name: String?): AuthMode? = when (name) {
        "xc" -> AuthMode.XC
        "web" -> AuthMode.ACCOUNT
        "apiKey" -> AuthMode.API_KEY
        else -> null
    }

    // MARK: Records → local

    /** State for applying one pulled batch. */
    class ApplyContext(st: SyncState, batch: List<JsonObject>) {
        /** Canonical base key → a local item for it (keeps this device's own source when it has one). */
        val items = HashMap<String, MediaItem>()
        /** Full key (with episode) → episode object. */
        val episodes = HashMap<String, Episode>()
        /** Full key → local Library keys holding progress / watched for it. */
        val progressKeys = HashMap<String, MutableSet<String>>()
        val watchedKeys = HashMap<String, MutableSet<String>>()
        /** Items embedded in this batch, by base key (for watched marks that arrive without one). */
        val batchItems = HashMap<String, JsonObject>()
        val addonOps = ArrayList<Triple<String, Boolean, JsonObject?>>()
        val secretsChangedFor = HashSet<String>()

        init {
            fun index(p: Progress, into: HashMap<String, MutableSet<String>>?) {
                val base = SyncMapping.itemKey(p.item, st) ?: return
                val full = p.episode?.let { SyncMapping.episodeKey(base, it.season, it.episode) } ?: base
                items.putIfAbsent(base, p.item)
                p.episode?.let { episodes.putIfAbsent(full, it) }
                into?.getOrPut(full) { HashSet() }?.add(p.key)
            }
            Library.syncProgress.values.sortedByDescending { it.updatedAt }.forEach { index(it, progressKeys) }
            val watched = Library.watched
            Library.syncWatchedInfo.values.forEach { if (it.key in watched) index(it, watchedKeys) else index(it, null) }
            for (f in Library.favorites) SyncMapping.itemKey(f, st)?.let { items.putIfAbsent(it, f) }
            for (r in batch) {
                val item = r.child("data")?.child("item") ?: continue
                val key = item.str("key") ?: continue
                batchItems.putIfAbsent(key, item)
            }
        }
    }

    private fun profileAndKey(id: String): Pair<String, String> = id.substringBefore('|') to id.substringAfter('|', "")

    /** Applies one record. Returns false when it was ignored (unknown collection / other profile). */
    fun apply(collection: String, id: String, deleted: Boolean, data: JsonObject?, updatedAt: Long, ctx: ApplyContext, st: SyncState): Boolean {
        return when (collection) {
            "progress" -> applyProgress(id, deleted, data, updatedAt, ctx, st)
            "watched" -> applyWatched(id, deleted, updatedAt, ctx, st)
            "favorites" -> applyFavorite(id, deleted, data, updatedAt, ctx, st)
            "channels" -> applyChannel(id, deleted, data, st)
            "addons" -> { ctx.addonOps.add(Triple(id, deleted, data)); true }
            "servers" -> applyServer(id, deleted, data, st)
            "secrets" -> applySecret(id, deleted, data, ctx)
            "settings" -> applySetting(id, deleted, data)
            DISMISSED -> {
                if (deleted || data == null) st.dismissed.remove(id) else st.dismissed[id] = data.long("dismissedAt") ?: updatedAt
                true
            }
            else -> false // profiles: Android has none; unknown collections are ignored.
        }
    }

    private fun resolveItem(base: String, embedded: JsonObject?, ctx: ApplyContext, st: SyncState): MediaItem? =
        ctx.items[base] ?: embedded?.let { itemFromJson(it, st) } ?: ctx.batchItems[base]?.let { itemFromJson(it, st) } ?: stubItem(base, st)

    private fun applyProgress(id: String, deleted: Boolean, data: JsonObject?, updatedAt: Long, ctx: ApplyContext, st: SyncState): Boolean {
        val (profile, key) = profileAndKey(id)
        if (profile != PROFILE || key.isEmpty()) return false
        if (deleted || data == null) {
            ctx.progressKeys.remove(key)?.forEach { Library.syncRemoveProgressOnly(it) }
            return true
        }
        val (base, ep) = splitKey(key)
        val item = resolveItem(base, data.child("item"), ctx, st) ?: return false
        ctx.items.putIfAbsent(base, item)
        val epJson = data.child("episode")
        val episode = if (ep == null) null else ctx.episodes[key] ?: episodeFor(item, epJson?.int("season") ?: ep.first, epJson?.int("episode") ?: ep.second, epJson)
        episode?.let { ctx.episodes.putIfAbsent(key, it) }
        val k = Library.key(item, episode)
        val position = ((data.dbl("position") ?: 0.0) * 1000).toLong()
        val duration = ((data.dbl("duration") ?: 0.0) * 1000).toLong()
        Library.syncSetProgress(k, Progress(k, item, episode, position, duration, updatedAt))
        ctx.progressKeys.getOrPut(key) { HashSet() }.add(k)
        return true
    }

    private fun applyWatched(id: String, deleted: Boolean, updatedAt: Long, ctx: ApplyContext, st: SyncState): Boolean {
        val (profile, key) = profileAndKey(id)
        if (profile != PROFILE || key.isEmpty()) return false
        if (deleted) {
            ctx.watchedKeys.remove(key)?.forEach { Library.syncRemoveWatched(it) }
            return true
        }
        val (base, ep) = splitKey(key)
        val item = resolveItem(base, null, ctx, st) ?: return false
        ctx.items.putIfAbsent(base, item)
        val episode = if (ep == null) null else ctx.episodes[key] ?: episodeFor(item, ep.first, ep.second, null)
        val k = Library.key(item, episode)
        // A finished item leaves Continue Watching, unless that position is newer than the mark.
        val dropProgress = Library.syncProgress[k]?.let { it.updatedAt < updatedAt } ?: false
        Library.syncPutWatched(k, Progress(k, item, episode, 0, 0, updatedAt), dropProgress)
        ctx.watchedKeys.getOrPut(key) { HashSet() }.add(k)
        if (dropProgress) ctx.progressKeys[key]?.remove(k)
        return true
    }

    private fun applyFavorite(id: String, deleted: Boolean, data: JsonObject?, updatedAt: Long, ctx: ApplyContext, st: SyncState): Boolean {
        val (profile, key) = profileAndKey(id)
        if (profile != PROFILE || key.isEmpty()) return false
        val existing = Library.favorites.filter { itemKey(it, st) == key }
        if (deleted || data == null) {
            existing.forEach { Library.syncFavorite(it, false) }
            st.favoriteAddedAt.remove(key)
            return true
        }
        st.favoriteAddedAt[key] = data.long("addedAt") ?: updatedAt
        if (existing.isNotEmpty()) return true
        val item = resolveItem(key, data.child("item"), ctx, st) ?: return false
        ctx.items.putIfAbsent(key, item)
        Library.syncFavorite(item, true)
        return true
    }

    private fun applyChannel(id: String, deleted: Boolean, data: JsonObject?, st: SyncState): Boolean {
        val parts = id.split("|")
        if (parts.size != 3 || parts[0] != PROFILE) return false
        val sid = (data?.str("serverId") ?: parts[1]).lowercase()
        val ch = data?.long("channelId") ?: parts[2].toLongOrNull() ?: return false
        val on = !deleted && data != null && (data["favorite"] as? JsonPrimitive)?.flag() != false
        val current = st.channelFavs[sid] ?: emptyList()
        st.channelFavs[sid] = if (on) (current - ch) + ch else current - ch
        if (DispatcharrRepo.active?.id?.lowercase() == sid) Library.syncFavoriteChannel(ch, on)
        return true
    }

    private fun applyServer(id: String, deleted: Boolean, data: JsonObject?, st: SyncState): Boolean {
        val local = DispatcharrRepo.servers.firstOrNull { it.id.equals(id, ignoreCase = true) }
        if (deleted || data == null) {
            local?.let { DispatcharrRepo.remove(it) }
            return true
        }
        learnServer(st, id)
        val url = data.str("url") ?: local?.baseUrl ?: return false
        val server = Server(
            id = local?.id ?: id.lowercase(),
            name = data.str("name") ?: local?.name ?: (normalizedBase(url)?.substringAfter("://")?.substringBefore(":") ?: "Dispatcharr"),
            baseUrl = url,
            username = data.str("username") ?: local?.username ?: "",
            authMode = authMode(data.str("authMode")) ?: local?.authMode ?: AuthMode.ACCOUNT,
        )
        if (server != local) DispatcharrRepo.upsertFromSync(server)
        return true
    }

    private fun rawString(o: JsonObject?, key: String): String? = (o?.get(key) as? JsonPrimitive)?.text()

    private fun applySecret(id: String, deleted: Boolean, data: JsonObject?, ctx: ApplyContext): Boolean {
        when {
            id.startsWith("server:") -> {
                val uuid = id.removePrefix("server:")
                val sid = localServerId(uuid) ?: uuid.lowercase()
                // Secrets are keyed by server id in private prefs, so they can land before the server record.
                val s = Server(id = sid, name = "", baseUrl = "", username = "")
                val xc = if (deleted) "" else rawString(data, "xcPassword") ?: s.xcPassword
                val web = if (deleted) "" else rawString(data, "webPassword") ?: s.webPassword
                val key = if (deleted) "" else rawString(data, "apiKey") ?: s.apiKey
                if (xc != s.xcPassword || web != s.webPassword || key != s.apiKey) {
                    s.xcPassword = xc
                    s.webPassword = web
                    s.apiKey = key
                    ctx.secretsChangedFor.add(sid)
                }
                return true
            }
            id == "key:tmdb" -> {
                val v = if (deleted) "" else rawString(data, "value") ?: ""
                if (v.trim() != Settings.tmdbKey) Settings.tmdbKey = v
                return true
            }
            // key:omdb, key:fanart, trakt, pin:*, parentPin — Android has no such features.
            else -> return false
        }
    }

    private fun applySetting(id: String, deleted: Boolean, data: JsonObject?): Boolean {
        if (deleted) return false
        val m = settingsMap.firstOrNull { it.key == id } ?: return false
        val v = data?.get("value") as? JsonPrimitive ?: return false
        val updated = m.write(Settings.values, v) ?: return false
        if (updated != Settings.values) Settings.update { updated }
        return true
    }

    /** Addons need their manifests fetched, so they are applied after the rest of the batch. */
    suspend fun applyAddons(ctx: ApplyContext) {
        if (ctx.addonOps.isEmpty()) return
        val orders = HashMap<String, Int>()
        val enabled = HashMap<String, Boolean>()
        for ((url, deleted, data) in ctx.addonOps) {
            val local = Addons.addons.firstOrNull { Addons.manifestUrl(it) == url }
            if (deleted || data == null) {
                local?.let { Addons.remove(it) }
                orders.remove(url); enabled.remove(url)
                continue
            }
            var installedUrl = url
            if (local == null) {
                val installed: Addon = runCatching { Addons.install(url) }.getOrNull() ?: continue
                installedUrl = Addons.manifestUrl(installed)
            }
            data.int("order")?.let { orders[installedUrl] = it }
            (data["enabled"] as? JsonPrimitive)?.flag()?.let { enabled[installedUrl] = it }
        }
        val current = Addons.addons
        val reordered = current.withIndex()
            .sortedWith(compareBy<IndexedValue<Addon>> { orders[Addons.manifestUrl(it.value)] ?: it.index }.thenBy { it.index })
            .map { (_, a) -> enabled[Addons.manifestUrl(a)]?.let { e -> if (e != a.enabled) a.copy(enabled = e) else a } ?: a }
        if (reordered != current) Addons.replaceAllFromSync(reordered)
    }

    /** Reconnects the active server when its passwords arrived/changed and nothing is loaded yet. */
    fun afterSecrets(ctx: ApplyContext) {
        val active = DispatcharrRepo.active ?: return
        if (active.id in ctx.secretsChangedFor && DispatcharrRepo.channels.isEmpty() && DispatcharrRepo.movieItems.isEmpty()) {
            DispatcharrRepo.activate(active.id)
        }
    }
}
