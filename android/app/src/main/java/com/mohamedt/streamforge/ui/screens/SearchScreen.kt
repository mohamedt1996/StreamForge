package com.mohamedt.streamforge.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.dispatcharr.Channel
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.dispatcharr.GuideRepo
import com.mohamedt.streamforge.metadata.Tmdb
import com.mohamedt.streamforge.player.Player
import com.mohamedt.streamforge.stremio.Addons
import com.mohamedt.streamforge.ui.Dims
import com.mohamedt.streamforge.ui.LocalNav
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.PosterCard
import com.mohamedt.streamforge.ui.Screen
import com.mohamedt.streamforge.ui.Shelf
import com.mohamedt.streamforge.ui.card
import kotlinx.coroutines.delay

@Composable
fun SearchScreen() {
    val nav = LocalNav.current
    val context = LocalContext.current
    var query by remember { mutableStateOf("") }
    var channels by remember { mutableStateOf<List<Channel>>(emptyList()) }
    var groups by remember { mutableStateOf<List<Pair<String, List<MediaItem>>>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }

    LaunchedEffect(query) {
        val q = query.trim()
        // Reset the spinner too: a cancelled previous search leaves `searching` true.
        if (q.length < 2) { channels = emptyList(); groups = emptyList(); searching = false; return@LaunchedEffect }
        delay(350)
        searching = true
        val lower = q.lowercase()
        channels = DispatcharrRepo.channels.filter { it.name.lowercase().contains(lower) }.take(30)
        val local = buildList {
            DispatcharrRepo.movieItems.filter { it.title.lowercase().contains(lower) }.take(40).takeIf { it.isNotEmpty() }?.let { add("Movies on ${DispatcharrRepo.active?.name ?: "your server"}" to it) }
            DispatcharrRepo.seriesItems.filter { it.title.lowercase().contains(lower) }.take(40).takeIf { it.isNotEmpty() }?.let { add("Series on ${DispatcharrRepo.active?.name ?: "your server"}" to it) }
        }
        groups = local
        if (Tmdb.configured) runCatching { Tmdb.search(q) }.getOrNull()?.takeIf { it.isNotEmpty() }?.let { groups = groups + ("TMDB" to it) }
        for ((entry, metas) in runCatching { Addons.search(q) }.getOrDefault(emptyList())) {
            groups = groups + ("${entry.title} · ${entry.addon.name}" to metas.take(40).map { it.toItem(entry.addon.id) })
        }
        searching = false
    }

    Column(Modifier.fillMaxSize()) {
        OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth().padding(Dims.gutter()), placeholder = { Text("Movies, series, channels") }, singleLine = true)
        LazyColumn(Modifier.fillMaxSize()) {
            item {
                Shelf("Live Channels", channels, key = { it.id }) { ch -> ChannelTile(ch, GuideRepo.now(ch)) { Player.playChannel(context, ch, channels) } }
            }
            groups.forEachIndexed { i, (title, items) ->
                // Two catalogs can share a display title: key by position to avoid duplicate-key crashes.
                item(key = "g$i") { Shelf(title, items, key = { it.id }) { PosterCard(it, { nav.push(Screen.Detail(it)) }) } }
            }
            if (searching) item { CircularProgressIndicator(Modifier.padding(24.dp)) }
            if (query.trim().length < 2) {
                item { Text("Explore addon catalogs", color = Palette.secondary, modifier = Modifier.padding(Dims.gutter())) }
                Addons.catalogs.forEachIndexed { i, entry ->
                    item(key = "c-$i-${entry.addon.id}-${entry.catalog.type}-${entry.catalog.id}") {
                        Text("${entry.title} · ${entry.addon.name}", color = Palette.accent,
                            modifier = Modifier.fillMaxWidth().padding(horizontal = Dims.gutter(), vertical = 2.dp)
                                .card({ nav.push(Screen.Catalog(entry)) }).padding(8.dp))
                    }
                }
            }
        }
    }
}
