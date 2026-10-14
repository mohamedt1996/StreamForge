package com.mohamedt.streamforge.ui.screens

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
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
import com.mohamedt.streamforge.dispatcharr.Channel
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.dispatcharr.GuideRepo
import com.mohamedt.streamforge.library.Library
import com.mohamedt.streamforge.player.Player
import com.mohamedt.streamforge.ui.ChannelLogo
import com.mohamedt.streamforge.ui.Chip
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.card
import com.mohamedt.streamforge.ui.isTv
import kotlinx.coroutines.delay

/** TV guide grid: channels down, time across; every row shares one horizontal scroll. */
@Composable
fun GuideScreen() {
    val tv = isTv()
    val minuteWidth = if (tv) 7.dp else 4.dp
    val rowHeight = if (tv) 76.dp else 60.dp
    val channelWidth = if (tv) 220.dp else 120.dp
    val hours = 12
    var windowStart by remember { mutableStateOf(roundedStart()) }
    var favoritesOnly by remember { mutableStateOf(false) }
    val scroll = rememberScrollState()
    val channels = if (favoritesOnly) Library.favoriteChannels.mapNotNull { DispatcharrRepo.channel(it) }
    else DispatcharrRepo.channels.filter { !Library.isHidden("live:${it.categoryId}") }

    LaunchedEffect(Unit) {
        GuideRepo.refreshIfStale()
        while (true) { delay(60_000); windowStart = roundedStart() }
    }

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("TV Guide", fontSize = 22.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            if (GuideRepo.refreshing) Text("Updating guide…  ", color = Palette.secondary, fontSize = 12.sp)
            Chip("Favorites", favoritesOnly) { favoritesOnly = true }
            Spacer(Modifier.width(8.dp))
            Chip("All", !favoritesOnly) { favoritesOnly = false }
        }
        // Time header
        Row(Modifier.fillMaxWidth()) {
            Spacer(Modifier.width(channelWidth))
            Row(Modifier.horizontalScroll(scroll)) {
                repeat(hours * 2) { i ->
                    Text(timeText(windowStart + i * 1_800_000L), fontSize = 12.sp, color = Palette.secondary,
                        modifier = Modifier.width(minuteWidth * 30).padding(start = 6.dp))
                }
            }
        }
        LazyColumn(Modifier.fillMaxSize()) {
            items(channels, key = { it.id }) { ch -> GuideRow(ch, channels, windowStart, hours, minuteWidth, rowHeight, channelWidth, scroll) }
        }
    }
}

private fun roundedStart(): Long {
    val now = System.currentTimeMillis() - 30 * 60_000
    return now - now % 1_800_000L
}

@Composable
private fun GuideRow(ch: Channel, list: List<Channel>, windowStart: Long, hours: Int, minuteWidth: androidx.compose.ui.unit.Dp,
                     rowHeight: androidx.compose.ui.unit.Dp, channelWidth: androidx.compose.ui.unit.Dp, scroll: ScrollState) {
    val context = LocalContext.current
    var selected by remember { mutableStateOf<Boolean>(false) }
    LaunchedEffect(ch.id) { GuideRepo.ensure(ch) }
    val windowEnd = windowStart + hours * 3_600_000L
    val programmes = GuideRepo.forChannel(ch).filter { it.end > windowStart && it.start < windowEnd }
    Row(Modifier.fillMaxWidth().height(rowHeight).padding(vertical = 2.dp)) {
        Row(Modifier.width(channelWidth).fillMaxHeight().card({ Player.playChannel(context, ch, list) }).background(Palette.surfaceHigh).padding(6.dp),
            verticalAlignment = Alignment.CenterVertically) {
            ChannelLogo(ch.icon, ch.name, rowHeight * 0.6f)
            Spacer(Modifier.width(6.dp))
            Text(ch.name, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
        }
        Box(Modifier.horizontalScroll(scroll).width(minuteWidth * (hours * 60)).fillMaxHeight()) {
            if (programmes.isEmpty()) {
                Text("No guide data", fontSize = 12.sp, color = Palette.secondary, modifier = Modifier.padding(10.dp))
            }
            programmes.forEach { p ->
                val start = maxOf(p.start, windowStart)
                val end = minOf(p.end, windowEnd)
                val x = minuteWidth * ((start - windowStart) / 60_000f)
                val w = minuteWidth * ((end - start) / 60_000f)
                Column(
                    Modifier.offset(x = x).width(w - 3.dp).fillMaxHeight()
                        .card({ if (p.isLive) Player.playChannel(context, ch, list) else if (p.end < System.currentTimeMillis() && ch.hasArchive) Player.playCatchup(context, ch, p) else selected = !selected },
                            shape = RoundedCornerShape(8.dp))
                        .background(if (p.isLive) Palette.accent.copy(alpha = 0.35f) else Palette.surface)
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                ) {
                    Text(p.title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${timeText(p.start)} – ${timeText(p.end)}", fontSize = 10.sp, color = Palette.secondary, maxLines = 1)
                }
            }
        }
    }
}
