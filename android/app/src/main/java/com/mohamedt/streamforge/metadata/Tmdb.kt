package com.mohamedt.streamforge.metadata

import com.mohamedt.streamforge.core.Episode
import com.mohamedt.streamforge.core.Http
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.MediaType
import com.mohamedt.streamforge.core.Origin
import com.mohamedt.streamforge.core.Person
import com.mohamedt.streamforge.core.Settings
import com.mohamedt.streamforge.core.buildUrl
import com.mohamedt.streamforge.core.child
import com.mohamedt.streamforge.core.dbl
import com.mohamedt.streamforge.core.int
import com.mohamedt.streamforge.core.obj
import com.mohamedt.streamforge.core.objects
import com.mohamedt.streamforge.core.str
import kotlinx.serialization.json.JsonObject

/** TMDB v3. Accepts a v3 API key or a v4 read-access token. */
object Tmdb {
    private const val BASE = "https://api.themoviedb.org/3"
    val configured: Boolean get() = Settings.tmdbKey.isNotEmpty()

    fun image(path: String?, size: String = "w500"): String? = path?.takeIf { it.isNotEmpty() }?.let { "https://image.tmdb.org/t/p/$size$it" }

    private suspend fun get(path: String, query: Map<String, String?> = emptyMap()): JsonObject {
        val key = Settings.tmdbKey
        val q = query.toMutableMap()
        q["language"] = Settings.values.metadataLanguage
        val headers = mutableMapOf<String, String>()
        if (key.length > 40) headers["Authorization"] = "Bearer $key" else q["api_key"] = key
        return Http.json(buildUrl(BASE, path, q), headers).obj() ?: JsonObject(emptyMap())
    }

    private val genreNames = mapOf(
        28 to "Action", 12 to "Adventure", 16 to "Animation", 35 to "Comedy", 80 to "Crime", 99 to "Documentary",
        18 to "Drama", 10751 to "Family", 14 to "Fantasy", 36 to "History", 27 to "Horror", 10402 to "Music",
        9648 to "Mystery", 10749 to "Romance", 878 to "Science Fiction", 53 to "Thriller", 10752 to "War", 37 to "Western",
        10759 to "Action & Adventure", 10762 to "Kids", 10765 to "Sci-Fi & Fantasy", 10768 to "War & Politics",
    )

    fun summary(o: JsonObject, default: MediaType): MediaItem? {
        val id = o.int("id") ?: return null
        val type = when (o.str("media_type")) { "tv" -> MediaType.SERIES; "movie" -> MediaType.MOVIE; else -> default }
        return MediaItem(
            id = "tmdb:${type.name.lowercase()}:$id", type = type, title = o.str("title") ?: o.str("name") ?: "",
            year = (o.str("release_date") ?: o.str("first_air_date"))?.take(4)?.toIntOrNull(),
            poster = image(o.str("poster_path"), "w342"), backdrop = image(o.str("backdrop_path"), "w1280"),
            overview = o.str("overview"), rating = o.dbl("vote_average")?.takeIf { it > 0 },
            genres = (o["genre_ids"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { (it as? kotlinx.serialization.json.JsonPrimitive)?.content?.toIntOrNull()?.let { g -> genreNames[g] } } ?: emptyList(),
            tmdbId = id, origin = Origin("tmdb", id.toLong()),
        )
    }

    suspend fun trending(type: MediaType): List<MediaItem> =
        get(if (type == MediaType.SERIES) "trending/tv/week" else "trending/movie/week").objects("results").mapNotNull { summary(it, type) }

    suspend fun search(query: String): List<MediaItem> =
        get("search/multi", mapOf("query" to query, "include_adult" to "false")).objects("results")
            .filter { it.str("media_type") == "movie" || it.str("media_type") == "tv" }.mapNotNull { summary(it, MediaType.MOVIE) }

    suspend fun findByImdb(imdb: String): MediaItem? {
        val o = get("find/$imdb", mapOf("external_source" to "imdb_id"))
        return o.objects("movie_results").firstOrNull()?.let { summary(it, MediaType.MOVIE) }
            ?: o.objects("tv_results").firstOrNull()?.let { summary(it, MediaType.SERIES) }
    }

    suspend fun searchBest(title: String, year: Int?, type: MediaType): Int? {
        val path = if (type == MediaType.SERIES) "search/tv" else "search/movie"
        val q = mutableMapOf<String, String?>("query" to title)
        if (year != null) q[if (type == MediaType.SERIES) "first_air_date_year" else "year"] = year.toString()
        val results = get(path, q).objects("results")
        val lower = title.lowercase()
        return (results.firstOrNull { (it.str("title") ?: it.str("name"))?.lowercase() == lower } ?: results.firstOrNull())?.int("id")
    }

    data class Full(
        val raw: JsonObject,
        val imdbId: String?,
        val cast: List<Person>,
        val directors: List<String>,
        val trailer: String?,
        val logo: String?,
        val similar: List<MediaItem>,
        val seasons: List<Int>,
        val collectionId: Int?,
        val collectionName: String?,
    )

    suspend fun details(id: Int, type: MediaType): Full {
        val tv = type == MediaType.SERIES
        val lang = Settings.values.metadataLanguage
        val o = get((if (tv) "tv/" else "movie/") + id, mapOf(
            "append_to_response" to "credits,videos,images,external_ids,recommendations",
            "include_image_language" to "$lang,en,null", "include_video_language" to "$lang,en,null"))
        val credits = o.child("credits")
        val videos = o.child("videos")?.objects("results")?.filter { it.str("site") == "YouTube" } ?: emptyList()
        val trailer = (videos.firstOrNull { it.str("type") == "Trailer" } ?: videos.firstOrNull())?.str("key")
        val logos = o.child("images")?.objects("logos") ?: emptyList()
        val logo = (logos.firstOrNull { it.str("iso_639_1") == lang } ?: logos.firstOrNull { it.str("iso_639_1") == "en" } ?: logos.firstOrNull())?.str("file_path")
        val collection = o.child("belongs_to_collection")
        return Full(
            raw = o,
            imdbId = o.str("imdb_id") ?: o.child("external_ids")?.str("imdb_id"),
            cast = credits?.objects("cast")?.take(20)?.mapNotNull { c ->
                Person(c.int("id") ?: return@mapNotNull null, c.str("name") ?: "", c.str("character"), image(c.str("profile_path"), "w185"))
            } ?: emptyList(),
            directors = credits?.objects("crew")?.filter { it.str("job") == "Director" }?.mapNotNull { it.str("name") } ?: emptyList(),
            trailer = trailer,
            logo = image(logo, "w500"),
            similar = o.child("recommendations")?.objects("results")?.take(20)?.mapNotNull { summary(it, type) } ?: emptyList(),
            seasons = o.objects("seasons").mapNotNull { it.int("season_number") }.filter { it > 0 },
            collectionId = collection?.int("id"),
            collectionName = collection?.str("name"),
        )
    }

    suspend fun season(tvId: Int, season: Int, imdbId: String?): List<Episode> =
        get("tv/$tvId/season/$season").objects("episodes").mapNotNull { e ->
            val n = e.int("episode_number") ?: return@mapNotNull null
            Episode(
                id = "tmdb-$tvId-$season-$n", season = season, episode = n, title = e.str("name") ?: "Episode $n",
                overview = e.str("overview"), still = image(e.str("still_path"), "w500"), airDate = e.str("air_date"),
                runtimeMinutes = e.int("runtime"), stremioVideoId = imdbId?.let { "$it:$season:$n" },
            )
        }

    data class Collection(val name: String, val overview: String?, val backdrop: String?, val parts: List<MediaItem>)

    suspend fun collection(id: Int): Collection {
        val o = get("collection/$id")
        return Collection(o.str("name") ?: "Collection", o.str("overview"), image(o.str("backdrop_path"), "w1280"),
            o.objects("parts").mapNotNull { summary(it, MediaType.MOVIE) }.sortedBy { it.year ?: 9999 })
    }

    data class PersonInfo(val name: String, val bio: String?, val photo: String?, val credits: List<MediaItem>)

    suspend fun person(id: Int): PersonInfo {
        val o = get("person/$id", mapOf("append_to_response" to "combined_credits"))
        val credits = (o.child("combined_credits")?.objects("cast") ?: emptyList())
            .filter { it.str("media_type") == "movie" || it.str("media_type") == "tv" }
            .sortedByDescending { it.dbl("popularity") ?: 0.0 }
            .mapNotNull { summary(it, MediaType.MOVIE) }
            .distinctBy { it.id }
        return PersonInfo(o.str("name") ?: "", o.str("biography"), image(o.str("profile_path"), "w342"), credits)
    }

    suspend fun searchPerson(name: String): Int? = get("search/person", mapOf("query" to name)).objects("results").firstOrNull()?.int("id")
}
