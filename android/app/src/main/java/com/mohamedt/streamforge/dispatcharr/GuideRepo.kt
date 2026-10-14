package com.mohamedt.streamforge.dispatcharr

import android.util.Xml
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.mohamedt.streamforge.core.Http
import com.mohamedt.streamforge.core.Settings
import com.mohamedt.streamforge.core.Store
import java.io.File
import java.util.Calendar
import java.util.TimeZone
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import org.xmlpull.v1.XmlPullParser

/**
 * The full TV guide: Dispatcharr's XMLTV export (xmltv.php) downloaded, parsed in a streaming
 * pull parser, cached on disk and refreshed every few hours. XMLTV channel ids are Dispatcharr
 * channel numbers, which match the XC `epg_channel_id`.
 */
object GuideRepo {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    var programmes by mutableStateOf<Map<String, List<Programme>>>(emptyMap()); private set
    var updatedAt by mutableStateOf(Store.prefs.getLong("guide.updated", 0L)); private set
    var refreshing by mutableStateOf(false); private set
    var lastError by mutableStateOf<String?>(null); private set
    var programmeCount by mutableStateOf(0); private set

    private val fallback = HashMap<Long, Pair<Long, List<Programme>>>()
    private var refreshJob: Job? = null
    private val serializer = MapSerializer(String.serializer(), ListSerializer(Programme.serializer()))

    fun init() {
        scope.launch {
            val loaded = withContext(Dispatchers.IO) { Store.load(serializer, "guide-cache.json") }
            if (loaded != null && programmes.isEmpty()) setProgrammes(loaded)
        }
    }

    private fun setProgrammes(map: Map<String, List<Programme>>) {
        programmes = map
        programmeCount = map.values.sumOf { it.size }
    }

    private fun key(channel: Channel): String = channel.epgId?.takeIf { it.isNotEmpty() } ?: channel.number?.toString() ?: channel.id.toString()

    fun forChannel(channel: Channel): List<Programme> {
        programmes[key(channel)]?.let { return it }
        programmes[channel.number?.toString() ?: ""]?.let { return it }
        return fallback[channel.id]?.second ?: emptyList()
    }

    fun now(channel: Channel): Programme? = forChannel(channel).firstOrNull { it.isLive }
    fun next(channel: Channel): Programme? {
        val t = System.currentTimeMillis()
        return forChannel(channel).filter { it.start > t }.minByOrNull { it.start }
    }

    /** Per-channel API fallback for channels the XMLTV export doesn't cover. */
    suspend fun ensure(channel: Channel) {
        if (programmes.containsKey(key(channel))) return
        val cached = fallback[channel.id]
        if (cached != null && System.currentTimeMillis() - cached.first < 10 * 60_000) return
        val client = DispatcharrRepo.client ?: return
        val list = runCatching { withContext(Dispatchers.IO) { client.channelGuide(channel.id) } }.getOrDefault(emptyList())
        fallback[channel.id] = System.currentTimeMillis() to list
        // Nudge Compose to re-read.
        programmes = programmes.toMap()
    }

    fun refreshIfStale() {
        if (System.currentTimeMillis() - updatedAt > 4 * 3600_000L || programmes.isEmpty()) refresh()
    }

    fun refresh() {
        if (refreshJob?.isActive == true) return
        val client = DispatcharrRepo.client ?: return
        refreshJob = scope.launch {
            refreshing = true
            lastError = null
            try {
                val prevDays = DispatcharrRepo.channels.maxOfOrNull { it.archiveDays }?.coerceIn(0, 7) ?: 1
                val url = client.xmltvUrl(Settings.values.guideDays, maxOf(1, prevDays))
                val file = Store.cacheFile("guide.xml")
                Http.download(url, file)
                val parsed = withContext(Dispatchers.Default) { parse(file, prevDays) }
                file.delete()
                if (parsed.isNotEmpty()) {
                    setProgrammes(parsed)
                    updatedAt = System.currentTimeMillis()
                    Store.prefs.edit().putLong("guide.updated", updatedAt).apply()
                    withContext(Dispatchers.IO) { Store.save(serializer, parsed, "guide-cache.json") }
                }
            } catch (e: Exception) {
                lastError = e.message ?: "Couldn't download the guide"
            } finally {
                refreshing = false
            }
        }
    }

    private fun parse(file: File, prevDays: Int): Map<String, List<Programme>> {
        val from = System.currentTimeMillis() - maxOf(1, prevDays) * 86_400_000L
        val result = HashMap<String, MutableList<Programme>>()
        file.inputStream().buffered().use { input ->
            val parser = Xml.newPullParser()
            parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
            parser.setInput(input, null)
            var channel: String? = null
            var start = 0L
            var stop = 0L
            var title = ""
            var desc: String? = null
            var sub: String? = null
            val cats = mutableListOf<String>()
            var event = parser.eventType
            while (event != XmlPullParser.END_DOCUMENT) {
                when (event) {
                    XmlPullParser.START_TAG -> when (parser.name) {
                        "programme" -> {
                            channel = parser.getAttributeValue(null, "channel")
                            start = parseDate(parser.getAttributeValue(null, "start"))
                            stop = parseDate(parser.getAttributeValue(null, "stop")).takeIf { it > 0 } ?: (start + 1800_000)
                            title = ""; desc = null; sub = null; cats.clear()
                        }
                        "title" -> if (channel != null && title.isEmpty()) title = parser.nextText().trim()
                        "desc" -> if (channel != null && desc == null) desc = parser.nextText().trim().ifEmpty { null }
                        "sub-title" -> if (channel != null && sub == null) sub = parser.nextText().trim().ifEmpty { null }
                        "category" -> if (channel != null && cats.size < 6) parser.nextText().trim().takeIf { it.isNotEmpty() }?.let { cats.add(it) }
                    }
                    XmlPullParser.END_TAG -> if (parser.name == "programme") {
                        val ch = channel
                        if (ch != null && start > 0 && stop > from) {
                            result.getOrPut(ch) { mutableListOf() }.add(Programme(start, maxOf(stop, start + 60_000), title, desc, sub, cats.toList()))
                        }
                        channel = null
                    }
                }
                event = parser.next()
            }
        }
        return result.mapValues { (_, list) -> list.sortedBy { it.start } }
    }

    /** XMLTV dates: "20261014120000 +0000". */
    private fun parseDate(s: String?): Long {
        if (s == null || s.length < 12) return 0
        return try {
            val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
            cal.clear()
            cal.set(s.substring(0, 4).toInt(), s.substring(4, 6).toInt() - 1, s.substring(6, 8).toInt(),
                s.substring(8, 10).toInt(), s.substring(10, 12).toInt(), if (s.length >= 14) s.substring(12, 14).toIntOrNull() ?: 0 else 0)
            var ms = cal.timeInMillis
            val tz = s.substring(minOf(14, s.length)).trim()
            if (tz.length >= 5 && (tz[0] == '+' || tz[0] == '-')) {
                val sign = if (tz[0] == '-') -1 else 1
                val h = tz.substring(1, 3).toInt()
                val m = tz.substring(3, 5).toInt()
                ms -= sign * (h * 3600_000L + m * 60_000L)
            }
            ms
        } catch (_: Exception) {
            0
        }
    }

    // MARK: Sports

    private val sportsWords = Regex(
        """(?i)\b(sports?|ppv|events?|nba|nfl|nhl|mlb|ufc|wwe|f1|formula|golf|tennis|football|soccer|cricket|rugby|boxing|motogp|dazn|espn|bein|eurosport|laliga|serie a|bundesliga|premier league|champions league)\b""")
    private val matchWords = Regex("""(?i)(\bvs?\.?\s|\s@\s|\blive:|\bgrand prix\b|\bfinal\b|\bmatch\b|\bround \d+)""")

    fun isSportsChannel(channel: Channel): Boolean =
        sportsWords.containsMatchIn(channel.name) || sportsWords.containsMatchIn(DispatcharrRepo.categoryName(channel.categoryId))

    fun isEvent(p: Programme): Boolean =
        matchWords.containsMatchIn(p.title) || p.categories.any { sportsWords.containsMatchIn(it) }

    /** Sports channels showing something that looks like a match or event right now. */
    fun liveSports(): List<Pair<Channel, Programme>> =
        DispatcharrRepo.channels.mapNotNull { ch ->
            val now = now(ch) ?: return@mapNotNull null
            if (isEvent(now) || (isSportsChannel(ch) && now.title.isNotBlank())) ch to now else null
        }.sortedByDescending { isEvent(it.second) }.take(40)
}
