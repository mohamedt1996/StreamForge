package com.mohamedt.streamforge.player

import android.content.Context
import android.content.Intent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.mohamedt.streamforge.PlayerActivity
import com.mohamedt.streamforge.core.Episode
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.Settings
import com.mohamedt.streamforge.dispatcharr.Channel
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.dispatcharr.GuideRepo
import com.mohamedt.streamforge.dispatcharr.Programme
import com.mohamedt.streamforge.dispatcharr.toItem
import com.mohamedt.streamforge.library.Library
import com.mohamedt.streamforge.metadata.IntroDb
import com.mohamedt.streamforge.stremio.Addons
import com.mohamedt.streamforge.stremio.Subtitle
import com.mohamedt.streamforge.torrent.TorrServer
import com.mohamedt.streamforge.torrent.TorrentContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

data class PlaybackRequest(
    val item: MediaItem,
    val episode: Episode? = null,
    val source: PlaybackSource,
    val startMs: Long? = null,
    val upcoming: List<Episode> = emptyList(),
    val channelId: Long? = null,
    val channelList: List<Channel> = emptyList(),
    val catchup: Programme? = null,
) {
    val isLive get() = channelId != null && catchup == null
}

/** Hands a request to PlayerActivity. */
object Player {
    var pending: PlaybackRequest? = null

    fun play(context: Context, request: PlaybackRequest) {
        // Addon "externalUrl" streams open in another app instead of failing inside the player.
        (request.source.kind as? SourceKind.External)?.let { ext ->
            runCatching {
                context.startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(ext.url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            return
        }
        pending = request
        context.startActivity(Intent(context, PlayerActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    fun playChannel(context: Context, channel: Channel, list: List<Channel>) {
        val server = DispatcharrRepo.active ?: return
        val client = DispatcharrRepo.client ?: return
        Library.recordChannel(channel.id)
        play(context, PlaybackRequest(channel.toItem(server.id),
            source = PlaybackSource("live:${channel.id}", SourceKind.Direct(client.liveUrl(channel.id)), channel.name, provider = server.name),
            channelId = channel.id, channelList = list.ifEmpty { DispatcharrRepo.channels }))
    }

    fun playCatchup(context: Context, channel: Channel, p: Programme) {
        val server = DispatcharrRepo.active ?: return
        val client = DispatcharrRepo.client ?: return
        play(context, PlaybackRequest(channel.toItem(server.id),
            source = PlaybackSource("catchup:${channel.id}:${p.start}", SourceKind.Direct(client.catchupUrl(channel.id, p.start, p.end)), p.title, provider = server.name),
            channelId = channel.id, catchup = p))
    }
}

data class SkipSegment(val kind: String, val start: Long, val end: Long) {
    val label get() = when (kind) { "intro" -> "Skip Intro"; "recap" -> "Skip Recap"; else -> "Skip Credits" }
}

/** Playback state + logic; the UI observes the Compose state fields. */
class PlayerController(private val context: Context, initial: PlaybackRequest) : MpvListener {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    val mpv = Mpv(context, this)

    var request by mutableStateOf(initial); private set
    var positionMs by mutableStateOf(0L); private set
    var durationMs by mutableStateOf(0L); private set
    var cachedMs by mutableStateOf(0L); private set
    var paused by mutableStateOf(false); private set
    var buffering by mutableStateOf(true); private set
    var started by mutableStateOf(false); private set
    var status by mutableStateOf<String?>(null); private set
    var error by mutableStateOf<String?>(null); private set
    var audioTracks by mutableStateOf<List<Track>>(emptyList()); private set
    var subtitleTracks by mutableStateOf<List<Track>>(emptyList()); private set
    var addonSubtitles by mutableStateOf<List<Subtitle>>(emptyList()); private set
    var chapters by mutableStateOf<List<Mpv.Chapter>>(emptyList()); private set
    var segments by mutableStateOf<List<SkipSegment>>(emptyList()); private set
    var nowProgramme by mutableStateOf<Programme?>(null); private set
    var nextProgramme by mutableStateOf<Programme?>(null); private set
    var subtitleDelay by mutableStateOf(0.0); private set
    var volume by mutableStateOf(100); private set
    var nightMode by mutableStateOf(Settings.values.nightMode); private set
    var toast by mutableStateOf<String?>(null); private set
    var numberEntry by mutableStateOf(""); private set

    private var torrentHash: String? = null
    private var lastSaved = 0L
    private var previousChannel: Long? = null
    private var autoSkipped = HashSet<String>()
    private var numberJob: Job? = null
    private var resolveJob: Job? = null
    /** Set when mpv reports START_FILE / FILE_LOADED for the current load; events from the replaced file are ignored. */
    private var fileStarted = false
    private var fileLoaded = false

    val isLive get() = request.isLive
    val title get() = request.catchup?.title ?: if (isLive) currentChannel?.name ?: request.item.title else request.item.title
    val subtitle: String?
        get() = request.episode?.let { "${it.code} · ${it.title}" } ?: if (isLive) nowProgramme?.title else request.item.year?.toString()
    val currentChannel: Channel? get() = request.channelId?.let { id -> request.channelList.firstOrNull { it.id == id } ?: DispatcharrRepo.channel(id) }
    val nextEpisode: Episode? get() = request.upcoming.firstOrNull()
    val activeSegment: SkipSegment? get() = segments.firstOrNull { positionMs in it.start until it.end - 1500 }
    val showNextCard: Boolean get() = Settings.values.autoplayNext && nextEpisode != null && durationMs > 300_000 && (durationMs - positionMs) in 1L..35_000L
    /** How far behind the live edge the timeshift buffer is playing. */
    val behindLiveMs: Long get() = if (isLive && cachedMs > 0) maxOf(0, cachedMs - positionMs - Settings.values.liveBufferSeconds * 1000L) else 0

    init {
        load(initial)
        scope.launch {
            while (isActive) {
                delay(1000)
                tick()
            }
        }
    }

    private fun load(r: PlaybackRequest) {
        request = r
        positionMs = 0; durationMs = 0; cachedMs = 0; started = false; buffering = true; error = null; status = null
        fileStarted = false; fileLoaded = false
        segments = emptyList(); addonSubtitles = emptyList(); autoSkipped.clear()
        resolveJob?.cancel()
        resolveJob = scope.launch {
            try {
                val (url, headers) = resolve(r.source)
                val start = r.startMs?.let { it / 1000.0 } ?: resume(r)
                mpv.load(url, start, headers, r.isLive, r.catchup?.title ?: r.item.title)
                if (r.isLive) refreshProgramme()
                loadSubtitles(r)
            } catch (e: Exception) {
                error = e.message ?: "Can't play this"
                buffering = false
            }
        }
    }

    private fun resume(r: PlaybackRequest): Double? {
        if (r.isLive || r.catchup != null) return null
        val p = Library.progress(r.item, r.episode) ?: return null
        return if (!p.finished && p.position > 30_000) (p.position - 5_000) / 1000.0 else null
    }

    private suspend fun resolve(source: PlaybackSource): Pair<String, Map<String, String>> = when (val k = source.kind) {
        is SourceKind.Direct -> k.url to k.headers
        is SourceKind.External -> throw IllegalStateException("This source opens outside the app")
        is SourceKind.Recording -> {
            val rest = DispatcharrRepo.restClient() ?: throw IllegalStateException("Sign in with your Dispatcharr account to play recordings.")
            rest.recordingUrl(k.id) to rest.recordingHeaders()
        }
        is SourceKind.Torrent -> {
            if (!TorrServer.configured) throw IllegalStateException("Torrent streaming needs a TorrServer. Set one in Settings → Torrents.")
            val (url, hash) = TorrServer.resolve(k.source) { status = it }
            torrentHash = hash
            TorrServer.contexts[hash] = TorrentContext(request.item.title, request.episode?.code, request.item.poster, k.source.addonName)
            url to TorrServer.authHeaders
        }
    }

    private suspend fun loadSubtitles(r: PlaybackRequest) {
        if (r.channelId != null) return
        val type = if (r.episode != null) "series" else "movie"
        val id = r.episode?.let { e -> e.stremioVideoId ?: r.item.imdbId?.let { "$it:${e.season}:${e.episode}" } } ?: r.item.stremioId ?: return
        val subs = r.source.subtitles + runCatching { Addons.subtitles(type, id, r.source.size, r.source.filename) }.getOrDefault(emptyList())
        val pref = Settings.values.subtitleLanguage
        addonSubtitles = subs.sortedWith(compareBy<Subtitle> { !it.lang.startsWith(pref) }.thenBy { it.lang })
    }

    private suspend fun loadSegments() {
        if (!Settings.values.skipIntros || isLive) return
        val r = request
        val found = mutableListOf<SkipSegment>()
        // Chapters named like intros/credits.
        for ((i, c) in chapters.withIndex()) {
            val name = c.title.lowercase()
            val end = chapters.getOrNull(i + 1)?.time ?: continue
            val kind = when {
                listOf("intro", "opening", " op", "theme").any { name.contains(it) } -> "intro"
                listOf("recap", "previously").any { name.contains(it) } -> "recap"
                listOf("credits", "ending", " ed", "outro").any { name.contains(it) } -> "credits"
                else -> null
            } ?: continue
            found += SkipSegment(kind, (c.time * 1000).toLong(), (end * 1000).toLong())
        }
        // Manual per-series marker.
        if (r.episode != null) Library.introMarker(r.item.id)?.let { (s, e) -> found += SkipSegment("intro", s, e) }
        // TheIntroDB.
        val remote = IntroDb.segments(r.item.tmdbId, r.item.imdbId, r.episode?.season, r.episode?.episode, durationMs.takeIf { it > 0 })
        for (s in remote) if (found.none { it.kind == s.kind }) found += SkipSegment(s.kind, s.start, s.end)
        segments = found
    }

    // MARK: Controls

    fun togglePause() { mpv.setFlag("pause", !paused) }

    fun seekTo(ms: Long) {
        if (isLive && !Settings.values.timeshiftMinutes.let { it > 0 }) return
        val target = if (durationMs > 0) ms.coerceIn(0, durationMs - 1000) else maxOf(0, ms)
        positionMs = target
        mpv.seek(target / 1000.0)
    }

    fun seekBy(deltaMs: Long) {
        if (isLive) { mpv.seek(deltaMs / 1000.0, relative = true); return }
        seekTo(positionMs + deltaMs)
    }

    fun goLive() { if (isLive) mpv.seek(maxOf(0.0, (cachedMs / 1000.0) - Settings.values.liveBufferSeconds)) }

    fun skipSegment() {
        val s = activeSegment ?: return
        if (s.kind == "credits" && nextEpisode != null) playNextEpisode() else seekTo(s.end)
    }

    fun markIntro(start: Boolean) {
        if (request.episode == null) return
        val existing = Library.introMarker(request.item.id)
        if (start) {
            Library.setIntroMarker(request.item.id, positionMs, existing?.second?.takeIf { it > positionMs } ?: (positionMs + 90_000))
            showToast("Intro start saved for this series")
        } else {
            Library.setIntroMarker(request.item.id, existing?.first ?: maxOf(0, positionMs - 90_000), positionMs)
            showToast("Intro end saved for this series")
        }
        scope.launch { loadSegments() }
    }

    fun selectAudio(t: Track) { mpv.set("aid", t.id.toString()); refreshTracks() }
    fun selectSubtitle(t: Track?) { mpv.set("sid", t?.id?.toString() ?: "no"); refreshTracks() }
    fun loadAddonSubtitle(s: Subtitle) { mpv.command("sub-add", s.url, "select", s.lang, s.lang); scope.launch { delay(800); refreshTracks() } }
    fun changeSubtitleDelay(delta: Double) { subtitleDelay += delta; mpv.setDouble("sub-delay", subtitleDelay) }
    fun changeVolume(delta: Int) { volume = (volume + delta).coerceIn(0, 200); mpv.set("volume", volume.toString()); showToast("Volume $volume%") }
    fun toggleNightMode() {
        nightMode = !nightMode
        mpv.setNightMode(nightMode)
        Settings.update { it.copy(nightMode = nightMode) }
        showToast(if (nightMode) "Night mode on" else "Night mode off")
    }

    fun retry() { load(request) }

    /** A new request while the (singleTask) player is already open, e.g. from PiP. */
    fun open(r: PlaybackRequest) {
        saveProgress(force = true)
        val old = torrentHash
        val newHash = (r.source.kind as? SourceKind.Torrent)?.source?.infoHash
        if (old != null && old != newHash) {
            torrentHash = null
            CoroutineScope(Dispatchers.IO).launch { runCatching { TorrServer.drop(old) } }
        }
        previousChannel = null
        if (paused) mpv.setFlag("pause", false)
        load(r)
    }

    /** Leaving the player without PiP (Home on TV, screen off): don't keep playing audio in the background. */
    fun pauseForBackground() { if (!paused) mpv.setFlag("pause", true) }

    // MARK: Live TV

    private val channelIndex: Int? get() = request.channelId?.let { id -> request.channelList.indexOfFirst { it.id == id }.takeIf { it >= 0 } }

    fun zap(offset: Int) {
        val list = request.channelList
        val i = channelIndex ?: return
        if (list.isEmpty()) return
        switchChannel(list[(i + offset + list.size) % list.size])
    }

    fun switchChannel(channel: Channel) {
        val server = DispatcharrRepo.active ?: return
        val client = DispatcharrRepo.client ?: return
        previousChannel = request.channelId
        Library.recordChannel(channel.id)
        load(request.copy(item = channel.toItem(server.id), channelId = channel.id, catchup = null, startMs = null,
            source = PlaybackSource("live:${channel.id}", SourceKind.Direct(client.liveUrl(channel.id)), channel.name, provider = server.name)))
    }

    fun lastChannel() {
        val id = previousChannel ?: Library.lastChannel ?: return
        val ch = request.channelList.firstOrNull { it.id == id } ?: DispatcharrRepo.channel(id) ?: return
        switchChannel(ch)
    }

    /** Digits from a remote / keyboard: tune after a short pause. */
    fun typeDigit(d: Int) {
        if (!isLive) return
        numberEntry = (numberEntry + d).take(5)
        numberJob?.cancel()
        numberJob = scope.launch {
            delay(1500)
            val n = numberEntry.toIntOrNull()
            numberEntry = ""
            val ch = DispatcharrRepo.channels.firstOrNull { it.number == n }
            if (ch != null) switchChannel(ch) else showToast("No channel $n")
        }
    }

    private suspend fun refreshProgramme() {
        val ch = currentChannel ?: return
        GuideRepo.ensure(ch)
        nowProgramme = GuideRepo.now(ch)
        nextProgramme = GuideRepo.next(ch)
    }

    // MARK: Episodes

    fun playNextEpisode() {
        val next = request.upcoming.firstOrNull() ?: return
        saveProgress(force = true)
        scope.launch {
            status = "Finding ${next.code}…"
            buffering = true
            val sources = SourcesModel(request.item, next)
            sources.load()
            val prev = request.source
            val pick = sources.sorted.firstOrNull { it.bingeGroup != null && it.bingeGroup == prev.bingeGroup }
                ?: sources.sorted.firstOrNull { it.provider == prev.provider && it.resolution == prev.resolution }
                ?: sources.sorted.firstOrNull()
            if (pick == null) { error = "No source found for ${next.code}"; buffering = false; return@launch }
            load(request.copy(episode = next, source = pick, startMs = null, upcoming = request.upcoming.drop(1)))
        }
    }

    // MARK: mpv events

    override fun onProperty(name: String, value: Any?) {
        when (name) {
            "time-pos" -> if (fileLoaded) (value as? Double)?.let { positionMs = (it * 1000).toLong(); if (it > 0.3 && !started) onStarted() }
            "duration" -> durationMs = ((value as? Double) ?: 0.0).times(1000).toLong()
            "pause" -> paused = value as? Boolean ?: false
            "paused-for-cache" -> buffering = value as? Boolean ?: false
            "core-idle" -> if (value == false && started) buffering = false
            "demuxer-cache-time" -> cachedMs = ((value as? Double) ?: 0.0).times(1000).toLong()
            "eof-reached" -> if (value == true) onEnded()
            "track-list" -> refreshTracks()
            "chapter-list" -> { chapters = mpv.chapters(); scope.launch { loadSegments() } }
        }
    }

    override fun onEvent(id: Int) {
        when (id) {
            Mpv.EVENT_START_FILE -> fileStarted = true
            Mpv.EVENT_FILE_LOADED -> { fileLoaded = true; status = null; error = null; refreshTracks(); chapters = mpv.chapters() }
            // END_FILE of the file being replaced (channel zap, next episode) arrives before START_FILE of the new one: ignore it.
            Mpv.EVENT_END_FILE -> if (fileStarted && !started && error == null) {
                val failed = request
                scope.launch {
                    delay(1500)
                    if (!started && request === failed) { error = if (isLive) "The channel isn't responding." else "Playback failed."; buffering = false }
                }
            }
        }
    }

    private fun onStarted() {
        started = true
        buffering = false
        status = null
        scope.launch { loadSegments() }
    }

    private fun onEnded() {
        if (isLive) return
        saveProgress(force = true)
        if (Settings.values.autoplayNext && nextEpisode != null) playNextEpisode()
    }

    private fun refreshTracks() {
        val all = mpv.tracks()
        audioTracks = all.filter { it.type == "audio" }
        subtitleTracks = all.filter { it.type == "sub" }
    }

    private suspend fun tick() {
        saveProgress(force = false)
        activeSegment?.let { s ->
            if (Settings.values.autoSkip && s.kind != "credits" && autoSkipped.add("${s.kind}${s.start}")) {
                seekTo(s.end)
                showToast(s.label.replace("Skip", "Skipped"))
            }
        }
        torrentHash?.let { h ->
            if (buffering && !started) runCatching { TorrServer.status(h) }.getOrNull()?.let {
                status = "Buffering · ${it.activePeers} peers · ${(it.downloadSpeed / 1024 / 1024).let { s -> "%.1f".format(s) }} MB/s"
            }
        }
        if (isLive) nowProgramme?.let { if (it.end < System.currentTimeMillis()) refreshProgramme() }
    }

    fun saveProgress(force: Boolean) {
        if (!started || isLive || durationMs <= 0) return
        if (!force && kotlin.math.abs(positionMs - lastSaved) < 10_000) return
        lastSaved = positionMs
        Library.updateProgress(request.item, request.episode, positionMs, durationMs)
    }

    fun showToast(text: String) {
        toast = text
        scope.launch { delay(1800); if (toast == text) toast = null }
    }

    fun release() {
        saveProgress(force = true)
        torrentHash?.let { h -> CoroutineScope(Dispatchers.IO).launch { TorrServer.drop(h) } }
        scope.cancel()
        mpv.destroy()
    }
}
