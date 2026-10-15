package com.mohamedt.streamforge.ui.screens

import androidx.compose.foundation.ScrollState
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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mohamedt.streamforge.dispatcharr.Channel
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.dispatcharr.GuideRepo
import com.mohamedt.streamforge.dispatcharr.Programme
import com.mohamedt.streamforge.library.Library
import com.mohamedt.streamforge.player.Player
import com.mohamedt.streamforge.ui.ChannelLogo
import com.mohamedt.streamforge.ui.Chip
import com.mohamedt.streamforge.ui.Dims
import com.mohamedt.streamforge.ui.InitialFocus
import com.mohamedt.streamforge.ui.LiveBadge
import com.mohamedt.streamforge.ui.PageTitle
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.card
import com.mohamedt.streamforge.ui.isTv
import kotlinx.coroutines.delay

/** What the TV guide's info strip shows; only the strip reads it. */
private class GuideFocus {
    var channel by mutableStateOf<Channel?>(null)
    var programme by mutableStateOf<Programme?>(null)
}

private class GuideMetrics(val minuteWidth: Dp, val rowHeight: Dp, val channelWidth: Dp, val hours: Int) {
    val timelineWidth: Dp get() = minuteWidth * (hours * 60)
    fun x(windowStart: Long, t: Long): Dp = minuteWidth * ((t - windowStart) / 60_000f)
}

/** TV guide grid: channels down, time across; every row shares one horizontal scroll, with a time ruler and a now-line. */
@Composable
fun GuideScreen() {
    val tv = isTv()
    val m = remember(tv) { if (tv) GuideMetrics(6.dp, 74.dp, 230.dp, 12) else GuideMetrics(4.dp, 60.dp, 120.dp, 12) }
    var windowStart by remember { mutableStateOf(roundedStart()) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var favoritesOnly by remember { mutableStateOf(false) }
    var detailsFor by remember { mutableStateOf<Channel?>(null) }
    val scroll = rememberScrollState()
    val focus = remember { GuideFocus() }
    val firstLive = remember { FocusRequester() }
    val channels = if (favoritesOnly) Library.favoriteChannels.mapNotNull { DispatcharrRepo.channel(it) }
    else DispatcharrRepo.channels.filter { !Library.isHidden("live:${it.categoryId}") }

    LaunchedEffect(Unit) {
        GuideRepo.refreshIfStale()
        while (true) {
            delay(30_000)
            now = System.currentTimeMillis()
            windowStart = roundedStart()
        }
    }
    InitialFocus(firstLive, key = channels.isNotEmpty())

    val gutter = if (tv) Dims.gutter() else 12.dp
    Column(Modifier.fillMaxSize().padding(top = if (tv) Dims.overscanY else 0.dp)) {
        Row(Modifier.fillMaxWidth().padding(horizontal = gutter, vertical = if (tv) 4.dp else 12.dp), verticalAlignment = Alignment.CenterVertically) {
            PageTitle(if (tv) "TV guide" else "TV Guide", Modifier.weight(1f))
            if (GuideRepo.refreshing) Text("Updating guide…  ", color = Palette.secondary, fontSize = if (tv) 16.sp else 12.sp)
            if (tv) {
                Text(timeText(now), fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = Palette.secondary)
                Spacer(Modifier.width(20.dp))
            }
            Chip("Favorites", favoritesOnly) { favoritesOnly = true }
            Spacer(Modifier.width(if (tv) 12.dp else 8.dp))
            Chip("All", !favoritesOnly) { favoritesOnly = false }
        }
        if (tv) GuideInfo(focus, Modifier.padding(horizontal = gutter).height(104.dp))

        // Time ruler with the current time marked.
        Row(Modifier.fillMaxWidth().padding(top = if (tv) 6.dp else 0.dp)) {
            Spacer(Modifier.width(m.channelWidth + gutter + 4.dp))
            Box(Modifier.horizontalScroll(scroll).width(m.timelineWidth).height(if (tv) 34.dp else 22.dp)) {
                repeat(m.hours * 2) { i ->
                    val t = windowStart + i * 1_800_000L
                    Text(timeText(t), fontSize = if (tv) 15.sp else 12.sp, color = Palette.secondary,
                        modifier = Modifier.offset(x = m.x(windowStart, t)).padding(start = 6.dp))
                }
                val nx = m.x(windowStart, now)
                Box(Modifier.offset(x = nx - 1.dp).width(2.dp).fillMaxHeight().background(Palette.accent2))
                if (tv) {
                    Text("Now", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Color.White,
                        modifier = Modifier.offset(x = nx + 4.dp).align(Alignment.BottomStart)
                            .clip(RoundedCornerShape(4.dp)).background(Palette.accent2).padding(horizontal = 6.dp, vertical = 1.dp))
                }
            }
        }
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = 4.dp, bottom = if (tv) Dims.overscanY + 24.dp else 8.dp)) {
            itemsIndexed(channels, key = { _, ch -> ch.id }) { index, ch ->
                GuideRow(ch, channels, windowStart, now, m, gutter, scroll, focus, if (index == 0) firstLive else null) { detailsFor = ch }
            }
        }
    }

    // Upcoming programmes / long-press: full schedule with Record, catch-up and favorite.
    detailsFor?.let { ch -> ProgrammeDialog(ch) { detailsFor = null } }
}

private fun roundedStart(): Long {
    val now = System.currentTimeMillis() - 30 * 60_000
    return now - now % 1_800_000L
}

@Composable
private fun GuideInfo(focus: GuideFocus, modifier: Modifier) {
    val p = focus.programme
    val ch = focus.channel
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.Center) {
        if (p == null || ch == null) {
            Text("Select a programme to watch it, catch up on it or record it.", fontSize = 17.sp, color = Palette.secondary)
        } else {
            GuideInfoBody(ch, p)
        }
    }
}

@Composable
private fun GuideInfoBody(ch: Channel, p: Programme) {
    run {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (p.isLive) {
                LiveBadge()
                Spacer(Modifier.width(10.dp))
            }
            Text(p.title, fontSize = 24.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text("${ch.name}   ${timeText(p.start)} – ${timeText(p.end)}" + (p.subtitle?.let { "   $it" } ?: ""),
            fontSize = 16.sp, color = Palette.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        p.desc?.let { Text(it, fontSize = 15.sp, lineHeight = 21.sp, color = Color.White.copy(alpha = 0.8f), maxLines = 2, overflow = TextOverflow.Ellipsis) }
    }
}

@Composable
private fun GuideRow(
    ch: Channel,
    list: List<Channel>,
    windowStart: Long,
    now: Long,
    m: GuideMetrics,
    gutter: Dp,
    scroll: ScrollState,
    focus: GuideFocus,
    firstLive: FocusRequester?,
    onDetails: () -> Unit,
) {
    val context = LocalContext.current
    val tv = isTv()
    LaunchedEffect(ch.id) { GuideRepo.ensure(ch) }
    val windowEnd = windowStart + m.hours * 3_600_000L
    val programmes = GuideRepo.forChannel(ch).filter { it.end > windowStart && it.start < windowEnd }
    Row(Modifier.fillMaxWidth().height(m.rowHeight).padding(start = gutter, top = 3.dp, bottom = 3.dp)) {
        Row(
            Modifier.width(m.channelWidth).fillMaxHeight()
                .card({ Player.playChannel(context, ch, list) }, onDetails, RoundedCornerShape(10.dp), focusScale = if (tv) 1.03f else null, glow = false,
                    focusKey = "gch/${ch.id}")
                .background(Palette.surfaceHigh).padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ChannelLogo(ch.icon, ch.name, m.rowHeight * 0.6f)
            Spacer(Modifier.width(8.dp))
            Text(ch.name, fontSize = if (tv) 16.sp else 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(4.dp))
        Box(Modifier.horizontalScroll(scroll).width(m.timelineWidth).fillMaxHeight()) {
            if (programmes.isEmpty()) {
                Text("No guide data", fontSize = if (tv) 15.sp else 12.sp, color = Palette.secondary, modifier = Modifier.padding(10.dp))
            }
            programmes.forEach { p ->
                val start = maxOf(p.start, windowStart)
                val end = minOf(p.end, windowEnd)
                val x = m.x(windowStart, start)
                val w = m.minuteWidth * ((end - start) / 60_000f)
                ProgrammeCell(
                    p, now, Modifier.offset(x = x).width(maxOf(w - 3.dp, 1.dp)).fillMaxHeight(),
                    requester = if (firstLive != null && p.isLive) firstLive else null,
                    focusKey = "gp/${ch.id}/${p.start}",
                    onFocused = { focus.channel = ch; focus.programme = p },
                    onClick = {
                        if (p.isLive) Player.playChannel(context, ch, list)
                        else if (p.end < System.currentTimeMillis() && ch.hasArchive) Player.playCatchup(context, ch, p)
                        else onDetails()
                    },
                    onLongClick = onDetails,
                )
            }
            // Now-line across the row.
            Box(Modifier.offset(x = m.x(windowStart, now) - 1.dp).width(2.dp).fillMaxHeight().background(Palette.accent2.copy(alpha = 0.9f)))
        }
    }
}

@Composable
private fun ProgrammeCell(
    p: Programme,
    now: Long,
    modifier: Modifier,
    requester: FocusRequester?,
    focusKey: String,
    onFocused: () -> Unit,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
) {
    val tv = isTv()
    var focused by remember { mutableStateOf(false) }
    val live = p.start <= now && now < p.end
    val past = p.end <= now
    val bg = when {
        focused && tv -> Color.White
        live -> Palette.accent.copy(alpha = 0.38f)
        past -> Palette.surface
        else -> Palette.surfaceHigh
    }
    val fg = when {
        focused && tv -> Palette.onFocus
        past -> Palette.secondary
        else -> Color.White
    }
    Column(
        modifier
            .card(onClick, onLongClick, RoundedCornerShape(8.dp), focusScale = 1f, border = !tv, glow = false,
                focusKey = focusKey, focusRequester = requester, onFocus = { f -> focused = f; if (f) onFocused() })
            .background(bg)
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Text(p.title, fontSize = if (tv) 16.sp else 12.sp, fontWeight = FontWeight.SemiBold, color = fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text("${timeText(p.start)} – ${timeText(p.end)}", fontSize = if (tv) 13.sp else 10.sp,
            color = if (focused && tv) Palette.onFocus.copy(alpha = 0.7f) else Palette.secondary, maxLines = 1)
        if (live && tv) {
            Spacer(Modifier.height(4.dp))
            Box(Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)).background(Color.White.copy(alpha = 0.2f))) {
                Box(Modifier.fillMaxWidth(p.progress).height(3.dp).background(if (focused) Palette.accent else Color.White))
            }
        }
    }
}
