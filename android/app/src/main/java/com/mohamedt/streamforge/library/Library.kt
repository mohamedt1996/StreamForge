package com.mohamedt.streamforge.library

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.mohamedt.streamforge.core.Episode
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.Store
import kotlinx.serialization.Serializable

@Serializable
data class Progress(
    val key: String,
    val item: MediaItem,
    val episode: Episode? = null,
    val position: Long,
    val duration: Long,
    val updatedAt: Long,
) {
    val fraction: Float get() = if (duration > 0) (position.toFloat() / duration).coerceIn(0f, 1f) else 0f
    val finished: Boolean get() = duration > 0 && (position.toFloat() / duration > 0.92f || duration - position < 120_000)
    val remainingText: String
        get() {
            val mins = ((duration - position) / 60_000).toInt()
            return if (mins >= 60) "${mins / 60}h ${mins % 60}m left" else "${maxOf(1, mins)}m left"
        }
}

@Serializable
private data class LibrarySnapshot(
    val favorites: List<MediaItem> = emptyList(),
    val favoriteChannels: List<Long> = emptyList(),
    val recentChannels: List<Long> = emptyList(),
    val progress: Map<String, Progress> = emptyMap(),
    val watched: Set<String> = emptySet(),
    val hiddenCategories: Set<String> = emptySet(),
    val introMarkers: Map<String, List<Long>> = emptyMap(),
)

/** Favorites, positions, watched marks and channel history. */
object Library {
    private var snap by mutableStateOf(Store.load(LibrarySnapshot.serializer(), "library.json") ?: LibrarySnapshot())

    val favorites get() = snap.favorites
    val favoriteChannels get() = snap.favoriteChannels
    val recentChannels get() = snap.recentChannels
    val lastChannel: Long? get() = snap.recentChannels.getOrNull(1)
    val watched get() = snap.watched

    private fun update(transform: (LibrarySnapshot) -> LibrarySnapshot) {
        snap = transform(snap)
        Store.save(LibrarySnapshot.serializer(), snap, "library.json")
    }

    fun key(item: MediaItem, episode: Episode?) = episode?.let { "${item.id}#${it.season}x${it.episode}" } ?: item.id

    fun isFavorite(item: MediaItem) = snap.favorites.any { it.id == item.id }
    fun toggleFavorite(item: MediaItem) = update { s ->
        s.copy(favorites = if (isFavorite(item)) s.favorites.filter { it.id != item.id } else listOf(item) + s.favorites)
    }

    fun isFavoriteChannel(id: Long) = id in snap.favoriteChannels
    fun toggleFavoriteChannel(id: Long) = update { s ->
        s.copy(favoriteChannels = if (id in s.favoriteChannels) s.favoriteChannels - id else s.favoriteChannels + id)
    }

    fun recordChannel(id: Long) = update { s -> s.copy(recentChannels = (listOf(id) + s.recentChannels.filter { it != id }).take(20)) }

    fun isHidden(category: String) = category in snap.hiddenCategories
    fun toggleHidden(category: String) = update { s ->
        s.copy(hiddenCategories = if (category in s.hiddenCategories) s.hiddenCategories - category else s.hiddenCategories + category)
    }

    fun progress(item: MediaItem, episode: Episode? = null): Progress? = snap.progress[key(item, episode)]
    fun isWatched(item: MediaItem, episode: Episode? = null) = key(item, episode) in snap.watched

    fun setWatched(item: MediaItem, episode: Episode?, value: Boolean) = update { s ->
        val k = key(item, episode)
        if (value) s.copy(watched = s.watched + k, progress = s.progress - k) else s.copy(watched = s.watched - k)
    }

    fun updateProgress(item: MediaItem, episode: Episode?, position: Long, duration: Long) {
        if (duration < 60_000 || position < 5_000) return
        val k = key(item, episode)
        val p = Progress(k, item, episode, position, duration, System.currentTimeMillis())
        update { s ->
            if (p.finished) s.copy(progress = s.progress - k, watched = s.watched + k) else s.copy(progress = s.progress + (k to p))
        }
    }

    fun clearProgress(key: String) = update { s -> s.copy(progress = s.progress - key) }

    val continueWatching: List<Progress>
        get() {
            val seen = HashSet<String>()
            return snap.progress.values.sortedByDescending { it.updatedAt }.filter { seen.add(it.item.id) }
        }

    fun latestEpisode(item: MediaItem): Progress? =
        snap.progress.values.filter { it.item.id == item.id && it.episode != null }.maxByOrNull { it.updatedAt }

    /** Per-series manual intro markers [start, end] in ms. */
    fun introMarker(seriesKey: String): Pair<Long, Long>? = snap.introMarkers[seriesKey]?.takeIf { it.size == 2 }?.let { it[0] to it[1] }
    fun setIntroMarker(seriesKey: String, start: Long, end: Long) = update { s -> s.copy(introMarkers = s.introMarkers + (seriesKey to listOf(start, end))) }
}
