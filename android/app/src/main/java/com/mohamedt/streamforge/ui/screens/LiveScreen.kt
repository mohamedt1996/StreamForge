package com.mohamedt.streamforge.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mohamedt.streamforge.core.Settings
import com.mohamedt.streamforge.dispatcharr.Channel
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.dispatcharr.GuideRepo
import com.mohamedt.streamforge.dispatcharr.LoadState
import com.mohamedt.streamforge.dispatcharr.Programme
import com.mohamedt.streamforge.library.Library
import com.mohamedt.streamforge.player.Player
import com.mohamedt.streamforge.ui.ChannelLogo
import com.mohamedt.streamforge.ui.Chip
import com.mohamedt.streamforge.ui.Dims
import com.mohamedt.streamforge.ui.EmptyState
import com.mohamedt.streamforge.ui.LiveBadge
import com.mohamedt.streamforge.ui.Loading
import com.mohamedt.streamforge.ui.LocalNav
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.Pill
import com.mohamedt.streamforge.ui.ProgressLine
import com.mohamedt.streamforge.ui.Screen
import com.mohamedt.streamforge.ui.card
import com.mohamedt.streamforge.ui.isTv
import com.mohamedt.streamforge.ui.isWide
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.launch

private sealed interface LiveFilter {
    data object Favorites : LiveFilter
    data object Recent : LiveFilter
    data object Sports : LiveFilter
    data object All : LiveFilter
    data class Category(val id: String) : LiveFilter
}

fun timeText(ms: Long): String = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(ms))

@Composable
fun LiveScreen() {
    val nav = LocalNav.current
    var filter by remember { mutableStateOf<LiveFilter>(if (Library.favoriteChannels.isNotEmpty()) LiveFilter.Favorites else LiveFilter.All) }
    var query by remember { mutableStateOf("") }
    var programmeFor by remember { mutableStateOf<Channel?>(null) }

    when {
        !DispatcharrRepo.isConfigured -> { EmptyState("No Dispatcharr server", "Sign in to your Dispatcharr server in Settings to watch live channels with the full TV guide."); return }
        DispatcharrRepo.liveState is LoadState.Failed && DispatcharrRepo.channels.isEmpty() ->
            { EmptyState("Couldn't load channels", (DispatcharrRepo.liveState as LoadState.Failed).message, "Retry") { DispatcharrRepo.refreshAll(true) }; return }
        DispatcharrRepo.channels.isEmpty() -> { Loading("Loading channels…"); return }
    }

    val list: List<Channel> = remember(filter, query, DispatcharrRepo.channels, Library.favoriteChannels, GuideRepo.programmes) {
        val base = when (val f = filter) {
            LiveFilter.Favorites -> Library.favoriteChannels.mapNotNull { DispatcharrRepo.channel(it) }
            LiveFilter.Recent -> Library.recentChannels.mapNotNull { DispatcharrRepo.channel(it) }
            LiveFilter.Sports -> DispatcharrRepo.channels.filter { GuideRepo.isSportsChannel(it) }
            LiveFilter.All -> DispatcharrRepo.channels.filter { !Library.isHidden("live:${it.categoryId}") }
            is LiveFilter.Category -> DispatcharrRepo.channelsByCategory[f.id] ?: emptyList()
        }
        val q = query.trim().lowercase()
        if (q.isEmpty()) base else base.filter { it.name.lowercase().contains(q) || it.number?.toString() == q }
    }

    val filters: @Composable (Boolean) -> Unit = { vertical ->
        val entries = buildList {
            add(Triple<LiveFilter, String, Int>(LiveFilter.Favorites, "★ Favorites", Library.favoriteChannels.size))
            add(Triple(LiveFilter.Recent, "Recent", Library.recentChannels.size))
            add(Triple(LiveFilter.Sports, "Sports & Events", 0))
            add(Triple(LiveFilter.All, "All Channels", DispatcharrRepo.channels.size))
            DispatcharrRepo.liveCategories.filter { !Library.isHidden("live:${it.id}") }.forEach {
                add(Triple(LiveFilter.Category(it.id), it.name, DispatcharrRepo.channelsByCategory[it.id]?.size ?: 0))
            }
        }
        if (vertical) {
            LazyColumn(Modifier.width(260.dp).fillMaxHeight(), contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                items(entries) { (f, name, count) ->
                    Row(Modifier.fillMaxWidth().card({ filter = f }, shape = RoundedCornerShape(10.dp))
                        .background(if (filter == f) Palette.surfaceHigh else Palette.background).padding(horizontal = 12.dp, vertical = 10.dp)) {
                        Text(name, Modifier.weight(1f), fontWeight = if (filter == f) FontWeight.Bold else FontWeight.Normal, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (count > 0) Text("$count", fontSize = 12.sp, color = Palette.secondary)
                    }
                }
            }
        } else {
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                entries.forEach { (f, name, _) -> Chip(name, filter == f) { filter = f } }
            }
        }
    }

    val header: @Composable () -> Unit = {
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(query, { query = it }, Modifier.weight(1f), placeholder = { Text("Filter channels") }, singleLine = true)
            Spacer(Modifier.width(8.dp))
            Row(Modifier.card({ nav.push(Screen.Guide) }).background(Palette.surfaceHigh).padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.CalendarMonth, null); Spacer(Modifier.width(6.dp)); Text("Guide")
            }
            if (DispatcharrRepo.restClient() != null) {
                Spacer(Modifier.width(8.dp))
                Row(Modifier.card({ nav.push(Screen.Recordings) }).background(Palette.surfaceHigh).padding(12.dp)) { Text("Recordings") }
            }
        }
    }

    val channelList: @Composable () -> Unit = {
        if (list.isEmpty()) {
            EmptyState(if (filter == LiveFilter.Favorites) "No favorites yet" else "Nothing here",
                if (filter == LiveFilter.Favorites) "Long-press a channel to add it to your favorites." else "No channels match.")
        } else {
            LazyColumn(contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(list, key = { it.id }) { ch -> ChannelRow(ch, list) { programmeFor = ch } }
            }
        }
    }

    if (isTv() || isWide()) {
        Row(Modifier.fillMaxSize()) {
            filters(true)
            Column(Modifier.weight(1f)) { header(); channelList() }
        }
    } else {
        Column(Modifier.fillMaxSize()) { header(); filters(false); channelList() }
    }

    programmeFor?.let { ch -> ProgrammeDialog(ch) { programmeFor = null } }
}

@Composable
fun ChannelRow(ch: Channel, list: List<Channel>, onLongClick: () -> Unit) {
    val context = LocalContext.current
    val now = GuideRepo.now(ch)
    val next = GuideRepo.next(ch)
    val sports = now?.let { GuideRepo.isEvent(it) } == true
    LaunchedEffect(ch.id) { GuideRepo.ensure(ch) }
    Row(
        Modifier.fillMaxWidth().card({ Player.playChannel(context, ch, list) }, onLongClick, RoundedCornerShape(14.dp))
            .background(Palette.surface).padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (Settings.values.showChannelNumbers && ch.number != null) {
            Text("${ch.number}", fontSize = 12.sp, color = Palette.secondary, modifier = Modifier.width(36.dp))
        }
        ChannelLogo(ch.icon, ch.name, if (isTv()) 64.dp else 48.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(ch.name, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                if (Library.isFavoriteChannel(ch.id)) { Spacer(Modifier.width(6.dp)); Icon(Icons.Filled.Star, null, tint = Palette.gold, modifier = Modifier.size(14.dp)) }
                if (ch.hasArchive) { Spacer(Modifier.width(6.dp)); Icon(Icons.Filled.History, null, tint = Palette.secondary, modifier = Modifier.size(14.dp)) }
                if (sports) { Spacer(Modifier.width(6.dp)); Pill("EVENT", Palette.live) }
            }
            if (now != null) {
                Text(now.title, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.width(90.dp)) { ProgressLine(now.progress) }
                    Spacer(Modifier.width(8.dp))
                    Text("${timeText(now.start)} – ${timeText(now.end)}", fontSize = 11.sp, color = Palette.secondary)
                }
            } else {
                Text("No programme information", fontSize = 12.sp, color = Palette.secondary)
            }
            next?.let { Text("Next: ${it.title}", fontSize = 12.sp, color = Palette.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
    }
}

/** Full schedule for one channel: watch, catch-up, record, favorite. */
@Composable
fun ProgrammeDialog(ch: Channel, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var message by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(ch.id) { GuideRepo.ensure(ch) }
    val programmes = GuideRepo.forChannel(ch).filter { it.end > System.currentTimeMillis() - (ch.archiveDays.coerceAtLeast(1)) * 86_400_000L }
    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
        dismissButton = {
            TextButton(onClick = { Library.toggleFavoriteChannel(ch.id) }) {
                Text(if (Library.isFavoriteChannel(ch.id)) "Remove favorite" else "Add to favorites")
            }
        },
        title = { Text(ch.name) },
        text = {
            Column {
                message?.let { Text(it, color = Palette.accent) }
                LazyColumn(Modifier.height(420.dp)) {
                    items(programmes) { p -> ProgrammeRow(ch, p, onWatch = { onDismiss(); Player.playChannel(context, ch, emptyList()) },
                        onCatchup = { onDismiss(); Player.playCatchup(context, ch, p) },
                        onRecord = {
                            scope.launch {
                                message = runCatching { DispatcharrRepo.restClient()?.scheduleRecording(ch.id, p); "Scheduled “${p.title}”" }
                                    .getOrElse { it.message ?: "Couldn't schedule" }
                            }
                        }) }
                }
            }
        },
    )
}

@Composable
private fun ProgrammeRow(ch: Channel, p: Programme, onWatch: () -> Unit, onCatchup: () -> Unit, onRecord: () -> Unit) {
    val past = p.end < System.currentTimeMillis()
    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(timeText(p.start), fontWeight = FontWeight.SemiBold, modifier = Modifier.width(64.dp))
            Text(p.title, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f), color = if (past) Palette.secondary else androidx.compose.ui.graphics.Color.White)
            if (p.isLive) LiveBadge()
        }
        p.desc?.let { Text(it, fontSize = 12.sp, color = Palette.secondary, maxLines = 2, overflow = TextOverflow.Ellipsis) }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (p.isLive) TextButton(onClick = onWatch) { Text("Watch") }
            if (past && ch.hasArchive) TextButton(onClick = onCatchup) { Text("Catch-up") }
            if (!past && !p.isLive && DispatcharrRepo.restClient() != null) TextButton(onClick = onRecord) { Text("Record") }
        }
    }
}
