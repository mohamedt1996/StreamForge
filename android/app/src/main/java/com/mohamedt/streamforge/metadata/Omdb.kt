package com.mohamedt.streamforge.metadata

import com.mohamedt.streamforge.core.Http
import com.mohamedt.streamforge.core.Settings
import com.mohamedt.streamforge.core.buildUrl
import com.mohamedt.streamforge.core.obj
import com.mohamedt.streamforge.core.objects
import com.mohamedt.streamforge.core.str
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.cancellation.CancellationException

/** OMDb (omdbapi.com): IMDb, Rotten Tomatoes and Metacritic scores plus the age rating, by IMDb id. */
object Omdb {
    data class Ratings(
        /** IMDb user rating, 0–10. */
        val imdb: Double? = null,
        /** Rotten Tomatoes Tomatometer, e.g. "85%". */
        val rottenTomatoes: String? = null,
        /** Metascore, e.g. "67". */
        val metacritic: String? = null,
        /** Age rating, e.g. "PG-13". */
        val rated: String? = null,
    )

    val configured: Boolean get() = Settings.effectiveOmdbKey.isNotEmpty()

    private val cache = ConcurrentHashMap<String, Ratings>()

    suspend fun ratings(imdbId: String): Ratings? {
        if (!configured || !imdbId.startsWith("tt")) return null
        cache[imdbId]?.let { return it }
        val o = try {
            Http.json(buildUrl("https://www.omdbapi.com", "/", mapOf("i" to imdbId, "apikey" to Settings.effectiveOmdbKey)), timeoutSeconds = 8).obj()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            return null
        } ?: return null
        if (o.str("Response") != "True") return null
        fun clean(v: String?): String? = v?.trim()?.takeIf { it.isNotEmpty() && it != "N/A" }
        var imdb = clean(o.str("imdbRating"))?.toDoubleOrNull()
        var rt: String? = null
        var mc = clean(o.str("Metascore"))
        for (r in o.objects("Ratings")) {
            val value = clean(r.str("Value")) ?: continue
            when (r.str("Source")) {
                "Internet Movie Database" -> if (imdb == null) imdb = value.substringBefore("/").toDoubleOrNull()
                "Rotten Tomatoes" -> rt = value
                "Metacritic" -> if (mc == null) mc = value.substringBefore("/")
            }
        }
        val result = Ratings(imdb?.takeIf { it > 0 && it <= 10 }, rt, mc, clean(o.str("Rated")))
        cache[imdbId] = result
        return result
    }
}
