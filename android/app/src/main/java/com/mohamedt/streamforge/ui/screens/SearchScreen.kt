package com.mohamedt.streamforge.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.dispatcharr.Channel
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.dispatcharr.GuideRepo
import com.mohamedt.streamforge.metadata.Tmdb
import com.mohamedt.streamforge.player.Player
import com.mohamedt.streamforge.stremio.Addons
import com.mohamedt.streamforge.ui.Dims
import com.mohamedt.streamforge.ui.InitialFocus
import com.mohamedt.streamforge.ui.KeylineScroll
import com.mohamedt.streamforge.ui.LocalNav
import com.mohamedt.streamforge.ui.PageTitle
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.PosterCard
import com.mohamedt.streamforge.ui.Screen
import com.mohamedt.streamforge.ui.SfListRow
import com.mohamedt.streamforge.ui.SfTextField
import com.mohamedt.streamforge.ui.Shelf
import com.mohamedt.streamforge.ui.TvRowCardOffset
import com.mohamedt.streamforge.ui.card
import com.mohamedt.streamforge.ui.isTv
import kotlinx.coroutines.delay

@Composable
fun SearchScreen() {
    val nav = LocalNav.current
    val context = LocalContext.current
    val tv = isTv()
    var query by rememberSaveable { mutableStateOf("") }
    var channels by remember { mutableStateOf<List<Channel>>(emptyList()) }
    var groups by remember { mutableStateOf<List<Pair<String, List<MediaItem>>>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    val fieldFocus = remember { FocusRequester() }

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
    InitialFocus(fieldFocus)

    Column(Modifier.fillMaxSize().padding(top = if (tv) Dims.overscanY else 0.dp)) {
        if (tv) {
            Row(Modifier.fillMaxWidth().padding(horizontal = Dims.gutter()), verticalAlignment = Alignment.CenterVertically) {
                PageTitle("Search", Modifier.padding(end = 28.dp))
                SfTextField(query, { query = it }, "Movies, series, channels — press OK to type or speak", Modifier.widthIn(max = 680.dp),
                    icon = Icons.Filled.Search, imeAction = ImeAction.Search, focusRequester = fieldFocus)
            }
            Spacer(Modifier.height(10.dp))
        } else {
            SfTextField(query, { query = it }, "Movies, series, channels", Modifier.padding(Dims.gutter()), icon = Icons.Filled.Search,
                imeAction = ImeAction.Search, focusRequester = fieldFocus)
        }
        KeylineScroll(TvRowCardOffset, enabled = tv) {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = if (tv) 120.dp else 16.dp)) {
                item(key = "channels") {
                    Shelf("Live channels", channels, key = { it.id }, rowKey = "channels") { ch ->
                        ChannelTile(ch, GuideRepo.now(ch)) { Player.playChannel(context, ch, channels) }
                    }
                }
                groups.forEachIndexed { i, (title, items) ->
                    // Two catalogs can share a display title: key by position to avoid duplicate-key crashes.
                    item(key = "g$i") { Shelf(title, items, key = { it.id }, rowKey = "g$i") { PosterCard(it, { nav.push(Screen.Detail(it)) }) } }
                }
                if (searching) item(key = "spinner") { CircularProgressIndicator(Modifier.padding(horizontal = Dims.gutter(), vertical = 24.dp), color = Color.White) }
                if (!searching && query.trim().length >= 2 && channels.isEmpty() && groups.isEmpty()) item(key = "none") {
                    Text("Nothing found for “${query.trim()}”. Try another title or check the spelling.", color = Palette.secondary,
                        fontSize = if (tv) 18.sp else 14.sp, modifier = Modifier.padding(horizontal = Dims.gutter(), vertical = 16.dp))
                }
                if (query.trim().length < 2) {
                    item(key = "explore") {
                        Text("Explore addon catalogs", color = if (tv) Color.White else Palette.secondary, fontSize = if (tv) 22.sp else 14.sp,
                            fontWeight = if (tv) FontWeight.SemiBold else FontWeight.Normal,
                            modifier = Modifier.padding(horizontal = Dims.gutter(), vertical = if (tv) 12.dp else 16.dp))
                    }
                    Addons.catalogs.forEachIndexed { i, entry ->
                        item(key = "c-$i-${entry.addon.id}-${entry.catalog.type}-${entry.catalog.id}") {
                            if (tv) {
                                SfListRow(entry.title, { nav.push(Screen.Catalog(entry)) },
                                    Modifier.padding(horizontal = Dims.gutter() - 18.dp, vertical = 2.dp).widthIn(max = 760.dp), detail = entry.addon.name)
                            } else {
                                Text("${entry.title} · ${entry.addon.name}", color = Palette.accent,
                                    modifier = Modifier.fillMaxWidth().padding(horizontal = Dims.gutter(), vertical = 2.dp)
                                        .card({ nav.push(Screen.Catalog(entry)) }).padding(8.dp))
                            }
                        }
                    }
                }
            }
        }
    }
}
