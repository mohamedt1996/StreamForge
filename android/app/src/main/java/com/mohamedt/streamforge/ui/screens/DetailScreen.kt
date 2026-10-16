package com.mohamedt.streamforge.ui.screens

import android.content.Intent
import android.net.Uri
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.verticalScroll
import com.mohamedt.streamforge.ui.isExpandedWidth
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CollectionsBookmark
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mohamedt.streamforge.core.Details
import com.mohamedt.streamforge.core.Episode
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.MediaType
import com.mohamedt.streamforge.core.byteText
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.dispatcharr.toItem
import com.mohamedt.streamforge.library.Library
import com.mohamedt.streamforge.metadata.Metadata
import com.mohamedt.streamforge.metadata.Tmdb
import com.mohamedt.streamforge.player.PlaybackRequest
import com.mohamedt.streamforge.player.PlaybackSource
import com.mohamedt.streamforge.player.Player
import com.mohamedt.streamforge.player.SourceKind
import com.mohamedt.streamforge.player.SourcesModel
import com.mohamedt.streamforge.torrent.StartEstimator
import com.mohamedt.streamforge.ui.Artwork
import com.mohamedt.streamforge.ui.ButtonKind
import com.mohamedt.streamforge.ui.Chip
import com.mohamedt.streamforge.ui.Dims
import com.mohamedt.streamforge.ui.InitialFocus
import com.mohamedt.streamforge.ui.CriticScores
import com.mohamedt.streamforge.ui.ImdbBadge
import com.mohamedt.streamforge.ui.KeylineScroll
import com.mohamedt.streamforge.ui.MinimalScroll
import com.mohamedt.streamforge.ui.Loading
import com.mohamedt.streamforge.ui.LocalNav
import com.mohamedt.streamforge.ui.LocalShelfKey
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.Pill
import com.mohamedt.streamforge.ui.PosterCard
import com.mohamedt.streamforge.ui.ProgressLine
import com.mohamedt.streamforge.ui.Screen
import com.mohamedt.streamforge.ui.SectionHeader
import com.mohamedt.streamforge.ui.SfButton
import com.mohamedt.streamforge.ui.SfDialog
import com.mohamedt.streamforge.ui.Shelf
import com.mohamedt.streamforge.ui.TrailerButton
import com.mohamedt.streamforge.ui.TrailerController
import com.mohamedt.streamforge.ui.TrailerPolicy
import com.mohamedt.streamforge.ui.TrailerSurface
import com.mohamedt.streamforge.ui.rememberTrailerController
import com.mohamedt.streamforge.ui.card
import com.mohamedt.streamforge.ui.isTv
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import coil3.compose.AsyncImage
import kotlinx.coroutines.launch

private fun runtimeLabel(minutes: Int): String = "${minutes / 60}h ${minutes % 60}m".removePrefix("0h ")

@Composable
fun DetailScreen(initial: MediaItem, autoPlay: Boolean = false) {
    val nav = LocalNav.current
    val context = LocalContext.current
    val tv = isTv()
    var details by remember { mutableStateOf<Details?>(null) }
    var season by remember { mutableStateOf<Int?>(null) }
    var episodes by remember { mutableStateOf<List<Episode>>(emptyList()) }
    var sources by remember { mutableStateOf<SourcesModel?>(null) }
    var picker by remember { mutableStateOf<Pair<Episode?, List<Episode>>?>(null) }
    var advanced by remember { mutableStateOf(false) }
    var autoPlayed by rememberSaveable { mutableStateOf(false) }

    // Hero trailer (Netflix-style): backdrop first, muted video ~2.5 s after the page opened,
    // paused while the hero is scrolled away, the app isn't in front (a player activity is on
    // top, or it's in the background) or the sources dialog covers it.
    val listState = rememberLazyListState()
    val trailer = rememberTrailerController()
    val shownAt = remember { System.currentTimeMillis() }
    val config = LocalConfiguration.current
    // Phones in landscape are short: the hero never takes more than ~60 % of the height.
    val heroHeight = if (tv) (config.screenHeightDp * 0.7f).dp else minOf(300.dp, (config.screenHeightDp * 0.6f).dp).coerceAtLeast(180.dp)
    val heroPx = with(LocalDensity.current) { heroHeight.toPx() }
    val heroVisible by remember(heroPx) {
        derivedStateOf { listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset < heroPx * 0.55f }
    }
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val trailerActive = heroVisible && picker == null && lifecycleState.isAtLeast(Lifecycle.State.RESUMED)
    LaunchedEffect(trailerActive) { trailer.updateActive(trailerActive) }
    LaunchedEffect(details?.trailerKeys) {
        val keys = details?.trailerKeys ?: return@LaunchedEffect
        val elapsed = System.currentTimeMillis() - shownAt
        trailer.updateKeys(keys, (TrailerPolicy.START_DELAY_MS - elapsed).coerceAtLeast(400L))
    }

    LaunchedEffect(initial.id) {
        val d = Metadata.details(initial)
        details = d
        // Faces for cast lists that came as plain names; runs alongside sources/episodes.
        launch {
            val withFaces = Metadata.castWithPhotos(d)
            if (withFaces !== d && details?.item?.id == d.item.id) details = details?.copy(cast = withFaces.cast)
        }
        if (d.item.type == MediaType.SERIES) {
            val resume = Library.latestEpisode(d.item)?.episode?.season ?: Library.lastWatchedEpisode(d.item)?.episode?.season
            season = resume ?: d.seasons.firstOrNull { it > 0 } ?: d.seasons.firstOrNull() ?: 1
        } else if (d.item.type == MediaType.MOVIE) {
            val s = SourcesModel(d.item, null)
            sources = s
            s.load()
        }
    }
    // Keyed on the title, not the whole Details, so filling in cast photos doesn't refetch episodes.
    LaunchedEffect(season, details?.item?.id) {
        val d = details ?: return@LaunchedEffect
        val s = season ?: return@LaunchedEffect
        val eps = Metadata.episodes(d, s)
        episodes = eps
        // Finished the last episode of a season: open on the next season.
        if (!advanced && eps.isNotEmpty() && Library.latestEpisode(d.item) == null) {
            advanced = true
            val last = Library.lastWatchedEpisode(d.item)?.episode
            if (last != null && last.season == s && eps.none { it.episode > last.episode }) {
                d.seasons.firstOrNull { it > s }?.let { season = it }
            }
        }
    }

    val d = details
    if (d == null) { Loading(); return }
    val item = d.item

    fun play(ep: Episode) {
        val upcoming = episodes.dropWhile { it.id != ep.id }.drop(1)
        val url = ep.xcEpisodeId?.let { id -> DispatcharrRepo.playbackClient(item)?.episodeUrl(id, ep.ext ?: "mp4") }
        if (ep.xcEpisodeId != null && url != null) {
            Player.play(context, PlaybackRequest(item, ep, PlaybackSource("xc-ep-${ep.xcEpisodeId}", SourceKind.Direct(url),
                "${item.title} ${ep.code}", provider = DispatcharrRepo.playbackClient(item)?.server?.name ?: "Server", cached = true), upcoming = upcoming))
        } else {
            picker = ep to upcoming
        }
    }

    val nextEp: Episode? = run {
        val p = Library.latestEpisode(item)
        p?.episode?.let { e -> episodes.firstOrNull { it.season == e.season && it.episode == e.episode && !p.finished } }
            ?: Library.lastWatchedEpisode(item)?.episode?.let { last ->
                episodes.firstOrNull { (it.season > last.season || (it.season == last.season && it.episode > last.episode)) && !Library.isWatched(item, it) }
            }
            ?: episodes.firstOrNull { !Library.isWatched(item, it) } ?: episodes.firstOrNull()
    }

    fun playPrimary() {
        if (item.type == MediaType.SERIES) {
            nextEp?.let { play(it) }
        } else {
            val best = sources?.sorted?.firstOrNull()
            if (best != null && (best.cached || sources?.sorted?.size == 1)) Player.play(context, PlaybackRequest(item, source = best))
            else picker = null to emptyList()
        }
    }

    // "Play" on the Home billboard: start as soon as there is something to play.
    val sourceCount = sources?.sorted?.size ?: 0
    val sourcesLoading = sources?.loading == true
    LaunchedEffect(autoPlay, item.id, episodes, sourceCount, sourcesLoading) {
        if (!autoPlay || autoPlayed) return@LaunchedEffect
        when (item.type) {
            MediaType.SERIES -> if (episodes.isNotEmpty()) {
                autoPlayed = true
                playPrimary()
            }
            MediaType.MOVIE -> {
                val s = sources ?: return@LaunchedEffect
                if (s.sorted.any { it.cached } || !s.loading) {
                    autoPlayed = true
                    playPrimary()
                }
            }
            MediaType.CHANNEL, MediaType.OTHER -> autoPlayed = true
        }
    }

    val playLabel = when {
        item.type == MediaType.SERIES -> nextEp?.let { e -> if ((Library.progress(item, e)?.fraction ?: 0f) > 0.02f) "Resume ${e.code}" else "Play ${e.code}" } ?: "Play"
        (Library.progress(item)?.fraction ?: 0f) > 0.02f -> "Resume · ${Library.progress(item)?.remainingText}"
        sources?.loading == true && sources?.sorted?.isEmpty() == true -> "Finding sources…"
        else -> "Play"
    }
    val openTrailer: (() -> Unit)? = d.trailerKey?.let { key ->
        fun() {
            runCatching {
                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://www.youtube.com/watch?v=$key")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
        }
    }

    if (tv) {
        DetailTv(
            d = d, episodes = episodes, season = season, nextEp = nextEp, sources = sources, listState = listState, trailer = trailer,
            playLabel = playLabel, onPlay = { playPrimary() }, onPlayEpisode = { play(it) }, onSeason = { season = it },
            onSources = { picker = if (item.type == MediaType.SERIES) nextEp?.let { e -> e to episodes.dropWhile { it.id != e.id }.drop(1) } else (null to emptyList()) },
            onTrailer = openTrailer,
        )
    } else {
        DetailPhone(
            d = d, episodes = episodes, season = season, nextEp = nextEp, sources = sources, listState = listState, trailer = trailer,
            heroHeight = heroHeight, playLabel = playLabel, onPlay = { playPrimary() }, onPlayEpisode = { play(it) }, onSeason = { season = it },
            onAllSources = { picker = null to emptyList() }, onTrailer = openTrailer,
        )
    }

    picker?.let { (ep, upcoming) ->
        SourcesDialog(item, ep, onDismiss = { picker = null }) { src ->
            picker = null
            Player.play(context, PlaybackRequest(item, ep, src, upcoming = upcoming))
        }
    }
}

// MARK: Phone / tablet

@Composable
private fun DetailPhone(
    d: Details,
    episodes: List<Episode>,
    season: Int?,
    nextEp: Episode?,
    sources: SourcesModel?,
    listState: androidx.compose.foundation.lazy.LazyListState,
    trailer: TrailerController,
    heroHeight: Dp,
    playLabel: String,
    onPlay: () -> Unit,
    onPlayEpisode: (Episode) -> Unit,
    onSeason: (Int) -> Unit,
    onAllSources: () -> Unit,
    onTrailer: (() -> Unit)?,
) {
    val nav = LocalNav.current
    val context = LocalContext.current
    val item = d.item
    val body: LazyListScope.() -> Unit = {
        phoneBody(d, episodes, season, sources, onPlayEpisode, onSeason, onAllSources,
            onOpen = { nav.push(Screen.Detail(it)) },
            onPlaySource = { src -> Player.play(context, PlaybackRequest(item, source = src)) })
    }
    if (isExpandedWidth()) {
        // Tablets in landscape: artwork, title and actions on the left, episodes / sources / cast on the right.
        Row(Modifier.fillMaxSize()) {
            Column(Modifier.weight(0.44f).fillMaxHeight().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
                PhoneHero(item, trailer, Modifier.fillMaxWidth().aspectRatio(16f / 9f), compact = false,
                    imdbRating = d.imdbRating, rottenTomatoes = d.rottenTomatoes, metacritic = d.metacritic)
                PhoneActions(item, playLabel, onPlay, onTrailer)
                PhoneOverview(item, maxLines = 12)
            }
            LazyColumn(Modifier.weight(0.56f).fillMaxHeight(), state = rememberLazyListState(), contentPadding = PaddingValues(top = 8.dp)) {
                body()
            }
        }
    } else {
        LazyColumn(Modifier.fillMaxSize(), state = listState) {
            item(key = "hero") { PhoneHero(item, trailer, Modifier.fillMaxWidth().aspectRatio(16f / 9f), compact = heroHeight < 240.dp,
                imdbRating = d.imdbRating, rottenTomatoes = d.rottenTomatoes, metacritic = d.metacritic) }
            item(key = "actions") { PhoneActions(item, playLabel, onPlay, onTrailer) }
            item(key = "overview") { PhoneOverview(item, maxLines = 6) }
            body()
        }
    }
}

@Composable
private fun PhoneHero(
    item: MediaItem,
    trailer: TrailerController,
    modifier: Modifier,
    compact: Boolean,
    imdbRating: Double? = null,
    rottenTomatoes: String? = null,
    metacritic: String? = null,
) {
    Column {
        Box(modifier) {
            Artwork(item.backdrop ?: item.poster, Modifier.fillMaxSize())
            TrailerSurface(trailer, Modifier.fillMaxSize())
            TrailerButton(trailer, Modifier.align(Alignment.BottomEnd).padding(16.dp))
        }
        Column(Modifier.fillMaxWidth().padding(horizontal = Dims.gutter(), vertical = 20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(item.title, fontSize = if (compact) 26.sp else 32.sp, fontWeight = FontWeight.Bold)
            if (imdbRating != null || rottenTomatoes != null || metacritic != null) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    imdbRating?.let { ImdbBadge(it) }
                    CriticScores(rottenTomatoes, metacritic)
                }
            }
            Text(metaLine(item, hideRating = imdbRating != null).joinToString("  ·  "), color = Palette.secondary, fontSize = 14.sp,
                maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun PhoneActions(item: MediaItem, playLabel: String, onPlay: () -> Unit, onTrailer: (() -> Unit)?) {
    Column(Modifier.fillMaxWidth().padding(horizontal = Dims.gutter()).padding(bottom = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).card(onPlay, shape = RoundedCornerShape(14.dp))
            .background(Palette.accent).padding(horizontal = 20.dp, vertical = 16.dp),
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.PlayArrow, null)
            Spacer(Modifier.width(8.dp))
            Text(playLabel, fontWeight = FontWeight.Bold)
        }
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            SfButton(if (Library.isFavorite(item)) "In My List" else "My List", { Library.toggleFavorite(item) },
                icon = if (Library.isFavorite(item)) Icons.Filled.Check else Icons.Filled.Add)
            if (onTrailer != null) SfButton("Trailer", onTrailer, icon = Icons.Filled.Movie)
        }
    }
}

@Composable
private fun PhoneOverview(item: MediaItem, maxLines: Int) {
    val nav = LocalNav.current
    Column {
        item.overview?.let {
            Text(it, Modifier.padding(horizontal = Dims.gutter()).widthIn(max = 820.dp), color = Color.White.copy(alpha = 0.85f),
                maxLines = maxLines, overflow = TextOverflow.Ellipsis, lineHeight = 20.sp)
        }
        Metadata.collections[item.id]?.takeIf { it.first > 0 }?.let { (cid, cname) ->
            Text("Part of the $cname →", color = Palette.accent, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(horizontal = Dims.gutter() - 6.dp, vertical = 6.dp).card({ nav.push(Screen.Collection(cid, cname)) })
                    .padding(horizontal = 6.dp, vertical = 12.dp))
        }
    }
}

/** Seasons, episodes, sources, cast and "More like this" (phone and tablet). */
private fun LazyListScope.phoneBody(
    d: Details,
    episodes: List<Episode>,
    season: Int?,
    sources: SourcesModel?,
    onPlayEpisode: (Episode) -> Unit,
    onSeason: (Int) -> Unit,
    onAllSources: () -> Unit,
    onOpen: (MediaItem) -> Unit,
    onPlaySource: (PlaybackSource) -> Unit,
) {
    val item = d.item
    if (item.type == MediaType.SERIES) {
        item(key = "seasons") {
            LazyRow(contentPadding = PaddingValues(horizontal = Dims.gutter(), vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                itemsIndexed(d.seasons.distinct(), key = { _, s -> s }) { _, s -> Chip(if (s == 0) "Specials" else "Season $s", season == s) { onSeason(s) } }
            }
        }
        episodes.distinctBy { it.id }.forEach { ep -> item(key = "ep-${ep.id}") { EpisodeRow(item, ep) { onPlayEpisode(ep) } } }
    }
    if (item.type == MediaType.MOVIE) {
        item(key = "sources-head") {
            val s = sources
            Column(Modifier.padding(horizontal = Dims.gutter(), vertical = 10.dp)) {
                Text("Sources", fontSize = 20.sp, fontWeight = FontWeight.Bold)
                if (s == null || (s.loading && s.sources.isEmpty())) Text("Asking your server and addons…", color = Palette.secondary)
                else if (s.sorted.isEmpty()) Text("No sources found. Add stream addons in Settings.", color = Palette.secondary)
            }
        }
        sources?.sorted?.take(8)?.forEach { src ->
            item(key = "src-${src.id}") { SourceRow(src, sources?.estimate(src)) { onPlaySource(src) } }
        }
        if ((sources?.sorted?.size ?: 0) > 8) item(key = "sources-all") {
            Text("All ${sources?.sorted?.size} sources →", color = Palette.accent,
                modifier = Modifier.padding(horizontal = Dims.gutter() - 6.dp, vertical = 8.dp).card(onAllSources).padding(horizontal = 6.dp, vertical = 12.dp))
        }
    }
    if (d.cast.isNotEmpty()) item(key = "cast") {
        Shelf("Cast", d.cast, key = { it.id }) { person -> CastCard(person) }
    }
    item(key = "similar") { Shelf("More Like This", d.similar, key = { it.id }) { PosterCard(it, { onOpen(it) }) } }
    item(key = "bottom") { Spacer(Modifier.height(40.dp)) }
}

/** Year · ★ rating · runtime · genres. [hideRating]: the IMDb badge is shown instead of the star rating. */
private fun metaLine(item: MediaItem, hideRating: Boolean = false): List<String> = listOfNotNull(
    item.year?.toString(),
    item.rating?.takeIf { it > 0 && !hideRating }?.let { "★ %.1f".format(it) },
    item.runtimeMinutes?.takeIf { it > 0 }?.let { runtimeLabel(it) },
    item.genres.take(3).joinToString(", ").ifEmpty { null },
)

@Composable
private fun EpisodeRow(item: MediaItem, ep: Episode, onPlay: () -> Unit) {
    val p = Library.progress(item, ep)
    Row(Modifier.fillMaxWidth().padding(horizontal = Dims.gutter(), vertical = 5.dp).card(onPlay, { Library.setWatched(item, ep, !Library.isWatched(item, ep)) }, RoundedCornerShape(14.dp))
        .background(Palette.surface).padding(8.dp)) {
        Box(Modifier.width(140.dp).aspectRatio(16f / 9f).clip(RoundedCornerShape(10.dp))) {
            Artwork(ep.still ?: item.backdrop, Modifier.fillMaxSize())
            p?.let { ProgressLine(it.fraction, Modifier.align(Alignment.BottomCenter).padding(6.dp)) }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("${ep.episode}. ${ep.title}", fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                if (Library.isWatched(item, ep)) Icon(Icons.Filled.Check, null, tint = Palette.accent)
            }
            Text(listOfNotNull(ep.airDate, ep.runtimeMinutes?.let { "${it}m" }, if (ep.xcEpisodeId != null) "On server" else null).joinToString(" · "),
                fontSize = 11.sp, color = Palette.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            ep.overview?.let { Text(it, fontSize = 12.sp, color = Palette.secondary, maxLines = 3, overflow = TextOverflow.Ellipsis) }
        }
    }
}

// MARK: TV

/**
 * 10-foot detail page: the backdrop (and the muted trailer) fills the screen, the information sits
 * in a left column with large action buttons, and seasons, episodes, cast and "More like this"
 * follow as focusable rows.
 */
@Composable
private fun DetailTv(
    d: Details,
    episodes: List<Episode>,
    season: Int?,
    nextEp: Episode?,
    sources: SourcesModel?,
    listState: androidx.compose.foundation.lazy.LazyListState,
    trailer: TrailerController,
    playLabel: String,
    onPlay: () -> Unit,
    onPlayEpisode: (Episode) -> Unit,
    onSeason: (Int) -> Unit,
    onSources: () -> Unit,
    onTrailer: (() -> Unit)?,
) {
    val nav = LocalNav.current
    val item = d.item
    val playFocus = remember { FocusRequester() }
    val scope = rememberCoroutineScope()
    InitialFocus(playFocus)
    val scrolled by remember { derivedStateOf { listState.firstVisibleItemIndex > 0 || listState.firstVisibleItemScrollOffset > 60 } }
    val deep by animateFloatAsState(if (scrolled) 1f else 0f, tween(400), label = "detail-dim")

    Box(Modifier.fillMaxSize().background(Palette.background)) {
        Artwork(item.backdrop ?: item.poster, Modifier.fillMaxSize())
        TrailerSurface(trailer, Modifier.fillMaxSize())
        Box(Modifier.fillMaxSize().background(Brush.horizontalGradient(
            0f to Palette.background.copy(alpha = 0.96f), 0.4f to Palette.background.copy(alpha = 0.7f), 0.72f to Color.Transparent)))
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.45f to Color.Transparent, 1f to Palette.background)))
        Box(Modifier.fillMaxSize().graphicsLayer { alpha = deep }.background(Palette.background.copy(alpha = 0.82f)))

        // The page opens at the top and stays there: it only scrolls when focus moves to a row that
        // is off screen, and returning to the buttons brings the whole title back into view.
        MinimalScroll {
        LazyColumn(Modifier.fillMaxSize(), state = listState, contentPadding = PaddingValues(bottom = 48.dp)) {
            item(key = "info") {
                Column(
                    Modifier.onFocusChanged { f ->
                        if (f.hasFocus && (listState.firstVisibleItemIndex > 0 || listState.firstVisibleItemScrollOffset > 0)) {
                            scope.launch { listState.animateScrollToItem(0) }
                        }
                    }.fillParentMaxHeight(0.8f).fillMaxWidth(0.58f)
                        .padding(start = Dims.gutter(), top = Dims.overscanY + 12.dp, bottom = 8.dp),
                    verticalArrangement = Arrangement.Bottom,
                ) {
                    val logoScale by animateFloatAsState(if (trailer.revealed) 0.82f else 1f, tween(TrailerPolicy.FADE_MS), label = "tv-logo-scale")
                    val shrink = Modifier.graphicsLayer {
                        scaleX = logoScale
                        scaleY = logoScale
                        transformOrigin = TransformOrigin(0f, 1f)
                    }
                    if (item.logo != null) {
                        AsyncImage(model = item.logo, contentDescription = item.title, contentScale = ContentScale.Fit, alignment = Alignment.BottomStart,
                            modifier = shrink.widthIn(max = 420.dp).height(110.dp))
                    } else {
                        Text(item.title, fontSize = if (item.title.length > 28) 34.sp else 40.sp, lineHeight = 44.sp, fontWeight = FontWeight.Black,
                            maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = shrink)
                    }
                    Spacer(Modifier.height(12.dp))
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        d.imdbRating?.let { ImdbBadge(it) }
                        CriticScores(d.rottenTomatoes, d.metacritic)
                        d.certification?.takeIf { it.isNotBlank() }?.let { Pill(it, Color.Transparent) }
                        if (sources?.sorted?.any { it.resolution >= 2160 } == true) Pill("4K", Palette.gold.copy(alpha = 0.18f), Palette.gold)
                        Text(metaLine(item, hideRating = d.imdbRating != null).joinToString("  ·  "), fontSize = 17.sp, color = Palette.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    d.tagline?.takeIf { it.isNotBlank() }?.let {
                        Spacer(Modifier.height(8.dp))
                        Text(it, fontSize = 17.sp, color = Color.White.copy(alpha = 0.7f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    item.overview?.let {
                        Spacer(Modifier.height(10.dp))
                        Text(it, fontSize = 18.sp, lineHeight = 26.sp, color = Color.White.copy(alpha = 0.88f), maxLines = 3, overflow = TextOverflow.Ellipsis)
                    }
                    val people = listOfNotNull(
                        d.directors.take(2).joinToString(", ").ifEmpty { null }?.let { "Directed by $it" },
                        d.cast.take(3).joinToString(", ") { it.name }.ifEmpty { null }?.let { "Starring $it" },
                    )
                    if (people.isNotEmpty()) {
                        Spacer(Modifier.height(8.dp))
                        Text(people.joinToString("   "), fontSize = 15.sp, color = Palette.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    Spacer(Modifier.height(20.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                        SfButton(playLabel, onPlay, icon = Icons.Filled.PlayArrow, kind = ButtonKind.PRIMARY, focusRequester = playFocus)
                        if (item.type == MediaType.MOVIE || item.type == MediaType.SERIES) SfButton("Sources", onSources, icon = Icons.Filled.Tune)
                        SfButton("My List", { Library.toggleFavorite(item) }, icon = if (Library.isFavorite(item)) Icons.Filled.Check else Icons.Filled.Add)
                        when (trailer.phase) {
                            TrailerController.Phase.PLAYING -> SfButton(null, { trailer.toggleMute() },
                                icon = if (trailer.muted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp,
                                contentDescription = if (trailer.muted) "Unmute trailer" else "Mute trailer")
                            TrailerController.Phase.ENDED -> SfButton(null, { trailer.replay() }, icon = Icons.Filled.Replay, contentDescription = "Replay trailer")
                            TrailerController.Phase.IDLE, TrailerController.Phase.LOADING, TrailerController.Phase.UNAVAILABLE ->
                                if (onTrailer != null) SfButton("Trailer", onTrailer, icon = Icons.Filled.Movie)
                        }
                        Metadata.collections[item.id]?.takeIf { it.first > 0 }?.let { (cid, cname) ->
                            SfButton(null, { nav.push(Screen.Collection(cid, cname)) }, icon = Icons.Filled.CollectionsBookmark, contentDescription = cname)
                        }
                    }
                    if (item.type == MediaType.MOVIE) {
                        val s = sources
                        val status = when {
                            s == null || (s.loading && s.sources.isEmpty()) -> "Asking your server and addons for sources…"
                            s.sorted.isEmpty() && !s.loading -> "No sources found. Add stream addons in Settings."
                            else -> "${s.sorted.size} sources" + (s.sorted.firstOrNull()?.let { "  ·  best: ${it.resolutionLabel.ifEmpty { "SD" }} from ${it.provider}" } ?: "") +
                                (if (s.loading) "  ·  still searching" else "")
                        }
                        Spacer(Modifier.height(12.dp))
                        Text(status, fontSize = 15.sp, color = Palette.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            if (item.type == MediaType.SERIES && d.seasons.size > 1) {
                item(key = "seasons") {
                    LazyRow(
                        contentPadding = PaddingValues(horizontal = Dims.gutter(), vertical = 12.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        itemsIndexed(d.seasons.distinct(), key = { _, s -> s }) { _, s ->
                            Chip(if (s == 0) "Specials" else "Season $s", season == s) { onSeason(s) }
                        }
                    }
                }
            }
            if (item.type == MediaType.SERIES && episodes.isNotEmpty()) {
                item(key = "episodes-$season") {
                    val unique = episodes.distinctBy { it.id }
                    val rowState = rememberLazyListState(initialFirstVisibleItemIndex = unique.indexOfFirst { it.id == nextEp?.id }.coerceAtLeast(0))
                    Column(Modifier.padding(top = 4.dp)) {
                        SectionHeader(if (season == 0) "Specials" else "Season $season", "${unique.size} episodes")
                        Spacer(Modifier.height(4.dp))
                        androidx.compose.runtime.CompositionLocalProvider(LocalShelfKey provides "episodes") {
                            KeylineScroll(Dims.gutter()) {
                                LazyRow(
                                    state = rowState,
                                    contentPadding = PaddingValues(horizontal = Dims.gutter(), vertical = 12.dp),
                                    horizontalArrangement = Arrangement.spacedBy(20.dp),
                                ) {
                                    itemsIndexed(unique, key = { _, e -> e.id }) { _, ep -> EpisodeCard(item, ep, ep.id == nextEp?.id) { onPlayEpisode(ep) } }
                                }
                            }
                        }
                    }
                }
            }
            if (d.cast.isNotEmpty()) item(key = "cast") {
                Shelf("Cast", d.cast, key = { it.id }, rowKey = "cast") { person -> CastCard(person) }
            }
            item(key = "similar") { Shelf("More like this", d.similar, key = { it.id }, rowKey = "similar") { PosterCard(it, { nav.push(Screen.Detail(it)) }) } }
        }
        }
    }
}

/** Landscape still with progress; the title and runtime sit underneath. Long-press toggles watched. */
@Composable
private fun EpisodeCard(item: MediaItem, ep: Episode, isNext: Boolean, onPlay: () -> Unit) {
    val p = Library.progress(item, ep)
    val watched = Library.isWatched(item, ep)
    var focused by remember { mutableStateOf(false) }
    Column(Modifier.width(300.dp)) {
        Box(
            Modifier.fillMaxWidth().aspectRatio(16f / 9f).card(onPlay, { Library.setWatched(item, ep, !watched) }, RoundedCornerShape(14.dp),
                dimUnfocused = true, focusKey = "episodes/${ep.id}", onFocus = { focused = it }),
        ) {
            Artwork(ep.still ?: item.backdrop, Modifier.fillMaxSize(), label = ep.title)
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.55f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.75f))))
            Row(Modifier.align(Alignment.TopStart).padding(10.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Pill("E${ep.episode}", Color.Black.copy(alpha = 0.6f))
                if (isNext && !watched) Pill(if ((p?.fraction ?: 0f) > 0.02f) "RESUME" else "NEXT", Palette.accent.copy(alpha = 0.85f))
            }
            if (watched) Icon(Icons.Filled.CheckCircle, "Watched", tint = Color.White, modifier = Modifier.align(Alignment.TopEnd).padding(10.dp).size(24.dp))
            p?.let { ProgressLine(it.fraction, Modifier.align(Alignment.BottomCenter).padding(10.dp), 4.dp) }
        }
        Spacer(Modifier.height(10.dp))
        Text("${ep.episode}. ${ep.title}", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(listOfNotNull(ep.runtimeMinutes?.let { "${it}m" }, ep.airDate, if (ep.xcEpisodeId != null) "On server" else null).joinToString("  ·  "),
            fontSize = 14.sp, color = Palette.secondary, maxLines = 1)
        Text(ep.overview ?: "", fontSize = 14.sp, color = Palette.secondary, maxLines = 2, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.height(40.dp).alpha(if (focused) 1f else 0f))
    }
}

@Composable
private fun CastCard(person: com.mohamedt.streamforge.core.Person) {
    val nav = LocalNav.current
    val tv = isTv()
    val size = if (tv) 112.dp else 76.dp
    val shelf = LocalShelfKey.current
    Column(
        Modifier.width(if (tv) 132.dp else 96.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.card({ nav.push(Screen.Person(person.id.takeIf { it > 0 }, person.name, person.photo)) }, shape = CircleShape,
            focusKey = if (tv) shelf?.let { "$it/${person.id}-${person.name}" } else null)) {
            CastAvatar(person.photo, person.name, size)
        }
        Spacer(Modifier.height(if (tv) 10.dp else 4.dp))
        Text(person.name, fontSize = if (tv) 16.sp else 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, textAlign = TextAlign.Center,
            overflow = TextOverflow.Ellipsis)
        person.role?.let { Text(it, fontSize = if (tv) 14.sp else 11.sp, color = Palette.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis) }
    }
}

// MARK: Sources

@Composable
fun SourceRow(src: PlaybackSource, estimate: StartEstimator.Estimate? = null, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val tv = isTv()
    Row(modifier.fillMaxWidth().padding(horizontal = if (tv) 0.dp else Dims.gutter(), vertical = 4.dp)
        .card(onClick, shape = RoundedCornerShape(14.dp), focusScale = if (tv) 1.02f else null, glow = false)
        .background(if (tv) Palette.surfaceHigh else Palette.surface).padding(if (tv) 16.dp else 12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        val color = when { src.resolution >= 2160 -> Palette.gold; src.resolution >= 1080 -> Palette.accent; src.resolution >= 720 -> Color(0xFF2DD4BF); else -> Color.Gray }
        Text(src.resolutionLabel.ifEmpty { "—" }, fontWeight = FontWeight.Black, color = color, fontSize = if (tv) 18.sp else 14.sp,
            modifier = Modifier.width(if (tv) 76.dp else 60.dp).clip(RoundedCornerShape(8.dp)).background(color.copy(alpha = 0.18f)).padding(vertical = 8.dp), maxLines = 1,
            textAlign = TextAlign.Center)
        Spacer(Modifier.width(if (tv) 16.dp else 12.dp))
        Column(Modifier.weight(1f)) {
            Text(src.provider, fontSize = if (tv) 14.sp else 12.sp, fontWeight = FontWeight.Bold, color = Palette.accent, maxLines = 1)
            Text(src.title, fontWeight = FontWeight.SemiBold, fontSize = if (tv) 17.sp else 14.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
            src.detail?.let { Text(it, fontSize = if (tv) 14.sp else 12.sp, color = Palette.secondary, maxLines = 2, overflow = TextOverflow.Ellipsis) }
            Row(horizontalArrangement = Arrangement.spacedBy(5.dp), modifier = Modifier.padding(top = 4.dp)) {
                if (src.cached) Pill("⚡ INSTANT", Color(0x5522C55E))
                if (src.isTorrent) Pill("TORRENT")
                src.tags.take(4).forEach { Pill(it) }
                src.size?.let { Pill(it.byteText(), Color.Transparent) }
                src.seeders?.let { Pill("👤 $it", Color.Transparent) }
            }
            estimate?.takeIf { !(src.cached && it.rating == StartEstimator.Estimate.Rating.INSTANT) }?.let { e ->
                val c = when {
                    e.mayBuffer -> Color(0xFFF87171)
                    e.rating == StartEstimator.Estimate.Rating.SLOW -> Color(0xFFFB923C)
                    e.rating == StartEstimator.Estimate.Rating.OKAY -> Color(0xFFFACC15)
                    else -> Color(0xFF4ADE80)
                }
                val head = if (e.mayBuffer) "⚠ Starts in ${e.label} · may buffer" else "⏱ Starts in ${e.label}"
                Text("$head · est. ${e.expectedSpeed.toLong().byteText()}/s, file ${e.bitrate.toLong().byteText()}/s",
                    color = c, fontSize = if (tv) 13.sp else 11.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 4.dp))
            }
        }
    }
}

/** Every source for a title or episode: a side panel with large rows on TV, a dialog on phones. */
@Composable
fun SourcesDialog(item: MediaItem, ep: Episode?, onDismiss: () -> Unit, onPick: (PlaybackSource) -> Unit) {
    val tv = isTv()
    val model = remember(item.id, ep?.id) { SourcesModel(item, ep) }
    LaunchedEffect(model) { model.load() }
    var quality by remember(item.id, ep?.id) { mutableStateOf<String?>(null) }
    var fastest by remember { mutableStateOf(false) }
    @Suppress("UNUSED_VARIABLE") val learned = StartEstimator.version
    val qualities = model.sorted.filter { it.resolution > 0 }.sortedByDescending { it.resolution }.map { it.resolutionLabel }.distinct()
    val filtered = model.sorted.filter { quality == null || it.resolutionLabel == quality }
    val list = if (fastest) model.fastest(filtered) else filtered
    val first = remember { FocusRequester() }
    val title = ep?.let { "${item.title} · ${it.code}" } ?: item.title
    val subtitle = when {
        model.loading -> "${model.sorted.size} found · waiting for ${model.pendingAddons} addon(s)"
        else -> "${model.sorted.size} sources"
    }
    SfDialog(title, onDismiss, subtitle = if (tv) subtitle else null) {
        // Sort + quality chips stay pinned above the scrolling list.
        LazyRow(Modifier.padding(bottom = if (tv) 12.dp else 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp),
            contentPadding = PaddingValues(vertical = if (tv) 6.dp else 0.dp)) {
            item(key = "fastest") { Chip("⏱ Fastest start", fastest, focusRequester = if (tv) first else null) { fastest = !fastest } }
            if (qualities.size > 1) {
                item(key = "all") { Chip("All", quality == null) { quality = null } }
                qualities.forEach { q -> item(key = "q-$q") { Chip(q, quality == q) { quality = if (quality == q) null else q } } }
            }
        }
        LazyColumn(if (tv) Modifier.fillMaxSize() else Modifier.heightIn(max = 520.dp), verticalArrangement = Arrangement.spacedBy(if (tv) 6.dp else 0.dp),
            contentPadding = PaddingValues(vertical = if (tv) 6.dp else 0.dp)) {
            if (list.isEmpty()) item {
                Text(if (model.loading) "Waiting for ${model.pendingAddons} addon(s)…" else "No sources found. Install stream addons in Settings.",
                    color = Palette.secondary, fontSize = if (tv) 18.sp else 14.sp)
            }
            list.forEach { src -> item(key = src.id) { SourceRow(src, model.estimate(src)) { onPick(src) } } }
        }
        // Inside the panel's own window, so the request reaches it.
        if (tv) InitialFocus(first, always = true)
    }
}

// MARK: Person, collection

@Composable
fun PersonScreen(id: Int?, name: String, photo: String? = null) {
    val nav = LocalNav.current
    var info by remember { mutableStateOf<Tmdb.PersonInfo?>(null) }
    var failed by remember { mutableStateOf(false) }
    LaunchedEffect(id, name) {
        val pid = id ?: if (Tmdb.configured) runCatching { Tmdb.searchPerson(name) }.getOrNull() else null
        info = pid?.let { runCatching { Tmdb.person(it) }.getOrNull() }
        failed = info == null
    }
    val i = info
    if (i == null && !failed) { Loading(); return }
    // What's playable from your own server first.
    val credits = i?.credits ?: emptyList()
    // O(1) lookups per credit; remembered so recompositions don't redo them (re-run when the library changes).
    val movieLib = DispatcharrRepo.movieItems
    val seriesLib = DispatcharrRepo.seriesItems
    val onServer = remember(credits, movieLib, seriesLib) {
        credits.mapNotNull { c ->
            val sid = DispatcharrRepo.active?.id ?: return@mapNotNull null
            if (c.type == MediaType.MOVIE) DispatcharrRepo.matchMovie(c.tmdbId, null, c.title, c.year)?.toItem(sid)
            else DispatcharrRepo.matchSeries(c.tmdbId, null, c.title)?.toItem(sid)
        }.distinctBy { it.id }
    }
    val tv = isTv()
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = if (tv) Dims.overscanY else 0.dp, bottom = if (tv) 48.dp else 0.dp)) {
        item {
            Row(Modifier.padding(Dims.gutter())) {
                // TMDB's profile, else the face from the cast card, else initials.
                val shown = i?.photo ?: photo
                val shownName = i?.name?.ifEmpty { null } ?: name
                Box(Modifier.width(if (tv) 150.dp else 120.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(12.dp))) {
                    if (shown != null) {
                        Artwork(shown, Modifier.fillMaxSize(), label = shownName)
                    } else {
                        Box(Modifier.fillMaxSize().background(Palette.gradient, alpha = 0.35f), contentAlignment = Alignment.Center) {
                            Text(initials(shownName), fontSize = 34.sp, fontWeight = FontWeight.Bold, color = Color.White.copy(alpha = 0.8f))
                        }
                    }
                }
                Spacer(Modifier.width(if (tv) 28.dp else 16.dp))
                Column(Modifier.widthIn(max = 760.dp)) {
                    Text(shownName, fontSize = if (tv) 34.sp else 26.sp, fontWeight = FontWeight.Bold)
                    if (i != null) {
                        i.bio?.let {
                            Text(it, color = Palette.secondary, maxLines = if (tv) 6 else 8, overflow = TextOverflow.Ellipsis,
                                fontSize = if (tv) 17.sp else 13.sp, lineHeight = if (tv) 25.sp else 18.sp)
                        }
                    } else {
                        Text(if (Tmdb.configured) "No details found." else "Add a TMDB key in Settings to see filmographies.",
                            color = Palette.secondary, fontSize = if (tv) 17.sp else 13.sp)
                    }
                }
            }
        }
        item { Shelf("On Your Server", onServer, key = { it.id }, rowKey = "server") { PosterCard(it, { nav.push(Screen.Detail(it)) }) } }
        item { Shelf("Movies", credits.filter { it.type == MediaType.MOVIE }, subtitle = "Streams come from your addons", key = { it.id }, rowKey = "movies") { PosterCard(it, { nav.push(Screen.Detail(it)) }) } }
        item { Shelf("Series", credits.filter { it.type == MediaType.SERIES }, key = { it.id }, rowKey = "series") { PosterCard(it, { nav.push(Screen.Detail(it)) }) } }
    }
}

/** Round cast photo (face kept at the top); initials when there's no photo or it fails to load. */
@Composable
fun CastAvatar(url: String?, name: String, size: Dp) {
    var failed by remember(url) { mutableStateOf(false) }
    Box(
        Modifier.size(size).clip(CircleShape).background(Brush.verticalGradient(listOf(Palette.surfaceHigh, Palette.surface))),
        contentAlignment = Alignment.Center,
    ) {
        if (url == null || failed) {
            Box(Modifier.fillMaxSize().background(Palette.gradient, alpha = 0.35f), contentAlignment = Alignment.Center) {
                Text(initials(name), fontSize = (size.value * 0.34f).sp, fontWeight = FontWeight.Bold, color = Color.White.copy(alpha = 0.8f), maxLines = 1)
            }
        } else {
            AsyncImage(
                model = url,
                contentDescription = null,
                modifier = Modifier.fillMaxSize(),
                onError = { failed = true },
                alignment = Alignment.TopCenter,
                contentScale = ContentScale.Crop,
            )
        }
    }
}

private fun initials(name: String): String {
    val words = name.split(' ', '-', '.').filter { it.firstOrNull()?.isLetter() == true }
    val letters = if (words.size > 1) listOf(words.first().first(), words.last().first()) else words.firstOrNull()?.take(2)?.toList() ?: emptyList()
    return letters.joinToString("").uppercase().ifEmpty { "?" }
}

@Composable
fun CollectionScreen(id: Int, name: String) {
    val nav = LocalNav.current
    var col by remember { mutableStateOf<Tmdb.Collection?>(null) }
    LaunchedEffect(id) { col = runCatching { Tmdb.collection(id) }.getOrNull() }
    val c = col
    if (c == null) { Loading(); return }
    val sid = DispatcharrRepo.active?.id
    val parts = c.parts.map { p ->
        val local = sid?.let { s -> DispatcharrRepo.matchMovie(p.tmdbId, null, p.title, p.year)?.toItem(s) }
        (local ?: p) to (local != null)
    }
    PosterGrid(parts.map { it.first }) {
        Column {
            Text(c.name, fontSize = if (isTv()) 32.sp else 26.sp, fontWeight = FontWeight.Bold)
            Text("${parts.count { it.second }} of ${parts.size} on your server", color = Palette.accent)
            c.overview?.let { Text(it, color = Palette.secondary, maxLines = 4, overflow = TextOverflow.Ellipsis) }
            Spacer(Modifier.height(8.dp))
        }
    }
}
