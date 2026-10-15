package com.mohamedt.streamforge.ui.screens

import android.view.KeyEvent as NativeKeyEvent
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
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
import com.mohamedt.streamforge.ui.ButtonKind
import com.mohamedt.streamforge.ui.ChannelLogo
import com.mohamedt.streamforge.ui.Chip
import com.mohamedt.streamforge.ui.Dims
import com.mohamedt.streamforge.ui.EmptyState
import com.mohamedt.streamforge.ui.InitialFocus
import com.mohamedt.streamforge.ui.LiveBadge
import com.mohamedt.streamforge.ui.Loading
import com.mohamedt.streamforge.ui.LocalNav
import com.mohamedt.streamforge.ui.PageTitle
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.Pill
import com.mohamedt.streamforge.ui.ProgressLine
import com.mohamedt.streamforge.ui.Screen
import com.mohamedt.streamforge.ui.SfButton
import com.mohamedt.streamforge.ui.SfDialog
import com.mohamedt.streamforge.ui.SfListRow
import com.mohamedt.streamforge.ui.SfTextField
import com.mohamedt.streamforge.ui.card
import com.mohamedt.streamforge.ui.isTv
import com.mohamedt.streamforge.ui.isWide
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private sealed interface LiveFilter {
    data object Favorites : LiveFilter
    data object Recent : LiveFilter
    data object Sports : LiveFilter
    data object All : LiveFilter
    data class Category(val id: String) : LiveFilter
}

fun timeText(ms: Long): String = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(ms))

/** The channel the TV preview panel describes; only the panel reads it, so focus moves stay cheap. */
private class LiveFocus {
    var channel by mutableStateOf<Channel?>(null)
}

@Composable
fun LiveScreen() {
    val nav = LocalNav.current
    val context = LocalContext.current
    val tv = isTv()
    var filter by remember { mutableStateOf<LiveFilter>(if (Library.favoriteChannels.isNotEmpty()) LiveFilter.Favorites else LiveFilter.All) }
    var query by remember { mutableStateOf("") }
    var programmeFor by remember { mutableStateOf<Channel?>(null) }
    var numberEntry by remember { mutableStateOf("") }

    when {
        !DispatcharrRepo.isConfigured -> { EmptyState("No Dispatcharr server", "Sign in to your Dispatcharr server in Settings to watch live channels with the full TV guide."); return }
        DispatcharrRepo.liveState is LoadState.Failed && DispatcharrRepo.channels.isEmpty() ->
            { EmptyState("Couldn't load channels", (DispatcharrRepo.liveState as LoadState.Failed).message, "Retry") { DispatcharrRepo.refreshAll(true) }; return }
        DispatcharrRepo.channels.isEmpty() -> { Loading("Loading channels…"); return }
    }

    val list: List<Channel> = remember(filter, query, DispatcharrRepo.channels, Library.favoriteChannels, Library.recentChannels, GuideRepo.programmes) {
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

    val entries = buildList {
        add(Triple<LiveFilter, String, Int>(LiveFilter.Favorites, "★ Favorites", Library.favoriteChannels.size))
        add(Triple(LiveFilter.Recent, "Recent", Library.recentChannels.size))
        add(Triple(LiveFilter.Sports, "Sports & Events", 0))
        add(Triple(LiveFilter.All, "All Channels", DispatcharrRepo.channels.size))
        DispatcharrRepo.liveCategories.filter { !Library.isHidden("live:${it.id}") }.forEach {
            add(Triple(LiveFilter.Category(it.id), it.name, DispatcharrRepo.channelsByCategory[it.id]?.size ?: 0))
        }
    }

    // Typing a channel number on the remote tunes to it (same as in the player).
    LaunchedEffect(numberEntry) {
        if (numberEntry.isEmpty()) return@LaunchedEffect
        delay(1500)
        val n = numberEntry.toIntOrNull()
        numberEntry = ""
        val ch = n?.let { num -> DispatcharrRepo.channels.firstOrNull { it.number == num } }
        if (ch != null) Player.playChannel(context, ch, DispatcharrRepo.channels)
    }

    if (tv) {
        LiveTv(
            entries = entries, filter = filter, onFilter = { filter = it }, list = list, query = query, onQuery = { query = it },
            numberEntry = numberEntry, onDigit = { d -> numberEntry = (numberEntry + d).take(5) },
            onSchedule = { programmeFor = it },
        )
    } else {
        val filters: @Composable (Boolean) -> Unit = { vertical ->
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

        if (isWide()) {
            Row(Modifier.fillMaxSize()) {
                filters(true)
                Column(Modifier.weight(1f)) { header(); channelList() }
            }
        } else {
            Column(Modifier.fillMaxSize()) { header(); filters(false); channelList() }
        }
    }

    programmeFor?.let { ch -> ProgrammeDialog(ch) { programmeFor = null } }
}

// MARK: TV

@Composable
private fun LiveTv(
    entries: List<Triple<LiveFilter, String, Int>>,
    filter: LiveFilter,
    onFilter: (LiveFilter) -> Unit,
    list: List<Channel>,
    query: String,
    onQuery: (String) -> Unit,
    numberEntry: String,
    onDigit: (Int) -> Unit,
    onSchedule: (Channel) -> Unit,
) {
    val nav = LocalNav.current
    val focus = remember { LiveFocus() }
    val firstChannel = remember { FocusRequester() }
    InitialFocus(firstChannel, key = list.isNotEmpty())

    Box(
        Modifier.fillMaxSize().onPreviewKeyEvent { e ->
            val code = e.nativeKeyEvent.keyCode
            val digit = when (code) {
                in NativeKeyEvent.KEYCODE_0..NativeKeyEvent.KEYCODE_9 -> code - NativeKeyEvent.KEYCODE_0
                in NativeKeyEvent.KEYCODE_NUMPAD_0..NativeKeyEvent.KEYCODE_NUMPAD_9 -> code - NativeKeyEvent.KEYCODE_NUMPAD_0
                else -> -1
            }
            if (digit < 0) {
                false
            } else {
                if (e.type == KeyEventType.KeyDown) onDigit(digit)
                true
            }
        },
    ) {
        Column(Modifier.fillMaxSize().padding(top = Dims.overscanY)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = Dims.gutter()).height(66.dp), verticalAlignment = Alignment.CenterVertically) {
                PageTitle("Live TV", Modifier.weight(1f))
                SfTextField(query, onQuery, "Filter channels", Modifier.width(300.dp), icon = Icons.Filled.Search)
                Spacer(Modifier.width(14.dp))
                SfButton("Guide", { nav.push(Screen.Guide) }, icon = Icons.Filled.CalendarMonth)
                if (DispatcharrRepo.restClient() != null) {
                    Spacer(Modifier.width(14.dp))
                    SfButton("Recordings", { nav.push(Screen.Recordings) }, icon = Icons.Filled.FiberManualRecord)
                }
            }
            Spacer(Modifier.height(14.dp))
            Row(Modifier.weight(1f).fillMaxWidth()) {
                // Categories
                LazyColumn(
                    Modifier.width(250.dp).fillMaxHeight(),
                    contentPadding = PaddingValues(start = Dims.gutter() - 12.dp, end = 8.dp, bottom = Dims.overscanY),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    items(entries, key = { it.second + it.first.toString() }) { (f, name, count) ->
                        SfListRow(name, { onFilter(f) }, selected = filter == f, trailing = if (count > 0) "$count" else null)
                    }
                }
                // Channels
                Box(Modifier.weight(1f).fillMaxHeight()) {
                    if (list.isEmpty()) {
                        EmptyState(if (filter == LiveFilter.Favorites) "No favorites yet" else "Nothing here",
                            if (filter == LiveFilter.Favorites) "Open a channel's schedule and choose Add to favorites." else "No channels match.")
                    } else {
                        LazyColumn(
                            Modifier.fillMaxSize(),
                            contentPadding = PaddingValues(start = 10.dp, end = 14.dp, top = 6.dp, bottom = Dims.overscanY + 40.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            itemsIndexed(list, key = { _, ch -> ch.id }) { index, ch ->
                                TvChannelRow(ch, list, if (index == 0) firstChannel else null, onFocused = { focus.channel = ch }) { onSchedule(ch) }
                            }
                        }
                    }
                }
                ChannelPreview(focus, onSchedule, Modifier.width(300.dp).fillMaxHeight().padding(end = Dims.gutter(), bottom = Dims.overscanY))
            }
        }
        if (numberEntry.isNotEmpty()) {
            Text(numberEntry, fontSize = 56.sp, fontWeight = FontWeight.Black,
                modifier = Modifier.align(Alignment.TopEnd).padding(top = 40.dp, end = 60.dp)
                    .clip(RoundedCornerShape(16.dp)).background(Palette.raised).padding(horizontal = 26.dp, vertical = 8.dp))
        }
    }
}

@Composable
private fun TvChannelRow(ch: Channel, list: List<Channel>, requester: FocusRequester?, onFocused: () -> Unit, onSchedule: () -> Unit) {
    val context = LocalContext.current
    val now = GuideRepo.now(ch)
    val sports = now?.let { GuideRepo.isEvent(it) } == true
    LaunchedEffect(ch.id) { GuideRepo.ensure(ch) }
    Row(
        Modifier.fillMaxWidth().height(88.dp)
            .card({ Player.playChannel(context, ch, list) }, onSchedule, RoundedCornerShape(16.dp), focusScale = 1.02f, glow = false,
                focusKey = "ch/${ch.id}", focusRequester = requester, onFocus = { if (it) onFocused() })
            .background(Palette.surface)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (Settings.values.showChannelNumbers && ch.number != null) {
            Text("${ch.number}", fontSize = 17.sp, color = Palette.secondary, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(52.dp), maxLines = 1)
        }
        ChannelLogo(ch.icon, ch.name, 58.dp)
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(ch.name, fontSize = 19.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                if (Library.isFavoriteChannel(ch.id)) { Spacer(Modifier.width(8.dp)); Icon(Icons.Filled.Star, null, tint = Palette.gold, modifier = Modifier.size(18.dp)) }
                if (ch.hasArchive) { Spacer(Modifier.width(8.dp)); Icon(Icons.Filled.History, null, tint = Palette.secondary, modifier = Modifier.size(18.dp)) }
                if (sports) { Spacer(Modifier.width(8.dp)); Pill("EVENT", Palette.live) }
            }
            if (now != null) {
                Text(now.title, fontSize = 16.sp, color = Color.White.copy(alpha = 0.85f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.height(4.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.width(140.dp)) { ProgressLine(now.progress, height = 4.dp) }
                    Spacer(Modifier.width(10.dp))
                    Text("${timeText(now.start)} – ${timeText(now.end)}", fontSize = 14.sp, color = Palette.secondary, maxLines = 1)
                }
            } else {
                Text("No programme information", fontSize = 15.sp, color = Palette.secondary)
            }
        }
    }
}

/** Right-hand panel: what's on the focused channel now and next, with watch / schedule / favorite. */
@Composable
private fun ChannelPreview(focus: LiveFocus, onSchedule: (Channel) -> Unit, modifier: Modifier) {
    val ch = focus.channel
    Column(modifier.padding(start = 12.dp)) {
        if (ch != null) ChannelPreviewBody(ch, onSchedule)
    }
}

@Composable
private fun ChannelPreviewBody(ch: Channel, onSchedule: (Channel) -> Unit) {
    val context = LocalContext.current
    run {
        val now = GuideRepo.now(ch)
        val next = GuideRepo.next(ch)
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Palette.surface).padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ChannelLogo(ch.icon, ch.name, 52.dp)
                Spacer(Modifier.width(12.dp))
                Text(ch.name, fontSize = 18.sp, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            Spacer(Modifier.height(16.dp))
            if (now != null) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    LiveBadge()
                    Spacer(Modifier.width(8.dp))
                    Text("${timeText(now.start)} – ${timeText(now.end)}", fontSize = 14.sp, color = Palette.secondary)
                }
                Spacer(Modifier.height(6.dp))
                Text(now.title, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                now.desc?.let {
                    Spacer(Modifier.height(4.dp))
                    Text(it, fontSize = 15.sp, lineHeight = 21.sp, color = Palette.secondary, maxLines = 4, overflow = TextOverflow.Ellipsis)
                }
                Spacer(Modifier.height(10.dp))
                ProgressLine(now.progress, height = 4.dp)
            } else {
                Text("No programme information", fontSize = 16.sp, color = Palette.secondary)
            }
            next?.let {
                Spacer(Modifier.height(16.dp))
                Text("Next at ${timeText(it.start)}", fontSize = 14.sp, color = Palette.secondary)
                Text(it.title, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Spacer(Modifier.height(14.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SfButton(null, { Player.playChannel(context, ch, DispatcharrRepo.channels) }, icon = Icons.Filled.PlayArrow, kind = ButtonKind.PRIMARY, contentDescription = "Watch")
            SfButton(null, { onSchedule(ch) }, icon = Icons.Filled.Schedule, contentDescription = "Schedule")
            SfButton(null, { Library.toggleFavoriteChannel(ch.id) }, icon = if (Library.isFavoriteChannel(ch.id)) Icons.Filled.Star else Icons.Filled.StarBorder,
                contentDescription = if (Library.isFavoriteChannel(ch.id)) "Remove favorite" else "Add to favorites")
        }
    }
}

// MARK: Phone rows

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
        ChannelLogo(ch.icon, ch.name, 48.dp)
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

// MARK: Schedule

/** Full schedule for one channel: watch, catch-up, record, favorite. */
@Composable
fun ProgrammeDialog(ch: Channel, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val tv = isTv()
    var message by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(ch.id) { GuideRepo.ensure(ch) }
    val programmes = GuideRepo.forChannel(ch).filter { it.end > System.currentTimeMillis() - (ch.archiveDays.coerceAtLeast(1)) * 86_400_000L }
    val liveIndex = programmes.indexOfFirst { it.isLive }.coerceAtLeast(0)
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = liveIndex)
    val first = remember { FocusRequester() }
    val favorite = Library.isFavoriteChannel(ch.id)
    val watch = { onDismiss(); Player.playChannel(context, ch, emptyList()) }
    val record: (Programme) -> Unit = { p ->
        scope.launch {
            message = runCatching { DispatcharrRepo.restClient()?.scheduleRecording(ch.id, p); "Scheduled “${p.title}”" }
                .getOrElse { it.message ?: "Couldn't schedule" }
        }
    }

    SfDialog(
        ch.name, onDismiss,
        subtitle = (if (tv) message else null) ?: GuideRepo.now(ch)?.let { "Now: ${it.title}" },
        actions = {
            if (tv) {
                SfButton("Watch", watch, icon = Icons.Filled.PlayArrow, kind = ButtonKind.PRIMARY)
                SfButton(if (favorite) "Remove favorite" else "Add to favorites", { Library.toggleFavoriteChannel(ch.id) },
                    icon = if (favorite) Icons.Filled.Star else Icons.Filled.StarBorder)
            } else {
                TextButton(onClick = { Library.toggleFavoriteChannel(ch.id) }) { Text(if (favorite) "Remove favorite" else "Add to favorites") }
            }
        },
    ) {
        if (!tv) message?.let { Text(it, color = Palette.accent) }
        LazyColumn(if (tv) Modifier.fillMaxSize() else Modifier.height(420.dp), state = listState, verticalArrangement = Arrangement.spacedBy(if (tv) 4.dp else 0.dp)) {
            if (programmes.isEmpty()) item { Text("No guide data for this channel.", color = Palette.secondary, fontSize = if (tv) 18.sp else 14.sp) }
            itemsIndexed(programmes) { i, p ->
                val past = p.end < System.currentTimeMillis()
                val canRecord = !past && !p.isLive && DispatcharrRepo.restClient() != null
                if (tv) {
                    val action: (() -> Unit)? = when {
                        p.isLive -> watch
                        past && ch.hasArchive -> { { onDismiss(); Player.playCatchup(context, ch, p) } }
                        canRecord -> { { record(p) } }
                        else -> null
                    }
                    val label = when {
                        p.isLive -> "Watch"
                        past && ch.hasArchive -> "Catch-up"
                        canRecord -> "Record"
                        else -> null
                    }
                    SfListRow(
                        title = "${timeText(p.start)}   ${p.title}",
                        onClick = { action?.invoke() },
                        detail = p.desc,
                        selected = p.isLive,
                        trailing = label,
                        focusRequester = if (i == liveIndex) first else null,
                    )
                } else {
                    ProgrammeRow(ch, p, onWatch = watch, onCatchup = { onDismiss(); Player.playCatchup(context, ch, p) }, onRecord = { record(p) })
                }
            }
        }
        if (tv && programmes.isNotEmpty()) InitialFocus(first, always = true)
    }
}

@Composable
private fun ProgrammeRow(ch: Channel, p: Programme, onWatch: () -> Unit, onCatchup: () -> Unit, onRecord: () -> Unit) {
    val past = p.end < System.currentTimeMillis()
    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(timeText(p.start), fontWeight = FontWeight.SemiBold, modifier = Modifier.width(64.dp))
            Text(p.title, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f), color = if (past) Palette.secondary else Color.White)
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
