package com.mohamedt.streamforge.player

import android.content.Context
import android.content.Intent
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.mohamedt.streamforge.PlayerActivity
import com.mohamedt.streamforge.core.Episode
import com.mohamedt.streamforge.core.Http
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
import kotlinx.coroutines.CancellationException
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
        val url = client.liveUrl(channel.id) ?: return
        Library.recordChannel(channel.id)
        play(context, PlaybackRequest(channel.toItem(server.id),
            source = PlaybackSource("live:${channel.id}", SourceKind.Direct(url), channel.name, provider = server.name),
            channelId = channel.id, channelList = list.ifEmpty { DispatcharrRepo.channels }))
    }

    fun playCatchup(context: Context, channel: Channel, p: Programme) {
        val server = DispatcharrRepo.active ?: return
        val client = DispatcharrRepo.client ?: return
        val url = client.catchupUrl(channel.id, p.start, p.end) ?: return
        play(context, PlaybackRequest(channel.toItem(server.id),
            source = PlaybackSource("catchup:${channel.id}:${p.start}", SourceKind.Direct(url), p.title, provider = server.name),
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
    /** Real throughput of this session, fed back into StartEstimator so estimates learn this network. */
    private var throughput = com.mohamedt.streamforge.torrent.ThroughputTracker()
    private var throughputContext: Pair<Boolean, Int?>? = null

    private fun flushThroughput() {
        val ctx = throughputContext
        if (ctx != null && throughput.samples >= 8) {
            com.mohamedt.streamforge.torrent.StartEstimator.record(throughput.peak, ctx.second, ctx.first)
        }
        throughput = com.mohamedt.streamforge.torrent.ThroughputTracker()
        throughputContext = null
    }
    private var lastSaved = 0L
    private var previousChannel: Long? = null
    private var autoSkipped = HashSet<String>()
    private var numberJob: Job? = null
    private var resolveJob: Job? = null
    /** Set when mpv reports START_FILE / FILE_LOADED for the current load; events from the replaced file are ignored. */
    private var fileStarted = false
    private var fileLoaded = false

    // Recovery after the app was in the background / the stream dropped. While away, mpv's HTTP
    // connections time out, live streams hit EOF and TorrServer may drop the torrent (or the engine may
    // be gone): instead of "Can't play", the source is re-resolved (torrent re-added, fresh headers) and
    // reloaded at the last position, or a live channel is re-tuned, behind the buffering UI.
    private var inBackground = false
    private var backgroundedAt = 0L
    /** Set when the player leaves the screen; cleared after a stretch of healthy playback. While set,
     *  load failures, errors and stalls are retried instead of shown. */
    private var unhealthySinceBackground = false
    private var lastProgressAt = SystemClock.elapsedRealtime()
    private var lastProgressPos = -1L
    private var healthyTicks = 0
    private var recoveryAttempts = 0
    private var recoveryJob: Job? = null
    private var foregroundJob: Job? = null
    private var lastFailure: String? = null
    /** Bumped by every [load], so work started for an older load never touches a newer one. */
    private var loadGeneration = 0
    private var resolving = false
    /** What the user asked for (mpv's own pause also flips at keep-open EOF and when leaving the app). */
    private var userPaused = false
    /** mpv was paused because the player left the screen (Home on TV, screen off). */
    private var pausedForBackground = false

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
        loadGeneration++
        val generation = loadGeneration
        recoveryJob?.cancel(); recoveryJob = null
        recoveryAttempts = 0; lastFailure = null
        lastProgressAt = SystemClock.elapsedRealtime(); lastProgressPos = -1
        // New content always plays: mpv keeps `pause` across loadfile (and keep-open pauses at EOF).
        userPaused = false; pausedForBackground = false
        mpv.setFlag("pause", false)
        resolveJob?.cancel()
        resolving = true
        resolveJob = scope.launch {
            try {
                val (url, headers) = resolve(r.source)
                if (generation != loadGeneration) return@launch
                val start = r.startMs?.let { it / 1000.0 } ?: resume(r)
                lastProgressAt = SystemClock.elapsedRealtime()
                mpv.load(url, start, headers, r.isLive, r.catchup?.title ?: r.item.title)
                resolving = false
                if (r.isLive) refreshProgramme()
                loadSubtitles(r)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // A newer load owns the state now; and a failure after mpv.load (guide, subtitles) isn't a playback error.
                if (generation != loadGeneration || !resolving) return@launch
                resolving = false
                val message = e.message ?: "Can't play this"
                lastFailure = message
                if (unhealthySinceBackground) {
                    // E.g. the player left the screen while the torrent was still being fetched.
                    scheduleRecovery(message)
                } else {
                    error = message
                    buffering = false
                }
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

    fun togglePause() { setPausedByUser(!paused) }

    /** Pause/play on the user's behalf (controls, remote keys). */
    fun setPausedByUser(pause: Boolean) {
        userPaused = pause
        pausedForBackground = false
        // Paused time is not a stall.
        lastProgressAt = SystemClock.elapsedRealtime()
        mpv.setFlag("pause", pause)
    }

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

    fun retry() {
        if (started) {
            // Pick up where playback stopped (re-resolving the source), not from the original start.
            recoveryJob?.cancel(); recoveryJob = null
            recoveryAttempts = 0
            error = null
            scheduleRecovery("retry", delayMs = 0)
        } else {
            load(request)
        }
    }

    /** A new request while the (singleTask) player is already open, e.g. from PiP. */
    fun open(r: PlaybackRequest) {
        saveProgress(force = true)
        flushThroughput()
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
    fun pauseForBackground() {
        inBackground = true
        backgroundedAt = SystemClock.elapsedRealtime()
        unhealthySinceBackground = true
        healthyTicks = 0
        foregroundJob?.cancel()
        if (!paused) {
            pausedForBackground = true
            mpv.setFlag("pause", true)
        }
    }

    /**
     * The player is on screen again (PlayerActivity.onStart). It stays paused if it was paused for the
     * background, but anything that failed meanwhile (error, unloaded file, stream ran dry) is reloaded
     * now, and a torrent's engine/torrent are revived, so pressing Play works.
     */
    fun onForeground() {
        if (!inBackground) return
        inBackground = false
        val away = SystemClock.elapsedRealtime() - backgroundedAt
        lastProgressAt = SystemClock.elapsedRealtime()
        foregroundJob?.cancel()
        foregroundJob = scope.launch {
            // Let the surface come back and mpv report its state.
            delay(1500)
            foregroundCheck(away)
        }
    }

    private suspend fun foregroundCheck(away: Long) {
        if (recoveryJob != null || resolving || mpv.destroyed) return
        val eof = mpv.flag("eof-reached")
        val nearEnd = durationMs > 0 && positionMs >= durationMs - 20_000
        if (error != null || (fileStarted && mpv.flag("idle-active")) || (eof && (isLive || !nearEnd))) {
            recoveryAttempts = 0
            scheduleRecovery(lastFailure ?: "returned from the background", delayMs = 0)
            return
        }
        val torrent = request.source.kind as? SourceKind.Torrent ?: return
        if (away < 3_000) return
        // The engine may have died or dropped the torrent meanwhile: revive it and re-add the torrent with
        // its trackers before mpv reconnects to /stream by hash alone.
        val generation = loadGeneration
        val health = TorrServer.ensureRunning()
        if (generation != loadGeneration || recoveryJob != null) return
        if (health.restarted || !health.reachable) {
            scheduleRecovery(TorrServer.lastError ?: "the torrent engine restarted", delayMs = 0)
        } else {
            runCatching { TorrServer.add(torrent.source) }
        }
    }

    /** Watches for a stall after a background trip and resets the retry budget once playback is healthy. */
    private fun trackHealth() {
        val now = SystemClock.elapsedRealtime()
        val progressing = now - lastProgressAt < 2_500
        if (progressing && !paused) {
            healthyTicks++
            if (healthyTicks >= 20) {
                recoveryAttempts = 0
                lastFailure = null
                if (!inBackground) unhealthySinceBackground = false
            }
        } else if (!paused) {
            healthyTicks = 0
        }
        if (!unhealthySinceBackground || inBackground || recoveryJob != null || resolving || userPaused || pausedForBackground ||
            error != null || !fileStarted || !(started || isLive)) return
        val limit = if (isLive) 15_000L else if (torrentHash != null) 30_000L else 20_000L
        if (now - lastProgressAt > limit) scheduleRecovery("playback stalled")
    }

    /**
     * Reloads the current source behind the buffering UI: VOD/torrent/catch-up at the last position
     * (re-resolved: torrent re-added, fresh headers), live channels re-tuned at the live edge (the
     * timeshift buffer starts over). Keeps the pause state. After [MAX_RECOVERY_ATTEMPTS] failures in a
     * row the error is shown.
     */
    private fun scheduleRecovery(reason: String, delayMs: Long? = null) {
        if (recoveryJob != null || mpv.destroyed) return
        recoveryAttempts++
        if (recoveryAttempts > MAX_RECOVERY_ATTEMPTS) {
            buffering = false
            status = null
            error = lastFailure ?: if (isLive) "The channel isn't responding." else "Playback stopped: $reason"
            return
        }
        val attempt = recoveryAttempts
        val wait = delayMs ?: longArrayOf(500L, 2_000L, 5_000L)[minOf(attempt - 1, 2)]
        val r = request
        val generation = loadGeneration
        val resumeAt: Double? = when {
            r.isLive -> null
            started -> maxOf(0L, positionMs - 2_000L) / 1000.0
            else -> r.startMs?.let { it / 1000.0 } ?: resume(r)
        }
        val stayPaused = userPaused || pausedForBackground
        error = null
        buffering = true
        status = if (attempt == 1) "Reconnecting…" else "Reconnecting… (try $attempt of $MAX_RECOVERY_ATTEMPTS)"
        recoveryJob = scope.launch {
            try {
                if (wait > 0) delay(wait)
                if (generation != loadGeneration) return@launch
                // Pooled connections may have died while the app was away.
                Http.evictIdleConnections()
                var source = r.source
                val channelId = r.channelId
                if (r.isLive && channelId != null) {
                    DispatcharrRepo.client?.liveUrl(channelId)?.let { source = source.copy(kind = SourceKind.Direct(it)) }
                }
                val (url, headers) = resolve(source)
                if (generation != loadGeneration) return@launch
                // Events of the file being replaced must not count for the new one.
                fileStarted = false; fileLoaded = false
                lastProgressAt = SystemClock.elapsedRealtime(); lastProgressPos = -1; healthyTicks = 0
                recoveryJob = null
                mpv.setFlag("pause", stayPaused)
                mpv.load(url, resumeAt, headers, r.isLive, r.catchup?.title ?: r.item.title)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (generation != loadGeneration) return@launch
                lastFailure = e.message ?: "Can't play this"
                recoveryJob = null
                scheduleRecovery(lastFailure ?: reason)
            }
        }
    }

    /** keep-open reports EOF both at the real end and when the connection died mid-file. */
    private fun handleEndOfStream() {
        if (recoveryJob != null || !fileLoaded) return
        if (isLive) {
            // Live streams don't end: the connection was cut. Re-tune.
            scheduleRecovery("stream ended")
            return
        }
        val reachedEnd = if (durationMs <= 0) started else positionMs >= durationMs - 20_000
        if (reachedEnd) onEnded() else scheduleRecovery("the stream was interrupted")
    }

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
        val url = client.liveUrl(channel.id) ?: return
        previousChannel = request.channelId
        Library.recordChannel(channel.id)
        load(request.copy(item = channel.toItem(server.id), channelId = channel.id, catchup = null, startMs = null,
            source = PlaybackSource("live:${channel.id}", SourceKind.Direct(url), channel.name, provider = server.name)))
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
            "time-pos" -> if (fileLoaded) (value as? Double)?.let {
                positionMs = (it * 1000).toLong()
                if (kotlin.math.abs(positionMs - lastProgressPos) > 50) {
                    lastProgressPos = positionMs
                    lastProgressAt = SystemClock.elapsedRealtime()
                }
                if (it > 0.3 && !started) onStarted()
            }
            "duration" -> durationMs = ((value as? Double) ?: 0.0).times(1000).toLong()
            "pause" -> paused = value as? Boolean ?: false
            "paused-for-cache" -> buffering = value as? Boolean ?: false
            "core-idle" -> if (value == false && started) buffering = false
            "demuxer-cache-time" -> cachedMs = ((value as? Double) ?: 0.0).times(1000).toLong()
            "eof-reached" -> if (value == true) handleEndOfStream()
            "track-list" -> refreshTracks()
            "chapter-list" -> { chapters = mpv.chapters(); scope.launch { loadSegments() } }
        }
    }

    override fun onEvent(id: Int) {
        when (id) {
            Mpv.EVENT_START_FILE -> fileStarted = true
            Mpv.EVENT_FILE_LOADED -> {
                fileLoaded = true; status = null; error = null; refreshTracks(); chapters = mpv.chapters()
                // A recovery reload that stays paused never reports "playing": drop the spinner here.
                if (started && (userPaused || pausedForBackground)) buffering = false
            }
            // END_FILE of the file being replaced (channel zap, next episode) arrives before START_FILE of the new one: ignore it.
            Mpv.EVENT_END_FILE -> if (fileStarted && recoveryJob == null && error == null) {
                if (started || unhealthySinceBackground) {
                    // Failed mid-playback or right after a background trip (dead connection): retry with
                    // backoff before showing anything. keep-open means a normal end never sends END_FILE.
                    lastFailure = if (isLive) "The channel isn't responding." else "Playback failed."
                    scheduleRecovery("playback failed")
                } else {
                    val failed = request
                    scope.launch {
                        delay(1500)
                        if (!started && request === failed && recoveryJob == null) {
                            error = if (isLive) "The channel isn't responding." else "Playback failed."; buffering = false
                        }
                    }
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
        trackHealth()
        activeSegment?.let { s ->
            if (Settings.values.autoSkip && s.kind != "credits" && autoSkipped.add("${s.kind}${s.start}")) {
                seekTo(s.end)
                showToast(s.label.replace("Skip", "Skipped"))
            }
        }
        val hash = torrentHash
        if (hash != null) {
            runCatching { TorrServer.status(hash) }.getOrNull()?.let {
                if (buffering && !started) status = "Buffering · ${it.activePeers} peers · ${(it.downloadSpeed / 1024 / 1024).let { s -> "%.1f".format(s) }} MB/s"
                if (!isLive) {
                    throughputContext = true to (request.source.seeders ?: it.seeders)
                    throughput.add(it.downloadSpeed)
                }
            }
        } else if (!isLive && !paused && request.source.kind is SourceKind.Direct && throughput.samples < 40) {
            // Only the first seconds count: once mpv's cache is full it stops reading at full speed.
            mpv.double("cache-speed")?.let { throughputContext = false to null; throughput.add(it) }
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
        flushThroughput()
        torrentHash?.let { h -> CoroutineScope(Dispatchers.IO).launch { TorrServer.drop(h) } }
        scope.cancel()
        mpv.destroy()
    }

    private companion object {
        const val MAX_RECOVERY_ATTEMPTS = 3
    }
}
