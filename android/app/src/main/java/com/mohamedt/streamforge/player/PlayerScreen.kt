package com.mohamedt.streamforge.player

import android.view.SurfaceView
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.onKeyEvent
import com.mohamedt.streamforge.ui.ButtonKind
import com.mohamedt.streamforge.ui.SfButton
import com.mohamedt.streamforge.ui.SfListRow
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
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
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.animation.core.animateFloat
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
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
    val playFocus = remember { FocusRequester() }
    val seekFocus = remember { FocusRequester() }
    val errorFocus = remember { FocusRequester() }
    var rootFocused by remember { mutableStateOf(false) }
    val step = Settings.values.seekStep * 1000L

    LaunchedEffect(interaction) { if (interaction > 0) { controls = true; lastTouch = System.currentTimeMillis() } }
    LaunchedEffect(lastTouch, c.paused, panel) {
        delay(4500)
        if (!c.paused && panel == null) controls = false
    }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    // TV: the root Box is itself focusable, so D-pad focus search can't descend into the controls on its own.
    // Move focus explicitly: play button when controls show, error buttons on error, root when hidden.
    val hasError = c.error != null
    LaunchedEffect(controls, panel, hasError) {
        if (!tv || panel != null) return@LaunchedEffect
        delay(60)
        runCatching {
            when {
                hasError -> errorFocus.requestFocus()
                // VOD: land on the seek bar, so left/right keep scrubbing; live: on play/pause.
                controls && !c.isLive && c.durationMs > 0 -> seekFocus.requestFocus()
                controls -> playFocus.requestFocus()
                else -> focus.requestFocus()
            }
        }
    }

    BackHandler(enabled = panel != null || (controls && tv && c.started)) {
        if (panel != null) panel = null else controls = false
    }

    Box(
        Modifier.fillMaxSize().background(Color.Black)
            .focusRequester(focus)
            .onPreviewKeyEvent { e ->
                if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                // Any remote key keeps the controls alive (also keys consumed by a focused button).
                lastTouch = System.currentTimeMillis()
                // Controls just appeared but focus hasn't reached the seek bar yet: keep seeking.
                val pending = controls && rootFocused && panel == null && c.error == null && !c.isLive
                if (pending && e.key == Key.DirectionLeft) { c.seekBy(-step); return@onPreviewKeyEvent true }
                if (pending && e.key == Key.DirectionRight) { c.seekBy(step); return@onPreviewKeyEvent true }
                if (panel != null || controls || c.error != null) return@onPreviewKeyEvent false
                when (e.key) {
                    // VOD: seek and bring up the bar (focus lands on it, so further presses keep seeking).
                    Key.DirectionLeft -> { if (c.isLive) c.lastChannel() else { c.seekBy(-step); controls = true }; true }
                    Key.DirectionRight -> { if (c.isLive) panel = Panel.CHANNELS else { c.seekBy(step); controls = true }; true }
                    Key.DirectionUp -> { if (c.isLive) c.zap(-1) else controls = true; true }
                    Key.DirectionDown -> { if (c.isLive) c.zap(1) else controls = true; true }
                    Key.DirectionCenter, Key.Enter -> { controls = true; true }
                    else -> false
                }
            }
            .onFocusChanged { rootFocused = it.isFocused }
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

        if (!c.started && !c.isLive && c.error == null) {
            LoadingArtwork(c)
        } else if ((c.buffering || !c.started) && c.error == null) {
            Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator(color = Color.White)
                c.status?.let { Spacer(Modifier.height(10.dp)); Text(it, color = Color.White.copy(alpha = 0.8f), fontSize = 13.sp) }
            }
        }

        c.error?.let { err ->
            Column(Modifier.align(Alignment.Center).widthIn(max = if (tv) 640.dp else 480.dp).clip(RoundedCornerShape(20.dp)).background(Color(0xE0101020))
                .padding(if (tv) 32.dp else 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Can't play this", fontSize = if (tv) 28.sp else 20.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(6.dp))
                Text(err, color = Palette.secondary, fontSize = if (tv) 18.sp else 14.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                if (tv) {
                    Spacer(Modifier.height(20.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        SfButton("Try again", { c.retry() }, kind = ButtonKind.PRIMARY, focusRequester = errorFocus)
                        if (c.isLive) SfButton("Next channel", { c.zap(1) })
                        SfButton("Close", onClose)
                    }
                } else {
                    Row {
                        TextButton(onClick = onClose) { Text("Close") }
                        TextButton(onClick = { c.retry() }, modifier = Modifier.focusRequester(errorFocus)) { Text("Try again") }
                        if (c.isLive) TextButton(onClick = { c.zap(1) }) { Text("Next channel") }
                    }
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
            Column(Modifier.align(Alignment.BottomEnd).padding(end = if (tv) 48.dp else 32.dp, bottom = if (controls) (if (tv) 190.dp else 120.dp) else 40.dp),
                horizontalAlignment = Alignment.End) {
                c.activeSegment?.let { s ->
                    Text(s.label, fontWeight = FontWeight.Bold, fontSize = if (tv) 18.sp else 14.sp,
                        modifier = Modifier.card({ c.skipSegment() }, shape = RoundedCornerShape(10.dp))
                        .background(Color.White.copy(alpha = 0.9f)).padding(horizontal = if (tv) 24.dp else 18.dp, vertical = if (tv) 14.dp else 10.dp), color = Color.Black)
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

            AnimatedVisibility(controls && c.error == null, enter = fadeIn(), exit = fadeOut()) {
                if (tv) TvControls(c, playFocus, seekFocus, onInteract = { lastTouch = System.currentTimeMillis() }) { panel = it }
                else Controls(c, onClose, onPip, playFocus) { panel = it }
            }

            panel?.let { p -> androidx.compose.runtime.key(p) { SidePanel(c, p) { panel = null } } }
        }
    }
}

@Composable
private fun Controls(c: PlayerController, onClose: () -> Unit, onPip: () -> Unit, playFocus: FocusRequester, openPanel: (Panel) -> Unit) {
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
            CtrlButton(if (c.paused) Icons.Filled.PlayArrow else Icons.Filled.Pause, "Play/Pause", { c.togglePause() }, 76.dp, Modifier.focusRequester(playFocus))
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

/**
 * 10-foot controls: big title top-left, a focusable seek bar (left/right skip, OK pauses) and a row
 * of large buttons. Focus starts on the seek bar for films and episodes, on play/pause for live TV.
 */
@Composable
private fun TvControls(c: PlayerController, playFocus: FocusRequester, seekFocus: FocusRequester, onInteract: () -> Unit, openPanel: (Panel) -> Unit) {
    val step = Settings.values.seekStep * 1000L
    val live = c.isLive
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(
        0f to Color.Black.copy(alpha = 0.8f), 0.28f to Color.Transparent, 0.55f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.92f)))) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 48.dp, vertical = 27.dp), verticalAlignment = Alignment.Top) {
            if (live) c.currentChannel?.let {
                ChannelLogo(it.icon, it.name, 64.dp)
                Spacer(Modifier.width(18.dp))
            }
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(c.title, fontSize = 30.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                    if (live) { Spacer(Modifier.width(12.dp)); LiveBadge() }
                }
                c.subtitle?.let { Text(it, fontSize = 19.sp, color = Color.White.copy(alpha = 0.8f), maxLines = 1, overflow = TextOverflow.Ellipsis) }
                if (live) c.nextProgramme?.let { Text("Next at ${timeText(it.start)}  ${it.title}", fontSize = 16.sp, color = Palette.secondary, maxLines = 1) }
            }
            Text(timeText(System.currentTimeMillis()), fontSize = 22.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.85f))
        }

        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(horizontal = 48.dp, vertical = 27.dp)) {
            if (live) {
                c.nowProgramme?.let { p ->
                    Text(p.title, fontSize = 19.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Spacer(Modifier.height(8.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(timeText(p.start), fontSize = 17.sp)
                        Box(Modifier.weight(1f).padding(horizontal = 14.dp)) { ProgressLine(p.progress, height = 6.dp) }
                        Text(timeText(p.end), fontSize = 17.sp)
                    }
                }
                if (c.behindLiveMs > 5_000) {
                    Spacer(Modifier.height(10.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("−${c.behindLiveMs.clockText()} behind live", fontSize = 17.sp, color = Palette.gold)
                        Spacer(Modifier.width(14.dp))
                        SfButton("Go live", { c.goLive() }, kind = ButtonKind.DANGER)
                    }
                }
            } else {
                TvSeekBar(c, step, seekFocus, onInteract)
            }
            Spacer(Modifier.height(18.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                SfButton(null, { c.togglePause() }, icon = if (c.paused) Icons.Filled.PlayArrow else Icons.Filled.Pause, kind = ButtonKind.PRIMARY,
                    focusRequester = playFocus, contentDescription = if (c.paused) "Play" else "Pause")
                if (live) {
                    SfButton(null, { c.zap(-1) }, icon = Icons.Filled.KeyboardArrowUp, contentDescription = "Previous channel")
                    SfButton(null, { c.zap(1) }, icon = Icons.Filled.KeyboardArrowDown, contentDescription = "Next channel")
                    SfButton("Channels", { openPanel(Panel.CHANNELS) }, icon = Icons.Filled.List)
                    SfButton("Last channel", { c.lastChannel() })
                } else {
                    SfButton(null, { c.seekBy(-step) }, icon = Icons.Filled.FastRewind, contentDescription = "Back ${step / 1000} seconds")
                    SfButton(null, { c.seekBy(step) }, icon = Icons.Filled.FastForward, contentDescription = "Forward ${step / 1000} seconds")
                    c.nextEpisode?.let { n -> SfButton("Next: ${n.code}", { c.playNextEpisode() }, icon = Icons.Filled.SkipNext) }
                }
                Spacer(Modifier.weight(1f))
                SfButton("Audio", { openPanel(Panel.AUDIO) }, icon = Icons.Filled.Audiotrack)
                SfButton("Subtitles", { openPanel(Panel.SUBTITLES) }, icon = Icons.Filled.Subtitles)
                SfButton(null, { openPanel(Panel.SETTINGS) }, icon = Icons.Filled.Tune, contentDescription = "Playback settings")
            }
        }
    }
}

/** Focusable progress bar: left/right skip by the configured interval (held keys repeat), OK pauses. */
@Composable
private fun TvSeekBar(c: PlayerController, step: Long, requester: FocusRequester, onInteract: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val total = c.durationMs.coerceAtLeast(1)
    val fraction = (c.positionMs.toFloat() / total).coerceIn(0f, 1f)
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(c.positionMs.clockText(), fontSize = 19.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(96.dp))
            Box(
                Modifier.weight(1f).height(32.dp)
                    .focusRequester(requester)
                    .onFocusChanged { focused = it.isFocused }
                    .onKeyEvent { e ->
                        if (e.type != KeyEventType.KeyDown) return@onKeyEvent false
                        when (e.key) {
                            Key.DirectionLeft -> { c.seekBy(-step); onInteract(); true }
                            Key.DirectionRight -> { c.seekBy(step); onInteract(); true }
                            Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> { c.togglePause(); onInteract(); true }
                            else -> false
                        }
                    }
                    .focusable(),
                contentAlignment = Alignment.CenterStart,
            ) {
                val h = if (focused) 10.dp else 6.dp
                Box(Modifier.fillMaxWidth().height(h).clip(CircleShape).background(Color.White.copy(alpha = 0.25f)))
                Box(Modifier.fillMaxWidth(fraction).height(h).clip(CircleShape).background(Palette.gradient))
                if (focused) {
                    Box(Modifier.fillMaxWidth(fraction), contentAlignment = Alignment.CenterEnd) {
                        Box(Modifier.size(22.dp).clip(CircleShape).background(Color.White))
                    }
                }
            }
            Text("-" + (c.durationMs - c.positionMs).coerceAtLeast(0).clockText(), fontSize = 19.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.width(110.dp).padding(start = 14.dp))
        }
        Text(if (focused) "◀ ▶ skip ${step / 1000} s   OK ${if (c.paused) "play" else "pause"}" else " ",
            fontSize = 15.sp, color = Palette.secondary, modifier = Modifier.padding(start = 96.dp, top = 4.dp))
    }
}

@Composable
private fun CtrlButton(icon: ImageVector, label: String, onClick: () -> Unit, size: androidx.compose.ui.unit.Dp = 44.dp, modifier: Modifier = Modifier) {
    Box(modifier.size(size).card(onClick, shape = CircleShape), contentAlignment = Alignment.Center) {
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
    val tv = isTv()
    val first = remember { FocusRequester() }
    val channels = c.request.channelList
    val focusChannelId = channels.firstOrNull { it.id == c.request.channelId }?.id ?: channels.firstOrNull()?.id
    val listState = rememberLazyListState(
        initialFirstVisibleItemIndex = if (panel == Panel.CHANNELS) channels.indexOfFirst { it.id == focusChannelId }.coerceAtLeast(0) else 0)
    // Give the remote something to focus inside the panel.
    LaunchedEffect(panel) { if (tv) { delay(60); runCatching { first.requestFocus() } } }
    // Tap outside closes; not a focus target, so the D-pad stays inside the list.
    Box(Modifier.fillMaxSize().pointerInput(Unit) { detectTapGestures { onClose() } }) {
        Column(Modifier.align(Alignment.CenterEnd).fillMaxHeight().width(if (tv) 460.dp else 340.dp).background(Color(0xF015131F))
            .padding(horizontal = if (tv) 28.dp else 16.dp, vertical = if (tv) 27.dp else 16.dp)
            .pointerInput(Unit) { detectTapGestures { } }) {
            Text(when (panel) { Panel.AUDIO -> "Audio"; Panel.SUBTITLES -> "Subtitles"; Panel.CHANNELS -> "Channels"; Panel.SETTINGS -> "Playback" },
                fontSize = if (tv) 26.sp else 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(10.dp))
            LazyColumn(state = listState) {
                when (panel) {
                    Panel.AUDIO -> itemsIndexed(c.audioTracks) { i, t ->
                        Option(t.label, t.selected, if (i == 0) Modifier.focusRequester(first) else Modifier) { c.selectAudio(t) }
                    }
                    Panel.SUBTITLES -> {
                        item { Option("Off", c.subtitleTracks.none { it.selected }, Modifier.focusRequester(first)) { c.selectSubtitle(null) } }
                        items(c.subtitleTracks) { t -> Option(t.label, t.selected) { c.selectSubtitle(t) } }
                        if (c.addonSubtitles.isNotEmpty()) item { Text("From addons", fontSize = if (tv) 16.sp else 11.sp, color = Palette.secondary, modifier = Modifier.padding(top = 12.dp)) }
                        items(c.addonSubtitles.take(60)) { s ->
                            Option(java.util.Locale.forLanguageTag(s.lang).displayLanguage.ifEmpty { s.lang }, false) { c.loadAddonSubtitle(s) }
                        }
                        item {
                            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 12.dp)) {
                                Text("Delay %+.2fs".format(c.subtitleDelay), Modifier.weight(1f), fontSize = if (tv) 18.sp else 14.sp)
                                TextChip("−0.25") { c.changeSubtitleDelay(-0.25) }
                                Spacer(Modifier.width(6.dp))
                                TextChip("+0.25") { c.changeSubtitleDelay(0.25) }
                            }
                        }
                    }
                    Panel.CHANNELS -> items(channels.distinctBy { it.id }, key = { it.id }) { ch ->
                        val now = GuideRepo.now(ch)
                        Row(Modifier.fillMaxWidth().card({ c.switchChannel(ch); onClose() }, focusScale = if (tv) 1.02f else null, glow = false,
                            focusRequester = if (ch.id == focusChannelId) first else null)
                            .background(if (ch.id == c.request.channelId) Color.White.copy(alpha = 0.1f) else Color.Transparent)
                            .padding(if (tv) 10.dp else 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            ch.number?.let { Text("$it", fontSize = if (tv) 16.sp else 12.sp, color = Palette.secondary, modifier = Modifier.width(if (tv) 46.dp else 36.dp)) }
                            ChannelLogo(ch.icon, ch.name, if (tv) 44.dp else 34.dp)
                            Spacer(Modifier.width(if (tv) 12.dp else 8.dp))
                            Column {
                                Text(ch.name, fontSize = if (tv) 18.sp else 14.sp, fontWeight = if (ch.id == c.request.channelId) FontWeight.Bold else FontWeight.Normal, maxLines = 1)
                                now?.let { Text(it.title, fontSize = if (tv) 15.sp else 12.sp, color = Palette.secondary, maxLines = 1) }
                            }
                        }
                    }
                    Panel.SETTINGS -> {
                        item { Option("Night mode", c.nightMode, Modifier.focusRequester(first)) { c.toggleNightMode() } }
                        item { Option("Volume +25%", false) { c.changeVolume(25) } }
                        item { Option("Volume −25%", false) { c.changeVolume(-25) } }
                        if (c.request.episode != null) {
                            item { Option("Mark intro start here", false) { c.markIntro(true) } }
                            item { Option("Mark intro end here", false) { c.markIntro(false) } }
                        }
                        c.chapters.takeIf { it.size > 1 }?.let { chs ->
                            item { Text("Chapters", fontSize = if (tv) 16.sp else 11.sp, color = Palette.secondary, modifier = Modifier.padding(top = 12.dp)) }
                            items(chs) { ch -> Option("${ch.title} · ${(ch.time * 1000).toLong().clockText()}", false) { c.seekTo((ch.time * 1000).toLong()) } }
                        }
                        item { Text("Source: ${c.request.source.provider}", fontSize = if (tv) 15.sp else 12.sp, color = Palette.secondary, modifier = Modifier.padding(top = 12.dp)) }
                    }
                }
            }
        }
    }
}

@Composable
private fun Option(text: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    SfListRow(text, onClick, modifier, selected = selected)
}

@Suppress("unused")
private val listIcon = Icons.Filled.List


/** Stremio-style start screen: the artwork drifts and zooms slowly behind the title while the stream connects. */
@Composable
private fun LoadingArtwork(c: PlayerController) {
    val r = c.request
    // Clock-driven Ken Burns (continuous zoom + slow pan, 40 s loop) and a breathing logo, like Stremio.
    val t = androidx.compose.animation.core.rememberInfiniteTransition(label = "loading")
    val clock by t.animateFloat(0f, 1f, androidx.compose.animation.core.infiniteRepeatable(
        androidx.compose.animation.core.tween(40_000, easing = androidx.compose.animation.core.LinearEasing),
        androidx.compose.animation.core.RepeatMode.Restart), label = "clock")
    val breathRaw by t.animateFloat(0f, 1f, androidx.compose.animation.core.infiniteRepeatable(
        androidx.compose.animation.core.tween(1200, easing = androidx.compose.animation.core.FastOutSlowInEasing),
        androidx.compose.animation.core.RepeatMode.Reverse), label = "breath")
    val pulse = 0.55f + 0.45f * breathRaw
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        com.mohamedt.streamforge.ui.Artwork(
            r.episode?.still ?: r.item.backdrop ?: r.item.poster,
            Modifier.fillMaxSize().graphicsLayer {
                val a = clock * 2f * Math.PI.toFloat()
                val phase = (1f - kotlin.math.cos(a)) / 2f
                val s = 1.12f + 0.22f * phase
                scaleX = s; scaleY = s
                translationX = size.width * 0.07f * kotlin.math.sin(a)
                translationY = size.height * 0.04f * kotlin.math.sin(a * 2f)
                alpha = 0.6f
            },
        )
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.2f), Color.Black.copy(alpha = 0.45f), Color.Black.copy(alpha = 0.9f)))))
        Column(Modifier.align(Alignment.Center).padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            if (r.item.logo != null) {
                com.mohamedt.streamforge.ui.Artwork(r.item.logo, Modifier.width(360.dp).height(130.dp).graphicsLayer { alpha = pulse; scaleX = 0.95f + 0.07f * breathRaw; scaleY = scaleX },
                    androidx.compose.ui.layout.ContentScale.Fit)
            } else {
                Text(r.item.title, fontSize = 34.sp, fontWeight = FontWeight.Black, maxLines = 3,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.graphicsLayer { alpha = pulse; scaleX = 0.95f + 0.07f * breathRaw; scaleY = scaleX })
            }
            r.episode?.let { Spacer(Modifier.height(8.dp)); Text("${it.code} · ${it.title}", color = Color.White.copy(alpha = 0.8f), fontWeight = FontWeight.SemiBold) }
        }
        Row(Modifier.align(Alignment.BottomCenter).padding(bottom = 48.dp), verticalAlignment = Alignment.CenterVertically) {
            CircularProgressIndicator(color = Color.White, modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(10.dp))
            Text(c.status ?: "Starting…", color = Color.White.copy(alpha = 0.8f), fontSize = 13.sp)
        }
    }
}
