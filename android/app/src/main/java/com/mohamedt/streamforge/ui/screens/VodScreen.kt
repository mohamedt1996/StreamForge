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
import com.mohamedt.streamforge.ui.PosterCard
import com.mohamedt.streamforge.ui.Screen
import com.mohamedt.streamforge.ui.Shelf
import com.mohamedt.streamforge.ui.isTv
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

enum class VodSort(val label: String) { ADDED("Recently Added"), TITLE("A–Z"), YEAR("Year"), RATING("Rating") }

data class VodFilter(val sort: VodSort = VodSort.ADDED, val genre: String? = null, val decade: Int? = null, val unwatched: Boolean = false, val query: String = "") {
    val active get() = genre != null || decade != null || unwatched || query.isNotBlank()
}

fun applyFilter(f: VodFilter, items: List<MediaItem>): List<MediaItem> {
    val q = f.query.trim().lowercase()
    val out = items.filter { i ->
        (q.isEmpty() || i.title.lowercase().contains(q)) &&
            (f.genre == null || i.genres.any { it.contains(f.genre, ignoreCase = true) }) &&
            (f.decade == null || (i.year != null && i.year >= f.decade && i.year < f.decade + 10)) &&
            (!f.unwatched || !Library.isWatched(i))
    }
    return when (f.sort) {
        VodSort.ADDED -> out.sortedByDescending { it.added ?: 0 }
        VodSort.TITLE -> out.sortedBy { it.title.lowercase() }
        VodSort.YEAR -> out.sortedByDescending { it.year ?: 0 }
        VodSort.RATING -> out.sortedByDescending { it.rating ?: 0.0 }
    }
}

@Composable
private fun FilterBar(kind: MediaType, filter: VodFilter, grid: Boolean?, onGrid: ((Boolean) -> Unit)?, onChange: (VodFilter) -> Unit) {
    val genres = if (kind == MediaType.SERIES) DispatcharrRepo.seriesGenres else DispatcharrRepo.movieGenres
    Column {
        OutlinedTextField(filter.query, { onChange(filter.copy(query = it)) }, Modifier.fillMaxWidth().padding(horizontal = Dims.gutter()),
            placeholder = { Text("Search ${if (kind == MediaType.SERIES) "series" else "movies"}") }, singleLine = true)
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = Dims.gutter(), vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
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
    LazyVerticalGrid(
        columns = GridCells.Adaptive(Dims.poster() + 8.dp),
        contentPadding = PaddingValues(Dims.gutter()),
        horizontalArrangement = Arrangement.spacedBy(if (isTv()) 22.dp else 12.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
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
        LaunchedEffect(filter, all) { results = withContext(Dispatchers.Default) { applyFilter(filter, all) } }
        PosterGrid(results) {
            Column {
                FilterBar(kind, filter, grid, { grid = it }) { filter = it }
                Text("${results.size} ${if (kind == MediaType.SERIES) "series" else "movies"}", fontSize = 12.sp, color = Palette.secondary)
            }
        }
        return
    }

    val sections = if (kind == MediaType.SERIES) DispatcharrRepo.seriesSections else DispatcharrRepo.movieSections
    val active = sections.firstOrNull { it.name == (section ?: sections.firstOrNull()?.name) }
    val open: (MediaItem) -> Unit = { nav.push(Screen.Detail(it)) }

    LazyColumn(Modifier.fillMaxSize()) {
        item { FilterBar(kind, filter, grid, { grid = it }) { filter = it } }
        item {
            val cont = Library.continueWatching.filter { it.item.type == kind && it.item.origin.kind.startsWith("xc") }
            Shelf("Continue Watching", cont, key = { it.key }) { ContinueCard(it) }
        }
        item { Shelf("Recently Added", all.sortedByDescending { it.added ?: 0 }.take(30), seeAll = { grid = true }, key = { it.id }) { PosterCard(it, { open(it) }) } }
        item { Shelf("Top Rated", all.filter { (it.rating ?: 0.0) >= 7.0 }.sortedByDescending { it.rating }.take(30), key = { it.id }) { PosterCard(it, { open(it) }) } }
        item { Shelf("My List", Library.favorites.filter { it.type == kind }, key = { it.id }) { PosterCard(it, { open(it) }) } }
        if (kind == MediaType.MOVIE) item { CollectionsShelf(all) }
        if (sections.size > 1) {
            item {
                Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = Dims.gutter(), vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    sections.forEach { s -> Chip(s.name, active?.name == s.name) { section = s.name } }
                }
            }
        }
        (active?.categories ?: emptyList()).filter { !Library.isHidden("${kind.name}:${it.id}") }.forEach { cat ->
            item(key = "cat-${cat.id}") {
                val items = if (kind == MediaType.SERIES) DispatcharrRepo.series(cat.id) else DispatcharrRepo.movies(cat.id)
                val name = TitleCleaner.splitCategory(cat.name).second
                Shelf(name, items.sortedByDescending { it.added ?: 0 }.take(20), subtitle = "${items.size} titles",
                    seeAll = { nav.push(Screen.Category(kind, cat.id, name)) }, key = { it.id }) { PosterCard(it, { open(it) }) }
            }
        }
        item { Spacer(Modifier.height(30.dp)) }
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
        val candidates = all.filter { it.tmdbId != null }.sortedByDescending { it.rating ?: 0.0 }.take(200)
        for (m in candidates) {
            if (Metadata.collections.containsKey(m.id)) continue
            runCatching { Tmdb.details(m.tmdbId!!, MediaType.MOVIE) }.getOrNull()?.let { d ->
                if (d.collectionId != null && d.collectionName != null) Metadata.collections[m.id] = d.collectionId to d.collectionName
                else Metadata.collections[m.id] = -1 to ""
            }
        }
        groups = all.mapNotNull { m -> Metadata.collections[m.id]?.takeIf { it.first > 0 }?.let { it to m } }
            .groupBy({ it.first }, { it.second }).filter { it.value.size >= 2 }
            .map { (c, movies) -> Triple(c.first, c.second, movies.sortedBy { it.year ?: 0 }) }
            .sortedByDescending { it.third.size }
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
    LaunchedEffect(filter, items) { results = withContext(Dispatchers.Default) { applyFilter(filter, items) } }
    PosterGrid(results) {
        Column {
            Text(title, fontSize = 24.sp, fontWeight = FontWeight.Bold)
            FilterBar(kind, filter, null, null) { filter = it }
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
            Text(entry.title, fontSize = 24.sp, fontWeight = FontWeight.Bold)
            Text(entry.addon.name, color = Palette.secondary)
            if (entry.catalog.genres.isNotEmpty()) {
                Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Chip("All", genre == null) { genre = null }
                    entry.catalog.genres.forEach { g -> Chip(g, genre == g) { genre = g } }
                }
            }
            if (loading) Text("Loading…", color = Palette.secondary)
        }
    }
}
