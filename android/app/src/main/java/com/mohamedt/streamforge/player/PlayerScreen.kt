package com.mohamedt.streamforge.player

import android.view.SurfaceView
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Audiotrack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.NightsStay
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.Subtitles
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.mohamedt.streamforge.core.Settings
import com.mohamedt.streamforge.core.clockText
import com.mohamedt.streamforge.dispatcharr.GuideRepo
import com.mohamedt.streamforge.ui.ChannelLogo
import com.mohamedt.streamforge.ui.LiveBadge
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.ProgressLine
import com.mohamedt.streamforge.ui.card
import com.mohamedt.streamforge.ui.isTv
import com.mohamedt.streamforge.ui.screens.timeText
import kotlinx.coroutines.delay

private enum class Panel { AUDIO, SUBTITLES, CHANNELS, SETTINGS }

@Composable
fun PlayerScreen(c: PlayerController, surface: SurfaceView, inPip: Boolean, interaction: Long, onClose: () -> Unit, onPip: () -> Unit) {
    var controls by remember { mutableStateOf(true) }
    var panel by remember { mutableStateOf<Panel?>(null) }
    var lastTouch by remember { mutableStateOf(System.currentTimeMillis()) }
    val tv = isTv()
    val focus = remember { FocusRequester() }
    val step = Settings.values.seekStep * 1000L

    LaunchedEffect(interaction) { if (interaction > 0) { controls = true; lastTouch = System.currentTimeMillis() } }
    LaunchedEffect(lastTouch, c.paused, panel) {
        delay(4500)
        if (!c.paused && panel == null) controls = false
    }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }

    BackHandler(enabled = panel != null || (controls && tv && c.started)) {
        if (panel != null) panel = null else controls = false
    }

    Box(
        Modifier.fillMaxSize().background(Color.Black)
            .focusRequester(focus)
            .onKeyEvent { e ->
                if (e.type != KeyEventType.KeyDown || panel != null) return@onKeyEvent false
                lastTouch = System.currentTimeMillis()
                if (controls) return@onKeyEvent false
                when (e.key) {
                    Key.DirectionLeft -> { if (c.isLive) c.lastChannel() else c.seekBy(-step); true }
                    Key.DirectionRight -> { if (c.isLive) panel = Panel.CHANNELS else c.seekBy(step); true }
                    Key.DirectionUp -> { if (c.isLive) c.zap(-1) else controls = true; true }
                    Key.DirectionDown -> { if (c.isLive) c.zap(1) else controls = true; true }
                    Key.DirectionCenter, Key.Enter -> { controls = true; true }
                    else -> false
                }
            }
            .focusable(),
    ) {
        AndroidView(factory = { surface }, modifier = Modifier.fillMaxSize())

        if (!inPip) {
            Box(Modifier.fillMaxSize().pointerInput(Unit) {
                detectTapGestures(
                    onTap = { controls = !controls; lastTouch = System.currentTimeMillis() },
                    onDoubleTap = { o ->
                        if (o.x < size.width / 3f) c.seekBy(-step) else if (o.x > size.width * 2 / 3f) c.seekBy(step) else c.togglePause()
                    },
                )
            })
        }

        if ((c.buffering || !c.started) && c.error == null) {
            Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator(color = Color.White)
                c.status?.let { Spacer(Modifier.height(10.dp)); Text(it, color = Color.White.copy(alpha = 0.8f), fontSize = 13.sp) }
            }
        }

        c.error?.let { err ->
            Column(Modifier.align(Alignment.Center).clip(RoundedCornerShape(20.dp)).background(Color(0xE0101020)).padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Can't play this", fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Text(err, color = Palette.secondary)
                Row {
                    TextButton(onClick = onClose) { Text("Close") }
                    TextButton(onClick = { c.retry() }) { Text("Try again") }
                    if (c.isLive) TextButton(onClick = { c.zap(1) }) { Text("Next channel") }
                }
            }
        }

        if (c.numberEntry.isNotEmpty()) {
            Text(c.numberEntry, fontSize = 48.sp, fontWeight = FontWeight.Black, modifier = Modifier.align(Alignment.TopEnd).padding(32.dp)
                .clip(RoundedCornerShape(12.dp)).background(Color.Black.copy(alpha = 0.6f)).padding(horizontal = 18.dp, vertical = 6.dp))
        }

        c.toast?.let {
            Text(it, modifier = Modifier.align(Alignment.Center).clip(CircleShape).background(Color.Black.copy(alpha = 0.7f)).padding(horizontal = 18.dp, vertical = 10.dp),
                fontWeight = FontWeight.Bold)
        }

        if (!inPip) {
            // Skip intro / next episode buttons stay visible without the controls.
            Column(Modifier.align(Alignment.BottomEnd).padding(end = 32.dp, bottom = if (controls) 120.dp else 40.dp), horizontalAlignment = Alignment.End) {
                c.activeSegment?.let { s ->
                    Text(s.label, fontWeight = FontWeight.Bold, modifier = Modifier.card({ c.skipSegment() }, shape = RoundedCornerShape(10.dp))
                        .background(Color.White.copy(alpha = 0.9f)).padding(horizontal = 18.dp, vertical = 10.dp), color = Color.Black)
                }
                if (c.showNextCard) c.nextEpisode?.let { n ->
                    Spacer(Modifier.height(8.dp))
                    Row(Modifier.card({ c.playNextEpisode() }, shape = RoundedCornerShape(12.dp)).background(Color.Black.copy(alpha = 0.8f)).padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.SkipNext, null)
                        Spacer(Modifier.width(8.dp))
                        Column {
                            Text("Up next in ${(c.durationMs - c.positionMs) / 1000}s", fontSize = 11.sp, color = Palette.secondary)
                            Text("${n.code} · ${n.title}", fontWeight = FontWeight.SemiBold, maxLines = 1)
                        }
                    }
                }
            }

            AnimatedVisibility(controls && c.error == null, enter = fadeIn(), exit = fadeOut()) { Controls(c, onClose, onPip) { panel = it } }

            panel?.let { p -> SidePanel(c, p) { panel = null } }
        }
    }
}

@Composable
private fun Controls(c: PlayerController, onClose: () -> Unit, onPip: () -> Unit, openPanel: (Panel) -> Unit) {
    val tv = isTv()
    val step = Settings.values.seekStep * 1000L
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.75f), Color.Transparent, Color.Transparent, Color.Black.copy(alpha = 0.85f))))) {
        Row(Modifier.fillMaxWidth().padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
            if (!tv) CtrlButton(Icons.Filled.Close, "Close", onClose)
            if (c.isLive) c.currentChannel?.let { ChannelLogo(it.icon, it.name, 44.dp); Spacer(Modifier.width(10.dp)) }
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(c.title, fontSize = 18.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    if (c.isLive) { Spacer(Modifier.width(8.dp)); LiveBadge() }
                }
                c.subtitle?.let { Text(it, color = Color.White.copy(alpha = 0.75f), maxLines = 1) }
                if (c.isLive) c.nextProgramme?.let { Text("Next · ${timeText(it.start)} ${it.title}", fontSize = 12.sp, color = Palette.secondary, maxLines = 1) }
            }
            if (!tv) CtrlButton(Icons.Filled.PictureInPictureAlt, "Picture in picture", onPip)
        }

        Row(Modifier.align(Alignment.Center), horizontalArrangement = Arrangement.spacedBy(48.dp), verticalAlignment = Alignment.CenterVertically) {
            if (c.isLive) CtrlButton(Icons.Filled.KeyboardArrowUp, "Previous channel", { c.zap(-1) }, 56.dp)
            else CtrlButton(Icons.Filled.FastRewind, "Back", { c.seekBy(-step) }, 56.dp)
            CtrlButton(if (c.paused) Icons.Filled.PlayArrow else Icons.Filled.Pause, "Play/Pause", { c.togglePause() }, 76.dp)
            if (c.isLive) CtrlButton(Icons.Filled.KeyboardArrowDown, "Next channel", { c.zap(1) }, 56.dp)
            else CtrlButton(Icons.Filled.FastForward, "Forward", { c.seekBy(step) }, 56.dp)
        }

        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(20.dp)) {
            if (c.isLive) {
                val p = c.nowProgramme
                if (p != null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(timeText(p.start), fontSize = 12.sp)
                        Box(Modifier.weight(1f).padding(horizontal = 10.dp)) { ProgressLine(p.progress, height = 4.dp) }
                        Text(timeText(p.end), fontSize = 12.sp)
                    }
                }
                if (c.behindLiveMs > 5_000) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 6.dp)) {
                        Text("−${c.behindLiveMs.clockText()} behind live", fontSize = 12.sp, color = Palette.gold)
                        Spacer(Modifier.width(10.dp))
                        Text("GO LIVE", fontWeight = FontWeight.Bold, color = Palette.live, modifier = Modifier.card({ c.goLive() }).padding(6.dp))
                    }
                }
            } else {
                var scrub by remember { mutableStateOf<Float?>(null) }
                val total = c.durationMs.coerceAtLeast(1).toFloat()
                Slider(
                    value = scrub ?: (c.positionMs / total).coerceIn(0f, 1f),
                    onValueChange = { scrub = it },
                    onValueChangeFinished = { scrub?.let { c.seekTo((it * total).toLong()) }; scrub = null },
                    colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Palette.accent),
                )
                Row {
                    Text(((scrub?.let { (it * total).toLong() }) ?: c.positionMs).clockText(), fontSize = 12.sp)
                    Spacer(Modifier.weight(1f))
                    Text("-" + (c.durationMs - c.positionMs).coerceAtLeast(0).clockText(), fontSize = 12.sp)
                }
            }
            Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                if (c.isLive) TextChip("Channels") { openPanel(Panel.CHANNELS) }
                if (c.isLive) TextChip("Last channel") { c.lastChannel() }
                TextChipIcon(Icons.Filled.Audiotrack, "Audio") { openPanel(Panel.AUDIO) }
                TextChipIcon(Icons.Filled.Subtitles, "Subtitles") { openPanel(Panel.SUBTITLES) }
                TextChipIcon(Icons.Filled.NightsStay, if (c.nightMode) "Night ✓" else "Night") { c.toggleNightMode() }
                Spacer(Modifier.weight(1f))
                TextChip("Vol ${c.volume}%") { c.changeVolume(if (c.volume >= 200) -100 else 25) }
                TextChipIcon(Icons.Filled.Tune, "More") { openPanel(Panel.SETTINGS) }
            }
        }
    }
}

@Composable
private fun CtrlButton(icon: ImageVector, label: String, onClick: () -> Unit, size: androidx.compose.ui.unit.Dp = 44.dp) {
    Box(Modifier.size(size).card(onClick, shape = CircleShape), contentAlignment = Alignment.Center) {
        Icon(icon, label, Modifier.size(size * 0.6f), tint = Color.White)
    }
}

@Composable
private fun TextChip(text: String, onClick: () -> Unit) {
    Text(text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
        modifier = Modifier.card(onClick, shape = RoundedCornerShape(16.dp)).background(Color.White.copy(alpha = 0.12f)).padding(horizontal = 12.dp, vertical = 7.dp))
}

@Composable
private fun TextChipIcon(icon: ImageVector, text: String, onClick: () -> Unit) {
    Row(Modifier.card(onClick, shape = RoundedCornerShape(16.dp)).background(Color.White.copy(alpha = 0.12f)).padding(horizontal = 12.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun SidePanel(c: PlayerController, panel: Panel, onClose: () -> Unit) {
    Box(Modifier.fillMaxSize().clickable(onClick = onClose)) {
        Column(Modifier.align(Alignment.CenterEnd).fillMaxHeight().width(if (isTv()) 460.dp else 340.dp).background(Color(0xF0121026)).padding(16.dp)
            .clickable(enabled = false) {}) {
            Text(when (panel) { Panel.AUDIO -> "Audio"; Panel.SUBTITLES -> "Subtitles"; Panel.CHANNELS -> "Channels"; Panel.SETTINGS -> "Playback" },
                fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(10.dp))
            LazyColumn {
                when (panel) {
                    Panel.AUDIO -> items(c.audioTracks) { t -> Option(t.label, t.selected) { c.selectAudio(t) } }
                    Panel.SUBTITLES -> {
                        item { Option("Off", c.subtitleTracks.none { it.selected }) { c.selectSubtitle(null) } }
                        items(c.subtitleTracks) { t -> Option(t.label, t.selected) { c.selectSubtitle(t) } }
                        if (c.addonSubtitles.isNotEmpty()) item { Text("FROM ADDONS", fontSize = 11.sp, color = Palette.secondary, modifier = Modifier.padding(top = 12.dp)) }
                        items(c.addonSubtitles.take(60)) { s ->
                            Option(java.util.Locale.forLanguageTag(s.lang).displayLanguage.ifEmpty { s.lang }, false) { c.loadAddonSubtitle(s) }
                        }
                        item {
                            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 12.dp)) {
                                Text("Delay %+.2fs".format(c.subtitleDelay), Modifier.weight(1f))
                                TextChip("−0.25") { c.changeSubtitleDelay(-0.25) }
                                Spacer(Modifier.width(6.dp))
                                TextChip("+0.25") { c.changeSubtitleDelay(0.25) }
                            }
                        }
                    }
                    Panel.CHANNELS -> items(c.request.channelList, key = { it.id }) { ch ->
                        val now = GuideRepo.now(ch)
                        Row(Modifier.fillMaxWidth().card({ c.switchChannel(ch); onClose() }).padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            ch.number?.let { Text("$it", fontSize = 12.sp, color = Palette.secondary, modifier = Modifier.width(36.dp)) }
                            ChannelLogo(ch.icon, ch.name, 34.dp)
                            Spacer(Modifier.width(8.dp))
                            Column {
                                Text(ch.name, fontWeight = if (ch.id == c.request.channelId) FontWeight.Bold else FontWeight.Normal, maxLines = 1)
                                now?.let { Text(it.title, fontSize = 12.sp, color = Palette.secondary, maxLines = 1) }
                            }
                        }
                    }
                    Panel.SETTINGS -> {
                        item { Option("Night mode", c.nightMode) { c.toggleNightMode() } }
                        item { Option("Volume +25%", false) { c.changeVolume(25) } }
                        item { Option("Volume −25%", false) { c.changeVolume(-25) } }
                        if (c.request.episode != null) {
                            item { Option("Mark intro start here", false) { c.markIntro(true) } }
                            item { Option("Mark intro end here", false) { c.markIntro(false) } }
                        }
                        c.mpv.chapters().takeIf { it.size > 1 }?.let { chs ->
                            item { Text("CHAPTERS", fontSize = 11.sp, color = Palette.secondary, modifier = Modifier.padding(top = 12.dp)) }
                            items(chs) { ch -> Option("${ch.title} · ${(ch.time * 1000).toLong().clockText()}", false) { c.seekTo((ch.time * 1000).toLong()) } }
                        }
                        item { Text("Source: ${c.request.source.provider}", fontSize = 12.sp, color = Palette.secondary, modifier = Modifier.padding(top = 12.dp)) }
                    }
                }
            }
        }
    }
}

@Composable
private fun Option(text: String, selected: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().card(onClick, shape = RoundedCornerShape(10.dp)).background(if (selected) Color.White.copy(alpha = 0.12f) else Color.Transparent)
        .padding(horizontal = 10.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(text, Modifier.weight(1f), fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal)
        if (selected) Text("✓", color = Palette.accent)
    }
}

@Suppress("unused")
private val listIcon = Icons.Filled.List
