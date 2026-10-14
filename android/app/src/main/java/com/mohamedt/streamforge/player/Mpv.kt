package com.mohamedt.streamforge.player

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.Surface
import com.mohamedt.streamforge.core.Settings
import dev.jdtech.mpv.MPVLib
import dev.jdtech.mpv.MPVLib.MpvEvent
import dev.jdtech.mpv.MPVLib.MpvFormat
import java.io.File
import org.json.JSONArray

data class Track(val id: Int, val type: String, val title: String?, val lang: String?, val codec: String?, val selected: Boolean, val external: Boolean, val channels: Int?) {
    val label: String
        get() {
            val language = lang?.let { java.util.Locale.forLanguageTag(it).displayLanguage.takeIf { d -> d.isNotBlank() && d != it } ?: it.uppercase() }
            val parts = listOfNotNull(language, title?.takeIf { it.isNotBlank() && !it.equals(lang, true) })
            val extra = listOfNotNull(codec?.uppercase(), channels?.let { c -> when (c) { 6 -> "5.1"; 8 -> "7.1"; else -> "${c}ch" } }, if (external) "External" else null)
            return (parts.ifEmpty { listOf("Track $id") }).joinToString(" · ") + if (extra.isEmpty()) "" else "  (${extra.joinToString(", ")})"
        }
}

interface MpvListener {
    fun onProperty(name: String, value: Any?)
    fun onEvent(id: Int)
}

/** Thin wrapper over libmpv (dev.jdtech.mpv) with the options StreamForge uses everywhere. */
class Mpv(context: Context, private val listener: MpvListener) : MPVLib.EventObserver {
    private val lib: MPVLib = MPVLib.create(context) ?: throw IllegalStateException("libmpv failed to start")
    private val main = Handler(Looper.getMainLooper())
    var destroyed = false
        private set

    init {
        val config = File(context.filesDir, "mpv").apply { mkdirs() }
        val cache = File(context.cacheDir, "mpv").apply { mkdirs() }
        val s = Settings.values
        val opts = listOf(
            "config" to "yes", "config-dir" to config.path, "gpu-shader-cache-dir" to cache.path,
            "vo" to "gpu-next", "gpu-context" to "android", "opengl-es" to "yes", "ao" to "audiotrack,opensles",
            "hwdec" to s.hwdec, "hwdec-codecs" to "h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1",
            "tls-verify" to "no", "cache" to "yes", "demuxer-max-bytes" to "${s.cacheMb}MiB",
            "demuxer-max-back-bytes" to "${maxOf(32, s.cacheMb / 3)}MiB", "network-timeout" to "30",
            "stream-lavf-o" to "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=6",
            "keep-open" to "yes", "force-window" to "no", "ytdl" to "no", "hr-seek" to "yes",
            "alang" to "${s.audioLanguage},eng,en", "slang" to "${s.subtitleLanguage},eng,en",
            "sid" to if (s.autoSubtitles) "auto" else "no", "sub-auto" to "fuzzy",
            "volume-max" to "200", "user-agent" to s.userAgent.ifEmpty { "StreamForge/1.0 (Android; mpv)" },
            "sub-scale-with-window" to "yes", "sub-use-margins" to "no",
        )
        for ((k, v) in opts) lib.setOptionString(k, v)
        lib.init()
        lib.addObserver(this)
        for ((name, fmt) in listOf(
            "time-pos" to MpvFormat.MPV_FORMAT_DOUBLE, "duration" to MpvFormat.MPV_FORMAT_DOUBLE,
            "pause" to MpvFormat.MPV_FORMAT_FLAG, "paused-for-cache" to MpvFormat.MPV_FORMAT_FLAG,
            "eof-reached" to MpvFormat.MPV_FORMAT_FLAG, "demuxer-cache-time" to MpvFormat.MPV_FORMAT_DOUBLE,
            "cache-buffering-state" to MpvFormat.MPV_FORMAT_INT64, "track-list" to MpvFormat.MPV_FORMAT_STRING,
            "core-idle" to MpvFormat.MPV_FORMAT_FLAG, "chapter-list" to MpvFormat.MPV_FORMAT_STRING,
        )) lib.observeProperty(name, fmt)
        applySubtitleStyle()
        setNightMode(s.nightMode)
    }

    fun attach(surface: Surface) {
        if (destroyed) return
        lib.attachSurface(surface)
        lib.setOptionString("force-window", "yes")
        lib.setOptionString("vo", "gpu-next")
    }

    fun detach() {
        if (destroyed) return
        lib.setOptionString("vo", "null")
        lib.setOptionString("force-window", "no")
        lib.detachSurface()
    }
    fun setSurfaceSize(w: Int, h: Int) { if (!destroyed) lib.setPropertyString("android-surface-size", "${w}x$h") }

    fun load(url: String, start: Double? = null, headers: Map<String, String> = emptyMap(), live: Boolean = false, title: String? = null) {
        if (destroyed) return
        val s = Settings.values
        lib.setPropertyString("http-header-fields", headers.entries.joinToString(",") { "${it.key}: ${it.value}" })
        lib.setPropertyString("start", start?.let { "%.2f".format(java.util.Locale.US, it) } ?: "none")
        lib.setPropertyString("force-media-title", title ?: "")
        if (live) {
            // Timeshift: keep a rewindable buffer of the live stream.
            val mb = maxOf(64, s.timeshiftMinutes * 6)
            lib.setPropertyString("demuxer-max-back-bytes", "${mb}MiB")
            lib.setPropertyString("demuxer-max-bytes", "${maxOf(64, s.cacheMb)}MiB")
            lib.setPropertyString("demuxer-seekable-cache", "yes")
            lib.setPropertyString("force-seekable", "yes")
            lib.setPropertyString("cache-pause-initial", "yes")
            lib.setPropertyString("cache-pause-wait", s.liveBufferSeconds.toString())
            lib.setPropertyString("demuxer-readahead-secs", "${s.timeshiftMinutes * 60}")
        } else {
            lib.setPropertyString("demuxer-max-back-bytes", "${maxOf(32, s.cacheMb / 3)}MiB")
            lib.setPropertyString("cache-pause-initial", "no")
            lib.setPropertyString("demuxer-readahead-secs", "30")
        }
        command("loadfile", url, "replace")
    }

    fun command(vararg args: String) { if (!destroyed) lib.command(arrayOf(*args)) }
    fun set(name: String, value: String) { if (!destroyed) lib.setPropertyString(name, value) }
    fun setFlag(name: String, value: Boolean) { if (!destroyed) lib.setPropertyBoolean(name, value) }
    fun setDouble(name: String, value: Double) { if (!destroyed) lib.setPropertyDouble(name, value) }
    fun string(name: String): String? = if (destroyed) null else lib.getPropertyString(name)
    fun double(name: String): Double? = if (destroyed) null else lib.getPropertyDouble(name)
    fun int(name: String): Int? = if (destroyed) null else lib.getPropertyInt(name)
    fun flag(name: String): Boolean = if (destroyed) false else lib.getPropertyBoolean(name) ?: false

    fun seek(seconds: Double, relative: Boolean = false) = command("seek", "%.3f".format(java.util.Locale.US, seconds), if (relative) "relative" else "absolute+exact")

    fun tracks(): List<Track> {
        val json = string("track-list") ?: return emptyList()
        return runCatching {
            val arr = JSONArray(json)
            (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                Track(o.optInt("id"), o.optString("type"), o.optString("title").takeIf { it.isNotEmpty() },
                    o.optString("lang").takeIf { it.isNotEmpty() }, o.optString("codec").takeIf { it.isNotEmpty() },
                    o.optBoolean("selected"), o.optBoolean("external"), o.optInt("demux-channel-count").takeIf { it > 0 })
            }
        }.getOrDefault(emptyList())
    }

    data class Chapter(val title: String, val time: Double)

    fun chapters(): List<Chapter> {
        val json = string("chapter-list") ?: return emptyList()
        return runCatching {
            val arr = JSONArray(json)
            (0 until arr.length()).map { i -> arr.getJSONObject(i).let { Chapter(it.optString("title", "Chapter ${i + 1}"), it.optDouble("time")) } }
        }.getOrDefault(emptyList())
    }

    fun applySubtitleStyle() {
        val s = Settings.values
        set("sub-scale", "%.2f".format(java.util.Locale.US, s.subtitleScale))
        set("sub-color", s.subtitleColor)
        set("sub-bold", if (s.subtitleBold) "yes" else "no")
        set("sub-pos", s.subtitlePosition.toString())
        if (s.subtitleBackground) {
            set("sub-border-style", "background-box")
            set("sub-back-color", "#99000000")
        } else {
            set("sub-border-style", "outline-and-shadow")
            set("sub-border-size", "2.5")
            set("sub-border-color", "#FF000000")
        }
    }

    /** Night mode: compress dynamics so dialogue is audible without loud peaks. */
    fun setNightMode(on: Boolean) {
        set("af", if (on) "lavfi=[acompressor=threshold=0.089:ratio=4:attack=5:release=50:makeup=2],lavfi=[dynaudnorm=f=150:g=15]" else "")
    }

    fun destroy() {
        if (destroyed) return
        destroyed = true
        lib.removeObserver(this)
        lib.destroy()
    }

    // MPVLib.EventObserver — called on mpv's thread; forward to main.
    override fun eventProperty(property: String) { main.post { listener.onProperty(property, null) } }
    override fun eventProperty(property: String, value: Long) { main.post { listener.onProperty(property, value) } }
    override fun eventProperty(property: String, value: Double) { main.post { listener.onProperty(property, value) } }
    override fun eventProperty(property: String, value: Boolean) { main.post { listener.onProperty(property, value) } }
    override fun eventProperty(property: String, value: String) { main.post { listener.onProperty(property, value) } }
    override fun event(eventId: Int) { main.post { listener.onEvent(eventId) } }

    companion object {
        const val EVENT_FILE_LOADED = MpvEvent.MPV_EVENT_FILE_LOADED
        const val EVENT_END_FILE = MpvEvent.MPV_EVENT_END_FILE
        const val EVENT_PLAYBACK_RESTART = MpvEvent.MPV_EVENT_PLAYBACK_RESTART
    }
}
