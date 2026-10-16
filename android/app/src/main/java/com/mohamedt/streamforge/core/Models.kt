package com.mohamedt.streamforge.core

import kotlinx.serialization.Serializable

@Serializable
enum class MediaType { MOVIE, SERIES, CHANNEL, OTHER;

    val stremio: String
        get() = when (this) {
            MOVIE -> "movie"
            SERIES -> "series"
            CHANNEL -> "tv"
            OTHER -> "other"
        }

    companion object {
        fun fromStremio(s: String?): MediaType = when (s) {
            "movie" -> MOVIE
            "series" -> SERIES
            "tv", "channel" -> CHANNEL
            else -> OTHER
        }
    }
}

/** Where an item came from, which decides how it is resolved and played. */
@Serializable
data class Origin(
    val kind: String, // "xc-movie", "xc-series", "xc-channel", "stremio", "tmdb"
    val id: Long = 0,
    val ext: String? = null,
    val addonId: String? = null,
    val metaId: String? = null,
    val serverId: String? = null,
)

@Serializable
data class MediaItem(
    val id: String,
    val type: MediaType,
    val title: String,
    val year: Int? = null,
    val poster: String? = null,
    val backdrop: String? = null,
    val logo: String? = null,
    val overview: String? = null,
    val rating: Double? = null,
    val genres: List<String> = emptyList(),
    val imdbId: String? = null,
    val tmdbId: Int? = null,
    val origin: Origin,
    val added: Long? = null,
    val categoryId: String? = null,
    val runtimeMinutes: Int? = null,
) {
    /** Id addons understand (IMDb id, or the addon's own meta id). */
    val stremioId: String?
        get() = imdbId?.takeIf { it.startsWith("tt") } ?: origin.metaId ?: tmdbId?.let { "tmdb:$it" }
}

@Serializable
data class Episode(
    val id: String,
    val season: Int,
    val episode: Int,
    val title: String,
    val overview: String? = null,
    val still: String? = null,
    val airDate: String? = null,
    val runtimeMinutes: Int? = null,
    val xcEpisodeId: Long? = null,
    val ext: String? = null,
    val stremioVideoId: String? = null,
) {
    val code: String get() = "S%02dE%02d".format(season, episode)
}

data class Person(val id: Int, val name: String, val role: String? = null, val photo: String? = null)

data class Details(
    val item: MediaItem,
    val tagline: String? = null,
    val cast: List<Person> = emptyList(),
    val directors: List<String> = emptyList(),
    val trailerKey: String? = null,
    val seasons: List<Int> = emptyList(),
    val episodes: Map<Int, List<Episode>> = emptyMap(),
    val similar: List<MediaItem> = emptyList(),
    val certification: String? = null,
    /** YouTube trailer ids, best first; the hero trailer tries them in order. */
    val trailerKeys: List<String> = listOfNotNull(trailerKey),
    /** IMDb user rating (0–10) when the title has an IMDb id; shown as an "IMDb" badge. */
    val imdbRating: Double? = null,
    /** Rotten Tomatoes Tomatometer ("85%") and Metascore ("67"), from OMDb when a key is set. */
    val rottenTomatoes: String? = null,
    val metacritic: String? = null,
)

/** "https://youtu.be/abc_DEF-123", "…watch?v=abc_DEF-123" or "abc_DEF-123" → "abc_DEF-123" (null for junk). */
fun cleanYouTubeKey(raw: String?): String? {
    var s = raw?.trim().orEmpty()
    if (s.isEmpty()) return null
    if (s.contains("/") || s.contains("=")) {
        s = Regex("""[?&]v=([\w-]+)""").find(s)?.groupValues?.get(1)
            ?: s.substringBefore('?').trimEnd('/').substringAfterLast('/')
    }
    return s.takeIf { k -> k.length in 6..20 && k.all { it.isLetterOrDigit() && it.code < 128 || it == '-' || it == '_' } }
}

/** "Zoë  Saldaña-Perez" → "zoesaldanaperez" (for matching cast names across sources). */
fun normalizeName(name: String): String =
    // NFD splits accents into combining marks, which aren't letters, so they drop out.
    java.text.Normalizer.normalize(name, java.text.Normalizer.Form.NFD)
        .filter { it.isLetterOrDigit() }
        .lowercase()

fun Long.clockText(): String {
    val total = this / 1000
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

fun Long.byteText(): String {
    if (this < 1024) return "$this B"
    val units = listOf("KB", "MB", "GB", "TB")
    var v = this / 1024.0
    var i = 0
    while (v >= 1024 && i < units.size - 1) { v /= 1024; i++ }
    return "%.1f %s".format(v, units[i])
}

/** Cleans provider titles such as "EN | The Matrix (1999) [4K]" into "The Matrix" + 1999. */
object TitleCleaner {
    private val prefix = Regex("""^\s*(\[[^\]]{1,12}\]|[A-Z0-9]{2,4}\s*[|\-:•]+)\s*""")
    private val year = Regex("""[(\[]?\b(19[2-9]\d|20[0-4]\d)\b[)\]]?""")
    private val tags = Regex(
        """(?i)[(\[]?\b(4k|uhd|fhd|hd|sd|hevc|x26[45]|h\.?26[45]|1080p|720p|2160p|multi|vostfr|subbed|dubbed|hdr10?\+?|dolby vision|dv|imax)\b[)\]]?""")

    fun clean(raw: String): Pair<String, Int?> {
        var s = raw
        repeat(2) { s = prefix.replaceFirst(s, "") }
        var y: Int? = null
        year.findAll(s).lastOrNull()?.let { m ->
            val stripped = s.removeRange(m.range)
            if (stripped.trim(' ', '-', '|', ':', '(', ')', '[', ']').isNotEmpty()) {
                s = stripped
                y = m.groupValues[1].toIntOrNull()
            }
        }
        s = tags.replace(s, "").replace(Regex("""\s{2,}"""), " ").trim(' ', '-', '|', ':', '•', '[', ']', '(', ')')
        return (s.ifEmpty { raw.trim() }) to y
    }

    /** "EN | Action" → ("EN", "Action"). */
    fun splitCategory(raw: String): Pair<String?, String> {
        for (sep in listOf("|", " - ", ":", "•", "»")) {
            val parts = raw.split(sep)
            if (parts.size >= 2) {
                val head = parts[0].trim()
                val rest = parts.drop(1).joinToString(sep).trim()
                if (head.isNotEmpty() && head.length <= 12 && rest.isNotEmpty()) return head.uppercase() to rest
            }
        }
        return null to raw.trim()
    }
}
