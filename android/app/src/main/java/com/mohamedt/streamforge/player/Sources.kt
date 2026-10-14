package com.mohamedt.streamforge.player

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.mohamedt.streamforge.core.Episode
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.MediaType
import com.mohamedt.streamforge.core.Settings
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.stremio.Addons
import com.mohamedt.streamforge.stremio.Stream
import com.mohamedt.streamforge.stremio.Subtitle
import com.mohamedt.streamforge.torrent.TorrentSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

sealed interface SourceKind {
    data class Direct(val url: String, val headers: Map<String, String> = emptyMap()) : SourceKind
    data class Torrent(val source: TorrentSource) : SourceKind
    data class Recording(val id: Long) : SourceKind
    data class External(val url: String) : SourceKind
}

data class PlaybackSource(
    val id: String,
    val kind: SourceKind,
    val title: String,
    val detail: String? = null,
    val provider: String,
    val resolution: Int = 0,
    val tags: List<String> = emptyList(),
    val size: Long? = null,
    val seeders: Int? = null,
    val cached: Boolean = false,
    val bingeGroup: String? = null,
    val subtitles: List<Subtitle> = emptyList(),
    val filename: String? = null,
) {
    val isTorrent get() = kind is SourceKind.Torrent
    val resolutionLabel: String
        get() = when {
            resolution >= 2160 -> "4K"
            resolution >= 1440 -> "1440p"
            resolution >= 1080 -> "1080p"
            resolution >= 720 -> "720p"
            resolution > 0 -> "SD"
            else -> ""
        }

    val score: Double
        get() {
            var s = resolution.toDouble()
            if ("DV" in tags) s += 60
            if ("HDR" in tags || "HDR10+" in tags) s += 40
            if ("REMUX" in tags) s += 20
            if ("Atmos" in tags) s += 10
            if (cached) s += 2000
            if (kind is SourceKind.Direct) s += 500
            seeders?.let { s += minOf(it, 200) / 4.0 }
            if ("CAM" in tags) s -= 3000
            return s
        }
}

/** Pulls quality, HDR flags, size and seeders out of addon stream text. */
object StreamText {
    private val res = Regex("""(?i)\b(2160|1440|1080|720|576|480|360)p\b|\b(4k|uhd)\b""")
    private val size = Regex("""(?i)(\d+(?:[.,]\d+)?)\s*(gb|mb|gib|mib)\b""")
    private val seeds = Regex("""(?i)(?:👤|seeders?:?|seeds?:?|s:)\s*(\d+)""")

    data class Parsed(val resolution: Int, val tags: List<String>, val size: Long?, val seeders: Int?, val cached: Boolean)

    fun parse(text: String): Parsed {
        val r = res.find(text)?.let { m -> m.groupValues[1].toIntOrNull() ?: 2160 } ?: 0
        val sz = size.findAll(text).lastOrNull()?.let { m ->
            val v = m.groupValues[1].replace(',', '.').toDoubleOrNull() ?: return@let null
            (v * if (m.groupValues[2].lowercase().startsWith("g")) 1_073_741_824 else 1_048_576).toLong()
        }
        val sd = seeds.find(text)?.groupValues?.get(1)?.toIntOrNull()
        val l = text.lowercase()
        fun has(vararg n: String) = n.any { l.contains(it) }
        val tags = mutableListOf<String>()
        if (has("dolby vision", " dv ", ".dv.", "dovi", "[dv]")) tags += "DV"
        if (has("hdr10+", "hdr10plus")) tags += "HDR10+" else if (has("hdr")) tags += "HDR"
        if (has("remux")) tags += "REMUX"
        if (has("hevc", "x265", "h265", "h.265")) tags += "HEVC"
        if (has("av1")) tags += "AV1"
        if (has("atmos")) tags += "Atmos"
        if (has(" cam ", "camrip", "hdcam", "telesync", " ts ", "hdts")) tags += "CAM"
        val cached = has("[rd+]", "[ad+]", "[pm+]", "[tb+]", "rd+", "⚡", "instant", "cached")
        return Parsed(r, tags, sz, sd, cached)
    }
}

/** Collects sources for one movie/episode from Dispatcharr and every addon, incrementally. */
class SourcesModel(val item: MediaItem, val episode: Episode?) {
    val sources = mutableStateListOf<PlaybackSource>()
    var loading by mutableStateOf(false); private set
    var pendingAddons by mutableStateOf(0); private set

    val sorted: List<PlaybackSource>
        get() {
            val s = Settings.values
            return sources.filter { !(s.excludeCam && "CAM" in it.tags) && (it.resolution <= s.maxResolution || it.resolution == 0) }
                .distinctBy { it.id }
                .sortedByDescending { it.score }
        }

    val runtimeMinutes: Int? get() = episode?.runtimeMinutes ?: item.runtimeMinutes

    fun estimate(src: PlaybackSource) = com.mohamedt.streamforge.torrent.StartEstimator.estimate(src, runtimeMinutes, episode != null)

    /** Quick and smooth sources first. */
    fun fastest(list: List<PlaybackSource>) =
        list.sortedBy { com.mohamedt.streamforge.torrent.StartEstimator.fastestKey(it, runtimeMinutes, episode != null) }

    suspend fun load() {
        loading = true
        sources.clear()
        // REST streaming servers address streams by UUID: fetch any this device hasn't seen yet.
        DispatcharrRepo.client?.let { c ->
            runCatching { c.preparePlayback(if (episode == null && item.origin.kind == "xc-movie") item.origin.id else null, episode?.xcEpisodeId) }
        }
        addServerSources()
        val type = if (item.type == MediaType.MOVIE) "movie" else "series"
        val id = if (episode != null) episode.stremioVideoId ?: item.imdbId?.let { "$it:${episode.season}:${episode.episode}" } else item.stremioId
        if (id != null) {
            pendingAddons = Addons.enabled.count { it.supports("stream", type, id) }
            Addons.streams(type, id) { addon, streams ->
                val built = streams.mapIndexedNotNull { i, s -> make(s, i, addon.id, addon.name) }
                withContext(Dispatchers.Main) {
                    sources.addAll(built)
                    pendingAddons = maxOf(0, pendingAddons - 1)
                }
            }
        }
        pendingAddons = 0
        loading = false
    }

    private fun addServerSources() {
        val client = DispatcharrRepo.client ?: return
        val name = DispatcharrRepo.active?.name ?: "Server"
        fun add(url: String?, title: String, ext: String?) {
            if (url == null) return
            val p = StreamText.parse("$title ${ext ?: ""}")
            sources += PlaybackSource("server:$url", SourceKind.Direct(url), title, "From your server", name, p.resolution,
                p.tags + listOfNotNull(ext?.uppercase()), cached = true)
        }
        if (episode != null) {
            episode.xcEpisodeId?.let { add(client.episodeUrl(it, episode.ext ?: "mp4"), "${item.title} ${episode.code}", episode.ext) }
            return
        }
        if (item.origin.kind == "xc-movie") {
            add(client.movieUrl(item.origin.id, item.origin.ext ?: "mp4"), item.title, item.origin.ext)
        } else if (item.type == MediaType.MOVIE) {
            DispatcharrRepo.matchMovie(item.tmdbId, item.imdbId, item.title, item.year)?.let { add(client.movieUrl(it.id, it.ext), it.name, it.ext) }
        }
    }

    private fun make(s: Stream, index: Int, addonId: String, addonName: String): PlaybackSource? {
        val name = s.name ?: addonName
        val text = listOfNotNull(s.name, s.title, s.description, s.filename).joinToString(" ")
        val p = StreamText.parse(text)
        val lines = (s.title ?: s.description ?: "").split("\n")
        val kind: SourceKind = when {
            s.url != null -> SourceKind.Direct(s.url, s.headers)
            s.infoHash != null -> SourceKind.Torrent(TorrentSource(s.infoHash, s.fileIdx, s.filename, s.trackers, item.title, item.poster,
                episode?.season, episode?.episode, addonName))
            s.externalUrl != null -> SourceKind.External(s.externalUrl)
            else -> return null
        }
        return PlaybackSource(
            id = "$addonId:$index:${s.infoHash ?: s.url ?: ""}", kind = kind,
            title = lines.firstOrNull()?.takeIf { it.isNotBlank() } ?: name,
            detail = lines.drop(1).joinToString(" · ").ifBlank { null },
            provider = name.replace("\n", " "), resolution = p.resolution, tags = p.tags,
            size = s.videoSize ?: p.size, seeders = p.seeders, cached = p.cached, bingeGroup = s.bingeGroup,
            subtitles = s.subtitles, filename = s.filename,
        )
    }
}
