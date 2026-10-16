package com.mohamedt.streamforge.ui.screens

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import com.mohamedt.streamforge.ui.KeylineScroll
import com.mohamedt.streamforge.ui.LocalShelfKey
import com.mohamedt.streamforge.ui.PageTitle
import com.mohamedt.streamforge.ui.SfTextField
import com.mohamedt.streamforge.ui.TvRowCardOffset
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.MediaType
import com.mohamedt.streamforge.core.TitleCleaner
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.dispatcharr.LoadState
import com.mohamedt.streamforge.library.Library
import com.mohamedt.streamforge.metadata.Metadata
import com.mohamedt.streamforge.metadata.Tmdb
import com.mohamedt.streamforge.stremio.Addons
import com.mohamedt.streamforge.ui.Chip
import com.mohamedt.streamforge.ui.Dims
import com.mohamedt.streamforge.ui.EmptyState
import com.mohamedt.streamforge.ui.Loading
import com.mohamedt.streamforge.ui.LocalNav
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.WatchlistCard
import com.mohamedt.streamforge.ui.PosterCard
import com.mohamedt.streamforge.ui.Screen
import com.mohamedt.streamforge.ui.Shelf
import com.mohamedt.streamforge.ui.isTv
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

enum class VodSort(val label: String) { ADDED("Recently Added"), TITLE("A–Z"), YEAR("Year"), RATING("Rating") }

data class VodFilter(val sort: VodSort = VodSort.ADDED, val genre: String? = null, val decade: Int? = null, val unwatched: Boolean = false, val query: String = "") {
    val active get() = genre != null || decade != null || unwatched || query.isNotBlank()
}

/** Runs on Dispatchers.Default (it walks the whole library). */
fun applyFilter(f: VodFilter, items: List<MediaItem>): List<MediaItem> {
    val q = f.query.trim()
    // Read once: Library.isWatched per item would read the snapshot state tens of thousands of times.
    val watched = if (f.unwatched) Library.watched else emptySet()
    val out = items.filter { i ->
        (q.isEmpty() || i.title.contains(q, ignoreCase = true)) &&
            (f.genre == null || i.genres.any { it.contains(f.genre, ignoreCase = true) }) &&
            (f.decade == null || (i.year != null && i.year >= f.decade && i.year < f.decade + 10)) &&
            (!f.unwatched || i.id !in watched) // Library.key(item, null) == item.id
    }
    return when (f.sort) {
        VodSort.ADDED -> out.sortedByDescending { it.added ?: 0 }
        // Lower-case each title once, not on every comparison.
        VodSort.TITLE -> out.map { it.title.lowercase() to it }.sortedBy { it.first }.map { it.second }
        VodSort.YEAR -> out.sortedByDescending { it.year ?: 0 }
        VodSort.RATING -> out.sortedByDescending { it.rating ?: 0.0 }
    }
}

@Composable
private fun FilterBar(kind: MediaType, filter: VodFilter, grid: Boolean?, onGrid: ((Boolean) -> Unit)?, title: String? = null, padded: Boolean = true,
                      onChange: (VodFilter) -> Unit) {
    val genres = if (kind == MediaType.SERIES) DispatcharrRepo.seriesGenres else DispatcharrRepo.movieGenres
    val tv = isTv()
    val inset = if (padded) Dims.gutter() else 0.dp
    Column {
        if (tv) {
            Row(Modifier.fillMaxWidth().padding(horizontal = inset), verticalAlignment = Alignment.CenterVertically) {
                if (title != null) PageTitle(title, Modifier.padding(end = 28.dp))
                SfTextField(filter.query, { onChange(filter.copy(query = it)) }, "Search ${if (kind == MediaType.SERIES) "series" else "movies"}",
                    Modifier.widthIn(max = 520.dp), icon = Icons.Filled.Search)
            }
        } else {
            SfTextField(filter.query, { onChange(filter.copy(query = it)) }, "Search ${if (kind == MediaType.SERIES) "series" else "movies"}",
                Modifier.padding(horizontal = inset))
        }
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = inset, vertical = if (tv) 14.dp else 8.dp),
            horizontalArrangement = Arrangement.spacedBy(if (tv) 12.dp else 8.dp)) {
            if (grid != null && onGrid != null) Chip(if (grid) "Grid" else "Shelves", false) { onGrid(!grid) }
            VodSort.entries.forEach { s -> Chip(s.label, filter.sort == s) { onChange(filter.copy(sort = s)) } }
            Chip("Unwatched", filter.unwatched) { onChange(filter.copy(unwatched = !filter.unwatched)) }
            listOf(2020, 2010, 2000, 1990, 1980).forEach { d -> Chip("${d}s", filter.decade == d) { onChange(filter.copy(decade = if (filter.decade == d) null else d)) } }
            genres.take(20).forEach { g -> Chip(g, filter.genre == g) { onChange(filter.copy(genre = if (filter.genre == g) null else g)) } }
        }
    }
}

@Composable
fun PosterGrid(items: List<MediaItem>, header: @Composable (() -> Unit)? = null) {
    val nav = LocalNav.current
    // Unique ids only: duplicate lazy keys crash (addon catalogs and collections can repeat items).
    val unique = remember(items) { items.distinctBy { it.id } }
    var visible by remember(items) { mutableStateOf(150) }
    val tv = isTv()
    CompositionLocalProvider(LocalShelfKey provides "grid") {
    LazyVerticalGrid(
        columns = GridCells.Adaptive(Dims.poster() + 8.dp),
        contentPadding = if (tv) PaddingValues(start = Dims.gutter(), end = Dims.gutter(), top = Dims.overscanY, bottom = Dims.overscanY + 40.dp) else PaddingValues(Dims.gutter()),
        horizontalArrangement = Arrangement.spacedBy(if (tv) 22.dp else 12.dp),
        verticalArrangement = Arrangement.spacedBy(if (tv) 10.dp else 16.dp),
        modifier = Modifier.fillMaxSize(),
    ) {
        if (header != null) item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(maxLineSpan) }) { header() }
        val shown = unique.take(visible)
        items(shown, key = { it.id }) { item ->
            PosterCard(item, { nav.push(Screen.Detail(item)) }, { Library.toggleFavorite(item) })
            if (item.id == shown.lastOrNull()?.id && visible < unique.size) LaunchedEffect(visible) { visible += 150 }
        }
    }
    }
}

@Composable
fun VodScreen(kind: MediaType) {
    val nav = LocalNav.current
    var filter by remember { mutableStateOf(VodFilter()) }
    var grid by remember { mutableStateOf(false) }
    var section by remember { mutableStateOf<String?>(null) }
    val all = if (kind == MediaType.SERIES) DispatcharrRepo.seriesItems else DispatcharrRepo.movieItems
    val state = DispatcharrRepo.vodState

    when {
        !DispatcharrRepo.isConfigured -> { EmptyState("No Dispatcharr server", "Sign in to your server in Settings to browse its library. Addon catalogs are on Home and Search."); return }
        state is LoadState.Failed && all.isEmpty() -> { EmptyState("Couldn't load the library", state.message, "Retry") { DispatcharrRepo.refreshAll(true) }; return }
        all.isEmpty() -> { if (state == LoadState.Loaded) EmptyState("Nothing here yet", "Your server has no ${if (kind == MediaType.SERIES) "series" else "movies"}.") else Loading("Organizing your library…"); return }
    }

    if (grid || filter.active || filter.sort != VodSort.ADDED) {
        var results by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
        LaunchedEffect(filter, all) {
            // Typing restarts this effect: wait for a pause before walking the whole library.
            if (filter.query.isNotBlank()) delay(250)
            results = withContext(Dispatchers.Default) { applyFilter(filter, all) }
        }
        PosterGrid(results) {
            Column {
                FilterBar(kind, filter, grid, { grid = it }, title = if (isTv()) (if (kind == MediaType.SERIES) "Series" else "Movies") else null, padded = false) { filter = it }
                Text("${results.size} ${if (kind == MediaType.SERIES) "series" else "movies"}", fontSize = if (isTv()) 16.sp else 12.sp, color = Palette.secondary)
            }
        }
        return
    }

    val sections = if (kind == MediaType.SERIES) DispatcharrRepo.seriesSections else DispatcharrRepo.movieSections
    val active = sections.firstOrNull { it.name == (section ?: sections.firstOrNull()?.name) }
    val open: (MediaItem) -> Unit = { nav.push(Screen.Detail(it)) }

    val tv = isTv()
    KeylineScroll(TvRowCardOffset, enabled = tv) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = if (tv) Dims.overscanY else 0.dp, bottom = if (tv) 120.dp else 0.dp)) {
        item { FilterBar(kind, filter, grid, { grid = it }, title = if (tv) (if (kind == MediaType.SERIES) "Series" else "Movies") else null) { filter = it } }
        item {
            val cont = Library.continueWatching.filter { it.item.type == kind && it.item.origin.kind.startsWith("xc") }
            Shelf("Continue Watching", cont.filter { !it.finished }, key = { it.key }) { ContinueCard(it) }
        }
        // Pre-built off the main thread by DispatcharrRepo (no full-library sort per recomposition).
        item { Shelf("Recently Added", if (kind == MediaType.SERIES) DispatcharrRepo.recentSeries else DispatcharrRepo.recentMovies, seeAll = { grid = true }, key = { it.id }) { PosterCard(it, { open(it) }) } }
        item { Shelf("Top Rated", if (kind == MediaType.SERIES) DispatcharrRepo.topSeries else DispatcharrRepo.topMovies, key = { it.id }) { PosterCard(it, { open(it) }) } }
        item { Shelf("My List", Library.favorites.filter { it.type == kind }, key = { it.id }) { WatchlistCard(it, { open(it) }) } }
        if (kind == MediaType.MOVIE) item { CollectionsShelf(all) }
        if (sections.size > 1) {
            item {
                Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = Dims.gutter(), vertical = if (tv) 14.dp else 8.dp), horizontalArrangement = Arrangement.spacedBy(if (tv) 12.dp else 8.dp)) {
                    sections.forEach { s -> Chip(s.name, active?.name == s.name) { section = s.name } }
                }
            }
        }
        (active?.categories ?: emptyList()).filter { !Library.isHidden("${kind.name}:${it.id}") }.forEach { cat ->
            item(key = "cat-${cat.id}") {
                // Already newest first (DispatcharrRepo pre-sorts each category).
                val items = if (kind == MediaType.SERIES) DispatcharrRepo.series(cat.id) else DispatcharrRepo.movies(cat.id)
                val name = remember(cat.name) { TitleCleaner.splitCategory(cat.name).second }
                val shown = remember(items) { items.take(20) }
                Shelf(name, shown, subtitle = "${items.size} titles",
                    seeAll = { nav.push(Screen.Category(kind, cat.id, name)) }, key = { it.id }, rowKey = "cat-${cat.id}") { PosterCard(it, { open(it) }) }
            }
        }
        item { Spacer(Modifier.height(30.dp)) }
    }
    }
}

/** Franchises (TMDB collections) found among the server's movies as their details are opened/enriched. */
@Composable
private fun CollectionsShelf(all: List<MediaItem>) {
    val nav = LocalNav.current
    var groups by remember { mutableStateOf<List<Triple<Int, String, List<MediaItem>>>>(emptyList()) }
    LaunchedEffect(all.size) {
        if (!Tmdb.configured) return@LaunchedEffect
        // Resolve collections for the best-known movies in the background (cached per item).
        val candidates = withContext(Dispatchers.Default) {
            all.filter { it.tmdbId != null }.sortedByDescending { it.rating ?: 0.0 }.take(200)
        }
        for (m in candidates) {
            if (Metadata.collections.containsKey(m.id)) continue
            runCatching { Tmdb.details(m.tmdbId!!, MediaType.MOVIE) }.getOrNull()?.let { d ->
                if (d.collectionId != null && d.collectionName != null) Metadata.collections[m.id] = d.collectionId to d.collectionName
                else Metadata.collections[m.id] = -1 to ""
            }
        }
        // Metadata.collections is a ConcurrentHashMap: safe to read from the background.
        groups = withContext(Dispatchers.Default) {
            all.mapNotNull { m -> Metadata.collections[m.id]?.takeIf { it.first > 0 }?.let { it to m } }
                .groupBy({ it.first }, { it.second }).filter { it.value.size >= 2 }
                .map { (c, movies) -> Triple(c.first, c.second, movies.sortedBy { it.year ?: 0 }) }
                .sortedByDescending { it.third.size }
        }
    }
    Shelf("Collections", groups, subtitle = "Franchises on your server", key = { it.first }) { (id, name, movies) ->
        com.mohamedt.streamforge.ui.LandscapeCard(name, "${movies.size} movies", movies.firstOrNull()?.backdrop ?: movies.firstOrNull()?.poster) {
            nav.push(Screen.Collection(id, name))
        }
    }
}

@Composable
fun CategoryScreen(kind: MediaType, categoryId: String, title: String) {
    var filter by remember { mutableStateOf(VodFilter()) }
    val items = if (kind == MediaType.SERIES) DispatcharrRepo.series(categoryId) else DispatcharrRepo.movies(categoryId)
    var results by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    LaunchedEffect(filter, items) {
        if (filter.query.isNotBlank()) delay(250)
        results = withContext(Dispatchers.Default) { applyFilter(filter, items) }
    }
    PosterGrid(results) {
        Column {
            if (isTv()) {
                FilterBar(kind, filter, null, null, title = title, padded = false) { filter = it }
            } else {
                Text(title, fontSize = 24.sp, fontWeight = FontWeight.Bold)
                FilterBar(kind, filter, null, null, padded = false) { filter = it }
            }
        }
    }
}

@Composable
fun CatalogScreen(entry: Addons.CatalogEntry) {
    var items by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    var genre by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(true) }
    LaunchedEffect(genre) {
        loading = true
        val extra = genre?.let { mapOf("genre" to it) } ?: emptyMap()
        val first = runCatching { Addons.catalog(entry, extra) }.getOrDefault(emptyList()).map { it.toItem(entry.addon.id) }
        items = first
        if (entry.catalog.supportsSkip && first.isNotEmpty()) {
            for (page in 1..4) {
                val more = runCatching { Addons.catalog(entry, extra + ("skip" to items.size.toString())) }.getOrDefault(emptyList()).map { it.toItem(entry.addon.id) }
                val new = more.filter { m -> items.none { it.id == m.id } }
                if (new.isEmpty()) break
                items = items + new
            }
        }
        loading = false
    }
    PosterGrid(items) {
        Column {
            PageTitle(entry.title)
            Text(entry.addon.name, color = Palette.secondary, fontSize = if (isTv()) 17.sp else 14.sp)
            if (entry.catalog.genres.isNotEmpty()) {
                Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = if (isTv()) 14.dp else 8.dp), horizontalArrangement = Arrangement.spacedBy(if (isTv()) 12.dp else 8.dp)) {
                    Chip("All", genre == null) { genre = null }
                    entry.catalog.genres.forEach { g -> Chip(g, genre == g) { genre = g } }
                }
            }
            if (loading) Text("Loading…", color = Palette.secondary)
        }
    }
}
