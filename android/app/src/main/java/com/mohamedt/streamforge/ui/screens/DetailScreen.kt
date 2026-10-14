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
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
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
import com.mohamedt.streamforge.ui.Artwork
import com.mohamedt.streamforge.ui.Chip
import com.mohamedt.streamforge.ui.Dims
import com.mohamedt.streamforge.ui.Loading
import com.mohamedt.streamforge.ui.LocalNav
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.Pill
import com.mohamedt.streamforge.ui.PosterCard
import com.mohamedt.streamforge.ui.ProgressLine
import com.mohamedt.streamforge.ui.Screen
import com.mohamedt.streamforge.ui.Shelf
import com.mohamedt.streamforge.ui.TrailerButton
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

@Composable
fun DetailScreen(initial: MediaItem) {
    val nav = LocalNav.current
    val context = LocalContext.current
    var details by remember { mutableStateOf<Details?>(null) }
    var season by remember { mutableStateOf<Int?>(null) }
    var episodes by remember { mutableStateOf<List<Episode>>(emptyList()) }
    var sources by remember { mutableStateOf<SourcesModel?>(null) }
    var picker by remember { mutableStateOf<Pair<Episode?, List<Episode>>?>(null) }

    // Hero trailer (Netflix-style): backdrop first, muted video ~2.5 s after the page opened,
    // paused while the hero is scrolled away, the app isn't in front (a player activity is on
    // top, or it's in the background) or the sources dialog covers it.
    val listState = rememberLazyListState()
    val trailer = rememberTrailerController()
    val shownAt = remember { System.currentTimeMillis() }
    val heroHeight = if (isTv()) 420.dp else 300.dp
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
            val resume = Library.latestEpisode(d.item)?.episode?.season
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
        episodes = Metadata.episodes(d, s)
    }

    val d = details
    if (d == null) { Loading(); return }
    val item = d.item

    fun play(ep: Episode) {
        val upcoming = episodes.dropWhile { it.id != ep.id }.drop(1)
        val client = DispatcharrRepo.client
        if (ep.xcEpisodeId != null && client != null) {
            Player.play(context, PlaybackRequest(item, ep, PlaybackSource("xc-ep-${ep.xcEpisodeId}", SourceKind.Direct(client.episodeUrl(ep.xcEpisodeId, ep.ext ?: "mp4")),
                "${item.title} ${ep.code}", provider = DispatcharrRepo.active?.name ?: "Server", cached = true), upcoming = upcoming))
        } else {
            picker = ep to upcoming
        }
    }

    val nextEp: Episode? = run {
        val p = Library.latestEpisode(item)
        p?.episode?.let { e -> episodes.firstOrNull { it.season == e.season && it.episode == e.episode && !p.finished } }
            ?: episodes.firstOrNull { !Library.isWatched(item, it) } ?: episodes.firstOrNull()
    }

    LazyColumn(Modifier.fillMaxSize(), state = listState) {
        item {
            Box(Modifier.fillMaxWidth().height(heroHeight)) {
                Artwork(item.backdrop ?: item.poster, Modifier.fillMaxSize())
                // Edge-to-edge muted trailer over the artwork (cropped, no controls).
                TrailerSurface(trailer, Modifier.fillMaxSize())
                Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.3f), Color.Transparent, Palette.background))))
                Row(Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(Dims.gutter()), verticalAlignment = Alignment.Bottom) {
                    Column(Modifier.weight(1f)) {
                        // Like Netflix, the title shrinks a little while the trailer plays.
                        val logoScale by animateFloatAsState(if (trailer.revealed) 0.8f else 1f, tween(TrailerPolicy.FADE_MS), label = "logo-scale")
                        val shrink = Modifier.graphicsLayer {
                            scaleX = logoScale
                            scaleY = logoScale
                            transformOrigin = TransformOrigin(0f, 1f)
                        }
                        if (item.logo != null) {
                            Artwork(item.logo, shrink.widthIn(max = 320.dp).height(90.dp), ContentScale.Fit)
                        } else {
                            Text(item.title, fontSize = 32.sp, fontWeight = FontWeight.Black, maxLines = 2, modifier = shrink)
                        }
                        val meta = listOfNotNull(item.year?.toString(), item.runtimeMinutes?.let { "${it / 60}h ${it % 60}m".removePrefix("0h ") },
                            item.rating?.let { "★ %.1f".format(it) }, item.genres.take(3).joinToString(" · ").ifEmpty { null })
                        Text(meta.joinToString("  ·  "), color = Palette.secondary, fontSize = 13.sp)
                    }
                    TrailerButton(trailer, Modifier.padding(start = 12.dp))
                }
            }
        }
        item {
            Row(Modifier.padding(horizontal = Dims.gutter(), vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                val label = when {
                    item.type == MediaType.SERIES -> nextEp?.let { e -> if ((Library.progress(item, e)?.fraction ?: 0f) > 0.02f) "Resume ${e.code}" else "Play ${e.code}" } ?: "Play"
                    (Library.progress(item)?.fraction ?: 0f) > 0.02f -> "Resume · ${Library.progress(item)?.remainingText}"
                    sources?.loading == true && sources?.sources?.isEmpty() == true -> "Finding sources…"
                    else -> "Play"
                }
                Row(Modifier.card({
                    if (item.type == MediaType.SERIES) nextEp?.let { play(it) }
                    else {
                        val best = sources?.sorted?.firstOrNull()
                        if (best != null && (best.cached || sources?.sorted?.size == 1)) Player.play(context, PlaybackRequest(item, source = best))
                        else picker = null to emptyList()
                    }
                }, shape = RoundedCornerShape(24.dp)).background(Palette.gradient).padding(horizontal = 22.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.PlayArrow, null); Spacer(Modifier.width(6.dp)); Text(label, fontWeight = FontWeight.Bold)
                }
                Box(Modifier.size(46.dp).card({ Library.toggleFavorite(item) }, shape = CircleShape).background(Palette.surfaceHigh), contentAlignment = Alignment.Center) {
                    Icon(if (Library.isFavorite(item)) Icons.Filled.Check else Icons.Filled.Add, "My List")
                }
                d.trailerKey?.let { key ->
                    Box(Modifier.size(46.dp).card({
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://www.youtube.com/watch?v=$key")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }, shape = CircleShape).background(Palette.surfaceHigh), contentAlignment = Alignment.Center) { Icon(Icons.Filled.Movie, "Trailer") }
                }
            }
        }
        item {
            item.overview?.let { Text(it, Modifier.padding(horizontal = Dims.gutter()).widthIn(max = 820.dp), color = Color.White.copy(alpha = 0.85f), maxLines = 6, overflow = TextOverflow.Ellipsis) }
        }
        Metadata.collections[item.id]?.takeIf { it.first > 0 }?.let { (cid, cname) ->
            item {
                Text("Part of the $cname →", color = Palette.accent, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(horizontal = Dims.gutter(), vertical = 10.dp).card({ nav.push(Screen.Collection(cid, cname)) }).padding(6.dp))
            }
        }
        if (item.type == MediaType.SERIES) {
            item {
                Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = Dims.gutter(), vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    d.seasons.forEach { s -> Chip(if (s == 0) "Specials" else "Season $s", season == s) { season = s } }
                }
            }
            episodes.distinctBy { it.id }.forEach { ep -> item(key = "ep-${ep.id}") { EpisodeRow(item, ep) { play(ep) } } }
        }
        if (item.type == MediaType.MOVIE) {
            item {
                val s = sources
                Column(Modifier.padding(horizontal = Dims.gutter(), vertical = 10.dp)) {
                    Text("Sources", fontSize = 20.sp, fontWeight = FontWeight.Bold)
                    if (s == null || (s.loading && s.sources.isEmpty())) Text("Asking your server and addons…", color = Palette.secondary)
                    else if (s.sorted.isEmpty()) Text("No sources found. Add stream addons in Settings.", color = Palette.secondary)
                }
            }
            sources?.sorted?.take(8)?.forEach { src ->
                item(key = "src-${src.id}") { SourceRow(src, sources?.estimate(src)) { Player.play(context, PlaybackRequest(item, source = src)) } }
            }
            if ((sources?.sorted?.size ?: 0) > 8) item {
                Text("All ${sources?.sorted?.size} sources →", color = Palette.accent, modifier = Modifier.padding(Dims.gutter()).card({ picker = null to emptyList() }).padding(6.dp))
            }
        }
        if (d.cast.isNotEmpty()) item {
            Shelf("Cast", d.cast, key = { it.id }) { person ->
                Column(Modifier.width(96.dp).card({ nav.push(Screen.Person(person.id.takeIf { it > 0 }, person.name, person.photo)) }), horizontalAlignment = Alignment.CenterHorizontally) {
                    CastAvatar(person.photo, person.name, 76.dp)
                    Text(person.name, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 2)
                    person.role?.let { Text(it, fontSize = 11.sp, color = Palette.secondary, maxLines = 1) }
                }
            }
        }
        item { Shelf("More Like This", d.similar, key = { it.id }) { PosterCard(it, { nav.push(Screen.Detail(it)) }) } }
        item { Spacer(Modifier.height(40.dp)) }
    }

    picker?.let { (ep, upcoming) ->
        SourcesDialog(item, ep, onDismiss = { picker = null }) { src ->
            picker = null
            Player.play(context, PlaybackRequest(item, ep, src, upcoming = upcoming))
        }
    }
}

@Composable
private fun EpisodeRow(item: MediaItem, ep: Episode, onPlay: () -> Unit) {
    val p = Library.progress(item, ep)
    Row(Modifier.fillMaxWidth().padding(horizontal = Dims.gutter(), vertical = 5.dp).card(onPlay, { Library.setWatched(item, ep, !Library.isWatched(item, ep)) }, RoundedCornerShape(14.dp))
        .background(Palette.surface).padding(8.dp)) {
        Box(Modifier.width(if (isTv()) 240.dp else 140.dp).aspectRatio(16f / 9f).clip(RoundedCornerShape(10.dp))) {
            Artwork(ep.still ?: item.backdrop, Modifier.fillMaxSize())
            p?.let { ProgressLine(it.fraction, Modifier.align(Alignment.BottomCenter).padding(6.dp)) }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("${ep.episode}. ${ep.title}", fontWeight = FontWeight.SemiBold, maxLines = 2, modifier = Modifier.weight(1f))
                if (Library.isWatched(item, ep)) Icon(Icons.Filled.Check, null, tint = Palette.accent)
            }
            Text(listOfNotNull(ep.airDate, ep.runtimeMinutes?.let { "${it}m" }, if (ep.xcEpisodeId != null) "On server" else null).joinToString(" · "),
                fontSize = 11.sp, color = Palette.secondary)
            ep.overview?.let { Text(it, fontSize = 12.sp, color = Palette.secondary, maxLines = 3, overflow = TextOverflow.Ellipsis) }
        }
    }
}

@Composable
fun SourceRow(src: PlaybackSource, estimate: com.mohamedt.streamforge.torrent.StartEstimator.Estimate? = null, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = Dims.gutter(), vertical = 4.dp).card(onClick, shape = RoundedCornerShape(14.dp)).background(Palette.surface).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        val color = when { src.resolution >= 2160 -> Palette.gold; src.resolution >= 1080 -> Palette.accent; src.resolution >= 720 -> Color(0xFF2DD4BF); else -> Color.Gray }
        Text(src.resolutionLabel.ifEmpty { "—" }, fontWeight = FontWeight.Black, color = color,
            modifier = Modifier.width(60.dp).clip(RoundedCornerShape(8.dp)).background(color.copy(alpha = 0.18f)).padding(vertical = 8.dp), maxLines = 1,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(src.provider, fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Palette.accent, maxLines = 1)
            Text(src.title, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            src.detail?.let { Text(it, fontSize = 12.sp, color = Palette.secondary, maxLines = 2, overflow = TextOverflow.Ellipsis) }
            Row(horizontalArrangement = Arrangement.spacedBy(5.dp), modifier = Modifier.padding(top = 4.dp)) {
                if (src.cached) Pill("⚡ INSTANT", Color(0x5522C55E))
                if (src.isTorrent) Pill("TORRENT")
                src.tags.take(4).forEach { Pill(it) }
                src.size?.let { Pill(it.byteText(), Color.Transparent) }
                src.seeders?.let { Pill("👤 $it", Color.Transparent) }
            }
            estimate?.takeIf { !(src.cached && it.rating == com.mohamedt.streamforge.torrent.StartEstimator.Estimate.Rating.INSTANT) }?.let { e ->
                val c = when {
                    e.mayBuffer -> Color(0xFFF87171)
                    e.rating == com.mohamedt.streamforge.torrent.StartEstimator.Estimate.Rating.SLOW -> Color(0xFFFB923C)
                    e.rating == com.mohamedt.streamforge.torrent.StartEstimator.Estimate.Rating.OKAY -> Color(0xFFFACC15)
                    else -> Color(0xFF4ADE80)
                }
                val head = if (e.mayBuffer) "⚠ Starts in ${e.label} · may buffer" else "⏱ Starts in ${e.label}"
                Text("$head · est. ${e.expectedSpeed.toLong().byteText()}/s, file ${e.bitrate.toLong().byteText()}/s",
                    color = c, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 4.dp))
            }
        }
    }
}

@Composable
fun SourcesDialog(item: MediaItem, ep: Episode?, onDismiss: () -> Unit, onPick: (PlaybackSource) -> Unit) {
    val model = remember(item.id, ep?.id) { SourcesModel(item, ep) }
    LaunchedEffect(model) { model.load() }
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
        title = { Text(ep?.let { "${item.title} · ${it.code}" } ?: item.title) },
        text = {
            var quality by remember(item.id, ep?.id) { mutableStateOf<String?>(null) }
            var fastest by remember { mutableStateOf(false) }
            @Suppress("UNUSED_VARIABLE") val learned = com.mohamedt.streamforge.torrent.StartEstimator.version
            val qualities = model.sorted.filter { it.resolution > 0 }.sortedByDescending { it.resolution }.map { it.resolutionLabel }.distinct()
            val filtered = model.sorted.filter { quality == null || it.resolutionLabel == quality }
            val list = if (fastest) model.fastest(filtered) else filtered
            Column {
                // Sort + quality chips stay pinned above the scrolling list.
                Row(Modifier.horizontalScroll(rememberScrollState()).padding(bottom = 8.dp)) {
                    Chip("⏱ Fastest start", fastest) { fastest = !fastest }
                    Spacer(Modifier.width(8.dp))
                    if (qualities.size > 1) {
                        Chip("All", quality == null) { quality = null }
                        qualities.forEach { q ->
                            Spacer(Modifier.width(8.dp))
                            Chip(q, quality == q) { quality = if (quality == q) null else q }
                        }
                    }
                }
                LazyColumn(Modifier.heightIn(max = 520.dp)) {
                    if (list.isEmpty()) item {
                        Text(if (model.loading) "Waiting for ${model.pendingAddons} addon(s)…" else "No sources found. Install stream addons in Settings.", color = Palette.secondary)
                    }
                    list.forEach { src -> item(key = src.id) { SourceRow(src, model.estimate(src)) { onPick(src) } } }
                }
            }
        },
    )
}

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
    val onServer = credits.mapNotNull { c ->
        val sid = DispatcharrRepo.active?.id ?: return@mapNotNull null
        if (c.type == MediaType.MOVIE) DispatcharrRepo.matchMovie(c.tmdbId, null, c.title, c.year)?.toItem(sid)
        else DispatcharrRepo.matchSeries(c.tmdbId, null, c.title)?.toItem(sid)
    }
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Row(Modifier.padding(Dims.gutter())) {
                // TMDB's profile, else the face from the cast card, else initials.
                val shown = i?.photo ?: photo
                val shownName = i?.name?.ifEmpty { null } ?: name
                Box(Modifier.width(120.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(12.dp))) {
                    if (shown != null) {
                        Artwork(shown, Modifier.fillMaxSize(), label = shownName)
                    } else {
                        Box(Modifier.fillMaxSize().background(Palette.gradient, alpha = 0.35f), contentAlignment = Alignment.Center) {
                            Text(initials(shownName), fontSize = 34.sp, fontWeight = FontWeight.Bold, color = Color.White.copy(alpha = 0.8f))
                        }
                    }
                }
                Spacer(Modifier.width(16.dp))
                Column {
                    Text(shownName, fontSize = 26.sp, fontWeight = FontWeight.Bold)
                    if (i != null) {
                        i.bio?.let { Text(it, color = Palette.secondary, maxLines = 8, overflow = TextOverflow.Ellipsis, fontSize = 13.sp) }
                    } else {
                        Text(if (Tmdb.configured) "No details found." else "Add a TMDB key in Settings to see filmographies.",
                            color = Palette.secondary, fontSize = 13.sp)
                    }
                }
            }
        }
        item { Shelf("On Your Server", onServer, key = { it.id }) { PosterCard(it, { nav.push(Screen.Detail(it)) }) } }
        item { Shelf("Movies", credits.filter { it.type == MediaType.MOVIE }, subtitle = "Streams come from your addons", key = { it.id }) { PosterCard(it, { nav.push(Screen.Detail(it)) }) } }
        item { Shelf("Series", credits.filter { it.type == MediaType.SERIES }, key = { it.id }) { PosterCard(it, { nav.push(Screen.Detail(it)) }) } }
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
            Text(c.name, fontSize = 26.sp, fontWeight = FontWeight.Bold)
            Text("${parts.count { it.second }} of ${parts.size} on your server", color = Palette.accent)
            c.overview?.let { Text(it, color = Palette.secondary, maxLines = 4, overflow = TextOverflow.Ellipsis) }
            Spacer(Modifier.height(8.dp))
        }
    }
}
