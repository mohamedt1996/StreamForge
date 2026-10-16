package com.mohamedt.streamforge.torrent

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import com.mohamedt.streamforge.core.Http
import com.mohamedt.streamforge.core.Store
import com.mohamedt.streamforge.player.PlaybackSource
import com.mohamedt.streamforge.player.SourceKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Predicts how long a source takes to start, and whether it plays without stalling, before connecting.
 *
 *   expected speed = min(connection ceiling, swarm speed from seeders)
 *   start time     = peer discovery + startup buffer ÷ expected speed
 *   smooth         = expected speed ≥ the file's bitrate (size ÷ runtime)
 *
 * The connection ceiling and the seeders → speed curve are learned from real playback, per network type
 * (and separately for a remote TorrServer, which downloads on its own connection).
 */
object StartEstimator {
    data class Estimate(
        val startSeconds: Double,
        val expectedSpeed: Double,
        val bitrate: Double,
        val rating: Rating,
        val mayBuffer: Boolean,
    ) {
        enum class Rating { INSTANT, FAST, OKAY, SLOW }
        val label: String
            get() = when {
                rating == Rating.INSTANT -> "Instant"
                startSeconds < 60 -> "~${max(startSeconds.toInt(), 2)}s"
                else -> "~${Math.round(startSeconds / 60)}m"
            }
    }

    /** Bumped on every change so Compose re-reads estimates. */
    var version by mutableIntStateOf(0); private set

    private val prefs get() = Store.prefs

    // MARK: Network

    fun linkType(): String {
        val cm = Store.context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return "wifi"
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return "wifi"
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "wired"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            else -> "other"
        }
    }

    /** Android's own downstream estimate, bytes/s (rough; often the Wi-Fi link rate, so it is discounted). */
    private fun systemHint(): Double? {
        val cm = Store.context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return null
        val kbps = cm.getNetworkCapabilities(cm.activeNetwork)?.linkDownstreamBandwidthKbps ?: return null
        return if (kbps > 0) kbps * 125.0 else null
    }

    fun profileKey(torrent: Boolean): String =
        if (torrent && !TorrServer.embedded) "remote-torrserver" else linkType()

    private fun defaultCapacity(key: String): Double {
        val base = when (key) {
            "wired" -> 12e6
            "cellular" -> 2.5e6
            "remote-torrserver" -> 10e6
            else -> 5e6
        }
        if (key == "remote-torrserver") return base
        val hint = systemHint() ?: return base
        return (hint * 0.4).coerceIn(0.4e6, base * 2)
    }

    fun capacity(key: String): Double? = prefs.getFloat("est.$key.capacity", -1f).takeIf { it > 0 }?.toDouble()
    fun sessions(key: String): Int = prefs.getInt("est.$key.sessions", 0)
    private fun swarmFactor(key: String): Double = prefs.getFloat("est.$key.factor", 1f).toDouble()

    private fun swarmSpeed(seeders: Int): Double = 180_000.0 * max(seeders, 1).toDouble().pow(0.8)

    private fun typicalBitrate(resolution: Int): Double = when {
        resolution >= 2160 -> 2.5e6
        resolution >= 1080 -> 0.75e6
        resolution >= 720 -> 0.35e6
        else -> 0.2e6
    }

    private fun rating(seconds: Double) = when {
        seconds < 12 -> Estimate.Rating.FAST
        seconds < 45 -> Estimate.Rating.OKAY
        else -> Estimate.Rating.SLOW
    }

    // MARK: Estimate

    fun estimate(src: PlaybackSource, runtimeMinutes: Int?, isEpisode: Boolean): Estimate? {
        val runtime = (runtimeMinutes ?: if (isEpisode) 45 else 115) * 60.0
        val bitrate = src.size?.let { it / runtime } ?: typicalBitrate(src.resolution)
        return when (src.kind) {
            is SourceKind.External -> null
            is SourceKind.Direct, is SourceKind.Recording -> {
                val key = profileKey(false)
                val cap = capacity(key) ?: defaultCapacity(key)
                val mayBuffer = cap * 0.85 < bitrate
                if (src.cached && !mayBuffer) Estimate(1.0, cap, bitrate, Estimate.Rating.INSTANT, false)
                else {
                    val start = 1.5 + (bitrate * 6 + 2e6) / max(cap * 0.85, 1.0)
                    Estimate(start, cap, bitrate, rating(start), mayBuffer)
                }
            }
            is SourceKind.Torrent -> {
                val key = profileKey(true)
                val cap = capacity(key) ?: defaultCapacity(key)
                val seeders = src.seeders ?: 8
                val expected = max(min(cap * 0.85, swarmSpeed(seeders) * swarmFactor(key)), 50_000.0)
                val discovery = when { seeders < 3 -> 20.0; seeders < 10 -> 9.0; seeders < 30 -> 5.0; else -> 3.0 }
                val start = discovery + (bitrate * 15 + 4e6) / expected
                Estimate(start, expected, bitrate, rating(start), expected < bitrate * 1.05)
            }
        }
    }

    fun fastestKey(src: PlaybackSource, runtimeMinutes: Int?, isEpisode: Boolean): Double {
        val e = estimate(src, runtimeMinutes, isEpisode) ?: return 1e9
        return e.startSeconds + (if (e.mayBuffer) 1e5 else 0.0) - src.resolution / 1e5
    }

    // MARK: Learning

    fun record(peakSpeed: Double, seeders: Int?, torrent: Boolean) {
        if (peakSpeed <= 20_000) return
        val key = profileKey(torrent)
        val old = capacity(key)
        val e = prefs.edit()
        e.putFloat("est.$key.capacity", max(peakSpeed, (old ?: 0.0) * 0.9).toFloat())
        if (torrent && seeders != null && seeders > 0) {
            val n = sessions(key)
            if (old == null || peakSpeed < old * 0.7) {
                val ratio = (peakSpeed / swarmSpeed(seeders)).coerceIn(0.15, 6.0)
                val f = if (n == 0) ratio else swarmFactor(key) * 0.7 + ratio * 0.3
                e.putFloat("est.$key.factor", f.toFloat())
            }
            e.putInt("est.$key.sessions", n + 1)
        }
        e.apply()
        version++
    }

    fun reset() {
        val e = prefs.edit()
        prefs.all.keys.filter { it.startsWith("est.") }.forEach { e.remove(it) }
        e.apply()
        version++
    }

    /** Downloads test data from Cloudflare's speed endpoint; stores the result as this network's ceiling. */
    suspend fun runSpeedTest(): Double? = withContext(Dispatchers.IO) {
        val client = Http.client.newBuilder().callTimeout(25, TimeUnit.SECONDS).build()
        var best: Double? = null
        for (bytes in listOf(2_000_000, 25_000_000)) {
            runCatching {
                val begin = System.nanoTime()
                client.newCall(Request.Builder().url("https://speed.cloudflare.com/__down?bytes=$bytes").build()).execute().use { r ->
                    val n = r.body.byteStream().use { input ->
                        val buf = ByteArray(64 * 1024); var total = 0L
                        while (true) { val read = input.read(buf); if (read < 0) break; total += read }
                        total
                    }
                    val secs = max((System.nanoTime() - begin) / 1e9, 0.05)
                    if (n > 0) best = max(best ?: 0.0, n / secs)
                }
            }
        }
        best?.let { b ->
            prefs.edit().putFloat("est.${profileKey(false)}.capacity", b.toFloat()).apply()
            withContext(Dispatchers.Main) { version++ }
        }
        best
    }
}

/** Best few-second average throughput during one playback session. */
class ThroughputTracker {
    private val window = ArrayDeque<Double>()
    var peak = 0.0; private set
    var samples = 0; private set

    fun add(bytesPerSecond: Double) {
        if (!bytesPerSecond.isFinite() || bytesPerSecond < 0) return
        samples++
        window.addLast(bytesPerSecond)
        if (window.size > 5) window.removeFirst()
        if (window.size == 5) peak = max(peak, window.sum() / 5)
    }
}
