package com.mohamedt.streamforge.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.MediaType
import com.mohamedt.streamforge.dispatcharr.Channel
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.dispatcharr.GuideRepo
import com.mohamedt.streamforge.dispatcharr.Programme
import com.mohamedt.streamforge.library.Library
import com.mohamedt.streamforge.library.Progress
import com.mohamedt.streamforge.metadata.Tmdb
import com.mohamedt.streamforge.player.PlaybackRequest
import com.mohamedt.streamforge.player.PlaybackSource
import com.mohamedt.streamforge.player.Player
import com.mohamedt.streamforge.player.SourceKind
import com.mohamedt.streamforge.stremio.Addons
import com.mohamedt.streamforge.ui.ChannelLogo
import com.mohamedt.streamforge.ui.Dims
import com.mohamedt.streamforge.ui.LandscapeCard
import com.mohamedt.streamforge.ui.LocalNav
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.PosterCard
import com.mohamedt.streamforge.ui.ProgressLine
import com.mohamedt.streamforge.ui.Screen
import com.mohamedt.streamforge.ui.Shelf
import com.mohamedt.streamforge.ui.card
import com.mohamedt.streamforge.ui.isTv
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope

@Composable
fun HomeScreen(onSearch: () -> Unit, onSettings: () -> Unit) {
    val nav = LocalNav.current
    val context = LocalContext.current
    var trendingMovies by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    var trendingSeries by remember { mutableStateOf<List<MediaItem>>(emptyList()) }
    var catalogs by remember { mutableStateOf<List<Pair<Addons.CatalogEntry, List<MediaItem>>>>(emptyList()) }

    // Re-run when addons change: on first launch Cinemeta is installed in the background after Home is shown.
    LaunchedEffect(Addons.addons) {
        coroutineScope {
            val m = async { if (Tmdb.configured) runCatching { Tmdb.trending(MediaType.MOVIE) }.getOrDefault(emptyList()) else emptyList() }
            val s = async { if (Tmdb.configured) runCatching { Tmdb.trending(MediaType.SERIES) }.getOrDefault(emptyList()) else emptyList() }
            val c = Addons.catalogs.take(8).map { e -> async { e to runCatching { Addons.catalog(e).take(30).map { it.toItem(e.addon.id) } }.getOrDefault(emptyList()) } }
            trendingMovies = m.await()
            trendingSeries = s.await()
            catalogs = c.map { it.await() }.filter { it.second.isNotEmpty() }
        }
    }

    val open: (MediaItem) -> Unit = { nav.push(Screen.Detail(it)) }

    LazyColumn(Modifier.fillMaxWidth()) {
        item {
            Row(Modifier.fillMaxWidth().padding(horizontal = Dims.gutter(), vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("StreamForge", fontSize = 26.sp, fontWeight = FontWeight.Black, modifier = Modifier.weight(1f))
                if (!isTv()) {
                    IconButton(onClick = onSearch) { Icon(Icons.Filled.Search, "Search") }
                    IconButton(onClick = onSettings) { Icon(Icons.Filled.Settings, "Settings") }
                }
            }
        }
        if (!DispatcharrRepo.isConfigured) {
            item {
                Column(Modifier.padding(Dims.gutter()).fillMaxWidth().background(Palette.surfaceHigh, RoundedCornerShape(18.dp)).padding(20.dp)) {
                    Text("Welcome to StreamForge", fontSize = 22.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(6.dp))
                    Text("Sign in to your Dispatcharr server in Settings for live TV, the guide and your movie and series library. Add Stremio addons for more catalogs and streams, and a TMDB key for artwork.",
                        color = Palette.secondary)
                    Spacer(Modifier.height(12.dp))
                    Text("Open Settings", color = Palette.accent, fontWeight = FontWeight.Bold, modifier = Modifier.card(onSettings).padding(8.dp))
                }
            }
        }
        item {
            Shelf("Continue Watching", Library.continueWatching, key = { it.key }) { p -> ContinueCard(p) }
        }
        item {
            val sports = GuideRepo.liveSports()
            Shelf("Live Sports Now", sports, subtitle = "Matches and events on air", key = { it.first.id }) { (ch, prog) ->
                ChannelTile(ch, prog) { Player.playChannel(context, ch, sports.map { it.first }) }
            }
        }
        item {
            val ids = Library.favoriteChannels.ifEmpty { Library.recentChannels.take(12) }
            val channels = ids.mapNotNull { DispatcharrRepo.channel(it) }
            Shelf(if (Library.favoriteChannels.isEmpty()) "Recent Channels" else "Favorite Channels", channels, key = { it.id }) { ch ->
                ChannelTile(ch, GuideRepo.now(ch)) { Player.playChannel(context, ch, channels) }
            }
        }
        item {
            Shelf("Recently Added Movies", DispatcharrRepo.movieItems.sortedByDescending { it.added ?: 0 }.take(24), subtitle = DispatcharrRepo.active?.name, key = { it.id }) {
                PosterCard(it, { open(it) }, { Library.toggleFavorite(it) })
            }
        }
        item {
            Shelf("Recently Updated Series", DispatcharrRepo.seriesItems.sortedByDescending { it.added ?: 0 }.take(24), subtitle = DispatcharrRepo.active?.name, key = { it.id }) {
                PosterCard(it, { open(it) }, { Library.toggleFavorite(it) })
            }
        }
        item { Shelf("My List", Library.favorites, key = { it.id }) { PosterCard(it, { open(it) }) } }
        item { Shelf("Trending Movies", trendingMovies, subtitle = "This week on TMDB", key = { it.id }) { PosterCard(it, { open(it) }) } }
        item { Shelf("Trending Series", trendingSeries, subtitle = "This week on TMDB", key = { it.id }) { PosterCard(it, { open(it) }) } }
        catalogs.forEachIndexed { i, (entry, items) ->
            item(key = "cat-$i-${entry.addon.id}-${entry.catalog.type}-${entry.catalog.id}") {
                Shelf(entry.title, items, subtitle = entry.addon.name, seeAll = { nav.push(Screen.Catalog(entry)) }, key = { it.id }) { PosterCard(it, { open(it) }) }
            }
        }
        item { Spacer(Modifier.height(30.dp)) }
    }
}

@Composable
fun ContinueCard(p: Progress) {
    val nav = LocalNav.current
    val context = LocalContext.current
    LandscapeCard(p.item.title, p.episode?.let { "${it.code} · ${p.remainingText}" } ?: p.remainingText,
        p.episode?.still ?: p.item.backdrop ?: p.item.poster, p.fraction) {
        val client = DispatcharrRepo.client
        val ep = p.episode
        val url = when {
            ep?.xcEpisodeId != null && client != null -> client.episodeUrl(ep.xcEpisodeId, ep.ext ?: "mp4")
            ep == null && p.item.origin.kind == "xc-movie" && client != null -> client.movieUrl(p.item.origin.id, p.item.origin.ext ?: "mp4")
            else -> null
        }
        if (url != null) {
            Player.play(context, PlaybackRequest(p.item, ep, PlaybackSource("resume", SourceKind.Direct(url), p.item.title, provider = "Server"), p.position - 5000))
        } else {
            nav.push(Screen.Detail(p.item))
        }
    }
}

@Composable
fun ChannelTile(ch: Channel, now: Programme?, onClick: () -> Unit) {
    Column(
        Modifier.width(Dims.landscape() * 0.9f).card(onClick, shape = RoundedCornerShape(14.dp)).background(Palette.surface).padding(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            ChannelLogo(ch.icon, ch.name, if (isTv()) 56.dp else 42.dp)
            Spacer(Modifier.width(10.dp))
            Column {
                Text(ch.name, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(now?.title ?: "Live", fontSize = 12.sp, color = Palette.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Spacer(Modifier.height(8.dp))
        Box(Modifier.fillMaxWidth()) { if (now != null) ProgressLine(now.progress) }
    }
    LaunchedEffect(ch.id) { GuideRepo.ensure(ch) }
}

@Suppress("unused")
private val spacing = Arrangement.spacedBy(8.dp)
