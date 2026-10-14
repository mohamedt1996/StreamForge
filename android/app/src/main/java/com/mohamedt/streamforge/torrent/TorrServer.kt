package com.mohamedt.streamforge.torrent

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.mohamedt.streamforge.core.Http
import com.mohamedt.streamforge.core.Settings
import com.mohamedt.streamforge.core.Store
import com.mohamedt.streamforge.core.arr
import com.mohamedt.streamforge.core.dbl
import com.mohamedt.streamforge.core.int
import com.mohamedt.streamforge.core.long
import com.mohamedt.streamforge.core.normalizedBase
import com.mohamedt.streamforge.core.obj
import com.mohamedt.streamforge.core.objects
import com.mohamedt.streamforge.core.str
import java.net.URLEncoder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

data class TorrentFile(val id: Int, val path: String, val length: Long) {
    val name: String get() = path.substringAfterLast('/')
    val isVideo: Boolean
        get() = path.substringAfterLast('.', "").lowercase() in setOf("mkv", "mp4", "avi", "m4v", "mov", "ts", "m2ts", "webm", "wmv", "mpg", "mpeg")
}

data class TorrentStatus(
    val hash: String,
    val title: String,
    val poster: String?,
    val stat: Int,
    val statText: String,
    val loaded: Long,
    val size: Long,
    val preloaded: Long,
    val preloadSize: Long,
    val downloadSpeed: Double,
    val uploadSpeed: Double,
    val activePeers: Int,
    val totalPeers: Int,
    val seeders: Int,
    val bytesRead: Long,
    val files: List<TorrentFile>,
) {
    val hasMetadata get() = files.isNotEmpty()
    val videoFiles get() = files.filter { it.isVideo }.sortedBy { it.path }

    companion object {
        fun parse(o: JsonObject) = TorrentStatus(
            hash = o.str("hash") ?: "", title = o.str("title") ?: o.str("name") ?: "", poster = o.str("poster"),
            stat = o.int("stat") ?: 0, statText = o.str("stat_string") ?: "",
            loaded = o.dbl("loaded_size")?.toLong() ?: 0, size = o.dbl("torrent_size")?.toLong() ?: 0,
            preloaded = o.dbl("preloaded_bytes")?.toLong() ?: 0, preloadSize = o.dbl("preload_size")?.toLong() ?: 0,
            downloadSpeed = o.dbl("download_speed") ?: 0.0, uploadSpeed = o.dbl("upload_speed") ?: 0.0,
            activePeers = o.int("active_peers") ?: 0, totalPeers = o.int("total_peers") ?: 0,
            seeders = o.int("connected_seeders") ?: 0, bytesRead = o.long("bytes_read_useful_data") ?: o.long("bytes_read_data") ?: 0,
            files = o.objects("file_stats").map { f -> TorrentFile(f.int("id") ?: 0, f.str("path") ?: "", f.dbl("length")?.toLong() ?: 0) },
        )
    }
}

/** What a stream asks the engine to play. */
data class TorrentSource(
    val infoHash: String,
    val fileIdx: Int? = null,
    val filename: String? = null,
    val trackers: List<String> = emptyList(),
    val title: String? = null,
    val poster: String? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val addonName: String? = null,
) {
    val magnet: String
        get() = buildString {
            append("magnet:?xt=urn:btih:").append(infoHash)
            title?.let { append("&dn=").append(URLEncoder.encode(it, "UTF-8")) }
            trackers.forEach { append("&tr=").append(URLEncoder.encode(it, "UTF-8")) }
        }

    companion object {
        fun parse(magnet: String): TorrentSource? {
            if (!magnet.startsWith("magnet:")) return null
            val params = magnet.substringAfter('?').split('&').mapNotNull {
                val i = it.indexOf('='); if (i < 0) null else it.substring(0, i) to java.net.URLDecoder.decode(it.substring(i + 1), "UTF-8")
            }
            val hash = params.firstOrNull { it.first == "xt" }?.second?.substringAfterLast(':')?.lowercase() ?: return null
            return TorrentSource(hash, trackers = params.filter { it.first == "tr" }.map { it.second },
                title = params.firstOrNull { it.first == "dn" }?.second)
        }
    }
}

/** Context shown in the Activity tab: which title/episode/addon a torrent belongs to. */
data class TorrentContext(val title: String, val subtitle: String?, val poster: String?, val addon: String?)

/**
 * TorrServer client — the embedded engine (gomobile AAR, loaded by reflection) on 127.0.0.1, or a
 * TorrServer on the network. Both speak the same HTTP API.
 */
object TorrServer {
    const val EMBEDDED_PORT = 8091
    var embeddedRunning by mutableStateOf(false); private set
    var lastError by mutableStateOf<String?>(null); private set
    var torrents by mutableStateOf<List<TorrentStatus>>(emptyList()); private set
    val contexts = mutableStateMapOf<String, TorrentContext>()
    /** Download-speed history per torrent for the Activity graphs. */
    val speedHistory = mutableStateMapOf<String, List<Double>>()

    val embeddedAvailable: Boolean by lazy { runCatching { Class.forName("torrserverkit.Torrserverkit") }.isSuccess }
    val embedded: Boolean get() = embeddedAvailable && Settings.values.torrentEmbedded

    val baseUrl: String?
        get() = if (embedded) "http://127.0.0.1:$EMBEDDED_PORT" else normalizedBase(Settings.values.remoteTorrServer)

    val configured: Boolean get() = baseUrl != null

    val authHeaders: Map<String, String>
        get() {
            val user = Settings.values.torrServerUser
            if (embedded || user.isEmpty()) return emptyMap()
            val token = android.util.Base64.encodeToString("$user:${Settings.torrServerPassword}".toByteArray(), android.util.Base64.NO_WRAP)
            return mapOf("Authorization" to "Basic $token")
        }

    private val startLock = Mutex()

    suspend fun startEmbeddedIfNeeded() {
        if (!embedded || embeddedRunning) return
        // App start, the Activity tab and every API call race here; start the Go server only once.
        startLock.withLock { startLocked() }
    }

    private suspend fun startLocked() {
        if (!embedded || embeddedRunning) return
        val dir = Store.file("torrserver").apply { mkdirs() }
        val err = withContext(Dispatchers.IO) {
            runCatching {
                val cls = Class.forName("torrserverkit.Torrserverkit")
                val m = cls.getMethod("startServer", Long::class.javaPrimitiveType, String::class.java)
                m.invoke(null, EMBEDDED_PORT.toLong(), dir.absolutePath) as? String ?: ""
            }.getOrElse { it.message ?: "Couldn't start the torrent engine" }
        }
        if (err.isEmpty() || err.contains("already running")) {
            embeddedRunning = true
            lastError = null
            for (i in 0 until 40) { if (ping()) break; delay(150) }
            applyEmbeddedSettings()
        } else {
            lastError = err
        }
    }

    private suspend fun applyEmbeddedSettings() {
        val base = baseUrl ?: return
        val current = runCatching { Http.json("$base/settings", method = "POST", body = """{"action":"get"}""").obj() }.getOrNull() ?: return
        val sets = current.toMutableMap()
        sets["CacheSize"] = JsonPrimitive(Settings.values.torrCacheMb.toLong() * 1024 * 1024)
        sets["ReaderReadAHead"] = JsonPrimitive(95)
        sets["PreloadCache"] = JsonPrimitive(5)
        sets["UseDisk"] = JsonPrimitive(false)
        sets["RemoveCacheOnDrop"] = JsonPrimitive(true)
        sets["ConnectionsLimit"] = JsonPrimitive(40)
        sets["EnableDLNA"] = JsonPrimitive(false)
        val body = buildJsonObject { put("action", "set"); put("sets", JsonObject(sets)) }.toString()
        runCatching { Http.text("$base/settings", method = "POST", body = body) }
    }

    suspend fun ping(): Boolean {
        val base = baseUrl ?: return false
        return runCatching { Http.text("$base/echo", authHeaders, timeoutSeconds = 3) }.isSuccess
    }

    suspend fun version(): String? {
        val base = baseUrl ?: return null
        return runCatching { Http.text("$base/echo", authHeaders, timeoutSeconds = 5).trim() }.getOrNull()
    }

    private suspend fun call(body: String): kotlinx.serialization.json.JsonElement {
        if (embedded) startEmbeddedIfNeeded()
        val base = baseUrl ?: throw IllegalStateException("Set a TorrServer address in Settings → Torrents.")
        return Http.json("$base/torrents", authHeaders, method = "POST", body = body)
    }

    suspend fun add(source: TorrentSource): TorrentStatus {
        val body = buildJsonObject {
            put("action", "add"); put("link", source.magnet); put("save_to_db", false)
            source.title?.let { put("title", it) }
            source.poster?.let { put("poster", it) }
        }.toString()
        return TorrentStatus.parse(call(body).obj() ?: throw IllegalStateException("Torrent engine error"))
    }

    suspend fun status(hash: String): TorrentStatus =
        TorrentStatus.parse(call("""{"action":"get","hash":"$hash"}""").obj() ?: throw IllegalStateException("Torrent not found"))

    suspend fun refreshList() {
        if (!configured) return
        val list = runCatching { call("""{"action":"list"}""").arr()?.mapNotNull { it.obj()?.let(TorrentStatus::parse) } }.getOrNull() ?: return
        torrents = list
        for (t in list) {
            val h = speedHistory[t.hash] ?: emptyList()
            speedHistory[t.hash] = (h + t.downloadSpeed).takeLast(60)
        }
    }

    suspend fun remove(hash: String) {
        runCatching { call("""{"action":"rem","hash":"$hash"}""") }
        torrents = torrents.filter { it.hash != hash }
        contexts.remove(hash)
    }

    suspend fun drop(hash: String) { runCatching { call("""{"action":"drop","hash":"$hash"}""") } }

    /** Adds the torrent, waits for metadata, picks the file and returns a stream URL. */
    suspend fun resolve(source: TorrentSource, progress: (String) -> Unit): Pair<String, String> {
        progress("Connecting to peers…")
        var status = add(source)
        val hash = status.hash.ifEmpty { source.infoHash }
        var attempts = 0
        while (!status.hasMetadata) {
            if (++attempts > 90) throw IllegalStateException("No peers responded. The torrent may be dead.")
            delay(500)
            status = status(hash)
            progress("Fetching torrent info…" + if (status.activePeers > 0) " · ${status.activePeers} peers" else "")
        }
        val file = pickFile(status.files, source) ?: throw IllegalStateException("No playable video file in this torrent.")
        val base = baseUrl ?: throw IllegalStateException("TorrServer not configured")
        progress("Buffering…")
        val url = "$base/stream/${URLEncoder.encode(file.name, "UTF-8").replace("+", "%20")}?link=$hash&index=${file.id}&play"
        return url to hash
    }

    private fun pickFile(files: List<TorrentFile>, s: TorrentSource): TorrentFile? {
        s.fileIdx?.let { idx -> files.firstOrNull { it.id == idx + 1 }?.let { if (it.isVideo || files.size == 1) return it } }
        s.filename?.lowercase()?.let { n -> files.firstOrNull { it.name.lowercase() == n }?.let { return it } }
        val videos = files.filter { it.isVideo }
        if (s.season != null && s.episode != null) {
            for (p in listOf("s%02de%02d".format(s.season, s.episode), "%dx%02d".format(s.season, s.episode), "e%02d".format(s.episode))) {
                videos.firstOrNull { it.name.lowercase().contains(p) }?.let { return it }
            }
        }
        return videos.maxByOrNull { it.length } ?: files.maxByOrNull { it.length }
    }
}
