package com.mohamedt.streamforge.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.mohamedt.streamforge.core.Details
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.MediaType
import com.mohamedt.streamforge.dispatcharr.Channel
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.dispatcharr.GuideRepo
import com.mohamedt.streamforge.dispatcharr.Programme
import com.mohamedt.streamforge.library.Library
import com.mohamedt.streamforge.library.Progress
import com.mohamedt.streamforge.metadata.Metadata
import com.mohamedt.streamforge.metadata.Tmdb
import com.mohamedt.streamforge.player.PlaybackRequest
import com.mohamedt.streamforge.player.PlaybackSource
import com.mohamedt.streamforge.player.Player
import com.mohamedt.streamforge.player.SourceKind
import com.mohamedt.streamforge.stremio.Addons
import com.mohamedt.streamforge.ui.ButtonKind
import com.mohamedt.streamforge.ui.ChannelLogo
import com.mohamedt.streamforge.ui.Dims
import com.mohamedt.streamforge.ui.InitialFocus
import com.mohamedt.streamforge.ui.KeylineScroll
import com.mohamedt.streamforge.ui.LandscapeCard
import com.mohamedt.streamforge.ui.LiveBadge
import com.mohamedt.streamforge.ui.LocalItemFocus
import com.mohamedt.streamforge.ui.LocalNav
import com.mohamedt.streamforge.ui.LocalShelfKey
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.Pill
import com.mohamedt.streamforge.ui.WatchlistCard
import com.mohamedt.streamforge.ui.PosterCard
import com.mohamedt.streamforge.ui.ProgressLine
import com.mohamedt.streamforge.ui.PullRefresh
import com.mohamedt.streamforge.ui.Screen
import com.mohamedt.streamforge.ui.SfButton
import com.mohamedt.streamforge.ui.Shelf
import com.mohamedt.streamforge.ui.TvRowCardOffset
import com.mohamedt.streamforge.ui.card
import com.mohamedt.streamforge.ui.isTv
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Home rows fetched from TMDB and addons; kept across visits so coming back is instant. */
private object HomeData {
    var trendingMovies by mutableStateOf<List<MediaItem>>(emptyList())
    var trendingSeries by mutableStateOf<List<MediaItem>>(emptyList())
    var catalogs by mutableStateOf<List<Pair<Addons.CatalogEntry, List<MediaItem>>>>(emptyList())
}

@Composable
fun HomeScreen(onSearch: () -> Unit, onSettings: () -> Unit) {
    // Re-run when addons change: on first launch Cinemeta is installed in the background after Home is shown.
    LaunchedEffect(Addons.addons) {
        coroutineScope {
            val m = async { if (Tmdb.configured) runCatching { Tmdb.trending(MediaType.MOVIE) }.getOrDefault(emptyList()) else emptyList() }
            val s = async { if (Tmdb.configured) runCatching { Tmdb.trending(MediaType.SERIES) }.getOrDefault(emptyList()) else emptyList() }
            val c = Addons.catalogs.take(8).map { e -> async { e to runCatching { Addons.catalog(e).take(30).map { it.toItem(e.addon.id) } }.getOrDefault(emptyList()) } }
            HomeData.trendingMovies = m.await()
            HomeData.trendingSeries = s.await()
            HomeData.catalogs = c.map { it.await() }.filter { it.second.isNotEmpty() }
        }
    }
    if (isTv()) HomeTv(onSettings) else HomePhone(onSearch, onSettings)
}

// MARK: Phone / tablet

@Composable
private fun HomePhone(onSearch: () -> Unit, onSettings: () -> Unit) {
    val nav = LocalNav.current
    val context = LocalContext.current
    val openDetails: (MediaItem) -> Unit = { nav.push(Screen.Detail(it)) }

    var homeSection by remember { mutableStateOf("Discover") }
    PullRefresh({ DispatcharrRepo.refreshAll(true); GuideRepo.refresh() }) {
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Row(Modifier.fillMaxWidth().padding(horizontal = Dims.gutter(), vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("StreamForge", fontSize = 26.sp, fontWeight = FontWeight.Black, modifier = Modifier.weight(1f))
                IconButton(onClick = onSearch) { Icon(Icons.Filled.Search, "Search") }
                IconButton(onClick = onSettings) { Icon(Icons.Filled.Settings, "Settings") }
            }
        }
        item {
            Row(Modifier.fillMaxWidth().padding(horizontal = Dims.gutter(), vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                listOf("Discover", "My List").forEach { section ->
                    com.mohamedt.streamforge.ui.SfButton(section, { homeSection = section },
                        kind = if (homeSection == section) com.mohamedt.streamforge.ui.ButtonKind.PRIMARY else com.mohamedt.streamforge.ui.ButtonKind.SECONDARY)
                }
            }
        }
        if (homeSection == "My List") {
            if (Library.favorites.isEmpty()) { item {
                Text("Your list starts here. Add a movie or series from its details page.", color = Palette.secondary, modifier = Modifier.padding(Dims.gutter()))
            }
            }
            item { Shelf("Saved movies", Library.favorites.filter { it.type == MediaType.MOVIE }, key = { it.id }) { WatchlistCard(it, { openDetails(it) }) } }
            item { Shelf("Saved series", Library.favorites.filter { it.type == MediaType.SERIES }, key = { it.id }) { WatchlistCard(it, { openDetails(it) }) } }
        } else {
        if (!DispatcharrRepo.isConfigured) {
            item {
                Column(Modifier.padding(Dims.gutter()).fillMaxWidth().background(Palette.surfaceHigh, RoundedCornerShape(18.dp)).padding(20.dp)) {
                    Text("Welcome to StreamForge", fontSize = 22.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(6.dp))
                    Text(WELCOME, color = Palette.secondary)
                    Spacer(Modifier.height(12.dp))
                    Text("Open Settings", color = Palette.accent, fontWeight = FontWeight.Bold, modifier = Modifier.card(onSettings).padding(8.dp))
                }
            }
        }
        item { Shelf("Continue Watching", Library.continueWatching.filter { !it.finished }, key = { it.key }) { p -> ContinueCard(p) } }
        item { Shelf("Up Next", Library.upNext, key = { it.key }) { p -> UpNextCard(p) } }
        item {
            val sports = GuideRepo.liveSports()
            Shelf("Live Sports Now", sports, subtitle = "Matches and events on air", key = { it.first.id }) { (ch, prog) ->
                ChannelTile(ch, prog) { Player.playChannel(context, ch, sports.map { it.first }) }
            }
        }
        item {
            val channels = homeChannels()
            Shelf(if (Library.favoriteChannels.isEmpty()) "Recent Channels" else "Favorite Channels", channels, key = { it.id }) { ch ->
                ChannelTile(ch, GuideRepo.now(ch)) { Player.playChannel(context, ch, channels) }
            }
        }
        item {
            Shelf("Recently Added Movies", recentMovies(), subtitle = DispatcharrRepo.active?.name, key = { it.id }) {
                PosterCard(it, { openDetails(it) }, { Library.toggleFavorite(it) })
            }
        }
        item {
            Shelf("Recently Updated Series", recentSeries(), subtitle = DispatcharrRepo.active?.name, key = { it.id }) {
                PosterCard(it, { openDetails(it) }, { Library.toggleFavorite(it) })
            }
        }
        item { Shelf("My List", Library.favorites, key = { it.id }) { WatchlistCard(it, { openDetails(it) }) } }
        item { Shelf("Trending Movies", HomeData.trendingMovies, subtitle = "This week on TMDB", key = { it.id }) { PosterCard(it, { openDetails(it) }) } }
        item { Shelf("Trending Series", HomeData.trendingSeries, subtitle = "This week on TMDB", key = { it.id }) { PosterCard(it, { openDetails(it) }) } }
        HomeData.catalogs.forEachIndexed { i, (entry, items) ->
            item(key = "cat-$i-${entry.addon.id}-${entry.catalog.type}-${entry.catalog.id}") {
                Shelf(entry.title, items, subtitle = entry.addon.name, seeAll = { nav.push(Screen.Catalog(entry)) }, key = { it.id }) { PosterCard(it, { openDetails(it) }) }
            }
        }
        }
        item { Spacer(Modifier.height(30.dp)) }
    }
    }
}

private const val WELCOME = "Sign in to your Dispatcharr server in Settings for live TV, the guide and your movie and series library. " +
    "Add Stremio addons for more catalogs and streams, and a TMDB key for artwork."

private fun homeChannels(): List<Channel> {
    val ids = Library.favoriteChannels.ifEmpty { Library.recentChannels.take(12) }
    return ids.mapNotNull { DispatcharrRepo.channel(it) }
}

// Pre-sorted off the main thread by DispatcharrRepo (sorting the whole library here ran on every recomposition).
private fun recentMovies() = DispatcharrRepo.recentMovies.take(24)
private fun recentSeries() = DispatcharrRepo.recentSeries.take(24)

// MARK: TV

/** What the billboard shows: the focused card's title, or the featured one before anything is focused. */
private data class Hero(
    val key: String,
    val title: String,
    val logo: String? = null,
    val backdrop: String? = null,
    val meta: List<String> = emptyList(),
    val overview: String? = null,
    val item: MediaItem? = null,
    val progress: Progress? = null,
    val channel: Channel? = null,
    val note: String? = null,
)

private fun runtimeText(minutes: Int): String = if (minutes >= 60) "${minutes / 60}h ${minutes % 60}m" else "${minutes}m"

private fun itemMeta(i: MediaItem): List<String> = listOfNotNull(
    i.year?.toString(),
    i.rating?.takeIf { it > 0 }?.let { "★ %.1f".format(it) },
    i.runtimeMinutes?.takeIf { it > 0 }?.let { runtimeText(it) },
    i.genres.take(3).joinToString(", ").ifEmpty { null },
)

private fun heroOf(i: MediaItem) = Hero("i:${i.id}", i.title, i.logo, i.backdrop ?: i.poster, itemMeta(i), i.overview, item = i)

private fun heroOf(p: Progress): Hero {
    val i = p.item
    val note = p.episode?.let { "${it.code}  ${it.title}" }
    return Hero("p:${p.key}", i.title, i.logo, i.backdrop ?: p.episode?.still ?: i.poster, itemMeta(i),
        p.episode?.overview ?: i.overview, item = i, progress = p, note = note)
}

private fun heroOf(ch: Channel, now: Programme?): Hero = Hero(
    "c:${ch.id}", now?.title?.ifBlank { null } ?: ch.name, null, null,
    listOfNotNull(ch.name, now?.let { "${timeText(it.start)} – ${timeText(it.end)}" }),
    now?.desc, channel = ch,
)

private class HomeRow(val key: String, val content: @Composable () -> Unit)

/** Billboard state. Only the billboard and backdrop read it, so moving focus doesn't recompose the rows. */
private class HeroState {
    var focused by mutableStateOf<Hero?>(null)
    var enriched by mutableStateOf<Pair<String, Details>?>(null)
}

/** The hero to show, merged with richer metadata when it has arrived. */
private class HeroView(val hero: Hero?, val backdrop: String?, val logo: String?, val meta: List<String>, val overview: String?)

private fun HeroState.view(featured: Hero?): HeroView {
    val hero = focused ?: featured
    val rich = enriched?.takeIf { it.first == hero?.item?.id }?.second?.item
    return HeroView(
        hero,
        rich?.backdrop ?: hero?.backdrop,
        rich?.logo ?: hero?.logo,
        rich?.let { itemMeta(it) }?.takeIf { it.isNotEmpty() } ?: hero?.meta.orEmpty(),
        hero?.overview ?: rich?.overview,
    )
}

/**
 * Google TV-style home: a billboard for the focused title (its backdrop crossfading in behind) on
 * top, rows below that keep the focused row and card on fixed keylines.
 */
@Composable
private fun HomeTv(onSettings: () -> Unit) {
    val nav = LocalNav.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val playFocus = remember { FocusRequester() }
    val heroState = remember { HeroState() }
    var rowsFocused by remember { mutableStateOf(false) }
    var forceButtons by remember { mutableStateOf(false) }
    var focusedRow by remember { mutableIntStateOf(-1) }
    val listState = rememberLazyListState()

    val resume = Library.continueWatching.filter { !it.finished }
    val upNext = Library.upNext
    val sports = GuideRepo.liveSports()
    val channels = homeChannels()
    val movies = recentMovies()
    val series = recentSeries()
    val open: (MediaItem) -> Unit = { nav.push(Screen.Detail(it)) }
    val focus: (Hero) -> Unit = { heroState.focused = it }

    val featured: Hero? = resume.firstOrNull()?.let { heroOf(it) }
        ?: (Library.favorites + HomeData.trendingMovies + HomeData.catalogs.flatMap { it.second } + movies)
            .firstOrNull()?.let { heroOf(it) }

    val rows = buildList {
        if (resume.isNotEmpty()) add(HomeRow("resume") {
            Shelf("Continue watching", resume, key = { it.key }, rowKey = "resume") { p ->
                CompositionLocalProvider(LocalItemFocus provides { _ -> focus(heroOf(p)) }) { ContinueCard(p) }
            }
        })
        if (upNext.isNotEmpty()) add(HomeRow("upnext") {
            Shelf("Up next", upNext, key = { it.key }, rowKey = "upnext") { p ->
                CompositionLocalProvider(LocalItemFocus provides { _ -> focus(heroOf(p)) }) { UpNextCard(p) }
            }
        })
        if (sports.isNotEmpty()) add(HomeRow("sports") {
            Shelf("Live sports now", sports, subtitle = "Matches and events on air", key = { it.first.id }, rowKey = "sports") { (ch, prog) ->
                ChannelTile(ch, prog, onFocused = { focus(heroOf(ch, prog)) }) { Player.playChannel(context, ch, sports.map { it.first }) }
            }
        })
        if (channels.isNotEmpty()) add(HomeRow("channels") {
            Shelf(if (Library.favoriteChannels.isEmpty()) "Recent channels" else "Favorite channels", channels, key = { it.id }, rowKey = "channels") { ch ->
                ChannelTile(ch, GuideRepo.now(ch), onFocused = { focus(heroOf(ch, GuideRepo.now(ch))) }) { Player.playChannel(context, ch, channels) }
            }
        })
        if (Library.favorites.isNotEmpty()) add(HomeRow("mylist") {
            Shelf("My List", Library.favorites, key = { it.id }, rowKey = "mylist") { WatchlistCard(it, { open(it) }) }
        })
        if (movies.isNotEmpty()) add(HomeRow("movies") {
            Shelf("Recently added movies", movies, subtitle = DispatcharrRepo.active?.name, key = { it.id }, rowKey = "movies") {
                PosterCard(it, { open(it) }, { Library.toggleFavorite(it) })
            }
        })
        if (series.isNotEmpty()) add(HomeRow("series") {
            Shelf("Recently updated series", series, subtitle = DispatcharrRepo.active?.name, key = { it.id }, rowKey = "series") {
                PosterCard(it, { open(it) }, { Library.toggleFavorite(it) })
            }
        })
        if (HomeData.trendingMovies.isNotEmpty()) add(HomeRow("tmovies") {
            Shelf("Trending movies", HomeData.trendingMovies, subtitle = "This week on TMDB", key = { it.id }, rowKey = "tmovies") { PosterCard(it, { open(it) }) }
        })
        if (HomeData.trendingSeries.isNotEmpty()) add(HomeRow("tseries") {
            Shelf("Trending series", HomeData.trendingSeries, subtitle = "This week on TMDB", key = { it.id }, rowKey = "tseries") { PosterCard(it, { open(it) }) }
        })
        HomeData.catalogs.forEachIndexed { i, (entry, items) ->
            val k = "cat-$i-${entry.addon.id}-${entry.catalog.type}-${entry.catalog.id}"
            add(HomeRow(k) {
                Shelf(entry.title, items, subtitle = entry.addon.name, seeAll = { nav.push(Screen.Catalog(entry)) }, key = { it.id }, rowKey = k) {
                    PosterCard(it, { open(it) })
                }
            })
        }
    }

    InitialFocus(playFocus, key = featured != null)
    HeroEnricher(heroState, featured)

    // Poster rows report plain items; channel and progress rows override this locally.
    CompositionLocalProvider(LocalItemFocus provides { item -> focus(heroOf(item)) }) {
        Box(Modifier.fillMaxSize()) {
            HeroBackdrop(heroState, featured, Modifier.align(Alignment.TopEnd).fillMaxWidth(0.82f).fillMaxHeight(0.84f))
            Column(Modifier.fillMaxSize()) {
                Billboard(
                    heroState, featured, visible = !rowsFocused || forceButtons, playFocus = playFocus,
                    onButtonFocus = { f -> if (f) forceButtons = false },
                    onSettings = onSettings, channels = channels,
                )
                Spacer(Modifier.height(8.dp))
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    KeylineScroll(TvRowCardOffset) {
                        LazyColumn(
                            Modifier.fillMaxSize()
                                .onFocusChanged { rowsFocused = it.hasFocus }
                                .onPreviewKeyEvent { e ->
                                    // Up from the first row brings the billboard buttons back and focuses Play.
                                    if (e.type == KeyEventType.KeyDown && e.key == Key.DirectionUp && rowsFocused && focusedRow == 0) {
                                        forceButtons = true
                                        scope.launch {
                                            delay(40)
                                            runCatching { playFocus.requestFocus() }
                                        }
                                        true
                                    } else {
                                        false
                                    }
                                },
                            state = listState,
                            contentPadding = PaddingValues(bottom = 160.dp),
                        ) {
                            itemsIndexed(rows, key = { _, r -> r.key }) { index, row ->
                                Box(Modifier.onFocusChanged { if (it.hasFocus) focusedRow = index }) { row.content() }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Fetches backdrop / logo / overview for the hero once focus has rested on it. */
@Composable
private fun HeroEnricher(state: HeroState, featured: Hero?) {
    val target = (state.focused ?: featured)?.item
    LaunchedEffect(target?.id) {
        val t = target ?: return@LaunchedEffect
        if (state.enriched?.first == t.id) return@LaunchedEffect
        delay(450)
        runCatching { Metadata.details(t) }.getOrNull()?.let { state.enriched = t.id to it }
    }
}

@Composable
private fun HeroBackdrop(state: HeroState, featured: Hero?, modifier: Modifier) {
    val backdrop = state.view(featured).backdrop
    Box(modifier) {
        Crossfade(targetState = backdrop, animationSpec = tween(650), label = "home-backdrop") { url ->
            if (url != null) {
                AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            } else {
                Box(Modifier.fillMaxSize().background(Brush.radialGradient(listOf(Palette.accent.copy(alpha = 0.22f), Color.Transparent))))
            }
        }
        Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(
            0f to Palette.background, 0.3f to Palette.background.copy(alpha = 0.75f), 0.65f to Color.Transparent)))
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(
            0f to Palette.background.copy(alpha = 0.35f), 0.25f to Color.Transparent, 0.62f to Color.Transparent, 1f to Palette.background)))
    }
}

@Composable
private fun Billboard(
    state: HeroState,
    featured: Hero?,
    visible: Boolean,
    playFocus: FocusRequester,
    onButtonFocus: (Boolean) -> Unit,
    onSettings: () -> Unit,
    channels: List<Channel>,
) {
    val nav = LocalNav.current
    val context = LocalContext.current
    val v = state.view(featured)
    val hero = v.hero
    // Fixed heights, so the rows underneath never jump while the title changes.
    Column(Modifier.padding(start = Dims.gutter(), end = Dims.gutter(), top = Dims.overscanY + 8.dp).fillMaxWidth(0.56f)) {
        Box(Modifier.height(92.dp).fillMaxWidth(), contentAlignment = Alignment.BottomStart) {
            if (hero == null) {
                Text("Welcome to StreamForge", fontSize = 40.sp, fontWeight = FontWeight.Black, lineHeight = 44.sp, maxLines = 2)
            } else if (v.logo != null) {
                AsyncImage(model = v.logo, contentDescription = hero.title, contentScale = ContentScale.Fit, alignment = Alignment.BottomStart,
                    modifier = Modifier.widthIn(max = 380.dp).fillMaxHeight())
            } else {
                Text(hero.title, fontSize = if (hero.title.length > 26) 32.sp else 40.sp, fontWeight = FontWeight.Black,
                    lineHeight = 42.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
        Spacer(Modifier.height(10.dp))
        Row(Modifier.height(28.dp), verticalAlignment = Alignment.CenterVertically) {
            if (hero?.channel != null) {
                LiveBadge()
                Spacer(Modifier.width(10.dp))
            }
            hero?.progress?.let { p ->
                Pill(p.remainingText, Palette.accent.copy(alpha = 0.35f))
                Spacer(Modifier.width(10.dp))
            }
            Text(v.meta.joinToString("  ·  "), fontSize = 17.sp, color = Palette.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Box(Modifier.height(58.dp)) {
            val text = when {
                hero == null -> WELCOME
                hero.note != null && v.overview != null -> "${hero.note}. ${v.overview}"
                else -> hero.note ?: v.overview ?: ""
            }
            Text(text, fontSize = 18.sp, lineHeight = 25.sp, color = Color.White.copy(alpha = 0.86f), maxLines = 2, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 6.dp))
        }
        AnimatedVisibility(visible, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
            Row(Modifier.padding(top = 14.dp, bottom = 6.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                val progress = hero?.progress
                val channel = hero?.channel
                val item = hero?.item
                when {
                    progress != null -> {
                        SfButton("Resume", { resumePlayback(context, nav, progress) }, icon = Icons.Filled.PlayArrow,
                            kind = ButtonKind.PRIMARY, focusRequester = playFocus, onFocus = onButtonFocus)
                        SfButton("More info", { nav.push(Screen.Detail(progress.item)) }, icon = Icons.Filled.Info, onFocus = onButtonFocus)
                    }
                    channel != null -> {
                        SfButton("Watch live", { Player.playChannel(context, channel, channels.ifEmpty { listOf(channel) }) }, icon = Icons.Filled.PlayArrow,
                            kind = ButtonKind.PRIMARY, focusRequester = playFocus, onFocus = onButtonFocus)
                        SfButton("TV guide", { nav.push(Screen.Guide) }, icon = Icons.Filled.CalendarMonth, onFocus = onButtonFocus)
                    }
                    item != null -> {
                        SfButton("Play", { nav.push(Screen.Detail(item, autoPlay = true)) }, icon = Icons.Filled.PlayArrow,
                            kind = ButtonKind.PRIMARY, focusRequester = playFocus, onFocus = onButtonFocus)
                        SfButton("More info", { nav.push(Screen.Detail(item)) }, icon = Icons.Filled.Info, onFocus = onButtonFocus)
                    }
                    else -> SfButton("Open Settings", onSettings, icon = Icons.Filled.Settings, kind = ButtonKind.PRIMARY,
                        focusRequester = playFocus, onFocus = onButtonFocus)
                }
            }
        }
    }
}

/** Resume a Continue Watching entry: straight from the server when possible, else via the detail page. */
private fun resumePlayback(context: android.content.Context, nav: com.mohamedt.streamforge.ui.Navigator, p: Progress) {
    val client = DispatcharrRepo.playbackClient(p.item)
    val ep = p.episode
    val url = when {
        ep?.xcEpisodeId != null && client != null -> client.episodeUrl(ep.xcEpisodeId, ep.ext ?: "mp4")
        ep == null && p.item.origin.kind == "xc-movie" && client != null -> client.movieUrl(p.item.origin.id, p.item.origin.ext ?: "mp4")
        else -> null
    }
    if (url != null) {
        Player.play(context, PlaybackRequest(p.item, ep, PlaybackSource("resume", SourceKind.Direct(url), p.item.title, provider = "Server"), maxOf(0L, p.position - 5000)))
    } else {
        nav.push(Screen.Detail(p.item, autoPlay = true))
    }
}

@Composable
fun ContinueCard(p: Progress) {
    val nav = LocalNav.current
    val context = LocalContext.current
    LandscapeCard(p.item.title, p.episode?.let { "${it.code} · ${p.remainingText}" } ?: p.remainingText,
        p.episode?.still ?: p.item.backdrop ?: p.item.poster, p.fraction, item = p.item, focusId = p.key) {
        resumePlayback(context, nav, p)
    }
}

@Composable
fun UpNextCard(p: Progress) {
    val nav = LocalNav.current
    LandscapeCard(p.item.title, p.episode?.let { "After ${it.code}" }, p.item.backdrop ?: p.episode?.still ?: p.item.poster,
        badge = "UP NEXT", item = p.item, focusId = p.key) {
        nav.push(Screen.Detail(p.item))
    }
}

@Composable
fun ChannelTile(ch: Channel, now: Programme?, onFocused: (() -> Unit)? = null, onClick: () -> Unit) {
    val tv = isTv()
    val shelf = LocalShelfKey.current
    Column(
        Modifier.width(Dims.landscape() * if (tv) 1f else 0.9f)
            .card(onClick, shape = RoundedCornerShape(if (tv) 16.dp else 14.dp), dimUnfocused = true,
                focusKey = shelf?.let { "$it/ch${ch.id}" }, onFocus = { f -> if (f) onFocused?.invoke() })
            .background(if (tv) Palette.surfaceHigh else Palette.surface)
            .padding(if (tv) 16.dp else 12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            ChannelLogo(ch.icon, ch.name, if (tv) 60.dp else 42.dp)
            Spacer(Modifier.width(if (tv) 14.dp else 10.dp))
            Column {
                Text(ch.name, fontWeight = FontWeight.SemiBold, fontSize = if (tv) 18.sp else 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(now?.title ?: "Live", fontSize = if (tv) 15.sp else 12.sp, color = Palette.secondary, maxLines = if (tv) 2 else 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Spacer(Modifier.height(if (tv) 12.dp else 8.dp))
        Box(Modifier.fillMaxWidth()) { if (now != null) ProgressLine(now.progress, height = if (tv) 4.dp else 3.dp) }
    }
    LaunchedEffect(ch.id) { GuideRepo.ensure(ch) }
}
