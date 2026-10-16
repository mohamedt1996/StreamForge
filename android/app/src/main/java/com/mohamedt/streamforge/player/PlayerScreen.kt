package com.mohamedt.streamforge.player

import android.view.SurfaceView
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Audiotrack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
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
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.mohamedt.streamforge.core.Settings
import com.mohamedt.streamforge.core.clockText
import com.mohamedt.streamforge.dispatcharr.GuideRepo
import com.mohamedt.streamforge.ui.ButtonKind
import com.mohamedt.streamforge.ui.ChannelLogo
import com.mohamedt.streamforge.ui.LiveBadge
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.ProgressLine
import com.mohamedt.streamforge.ui.SfButton
import com.mohamedt.streamforge.ui.SfListRow
import com.mohamedt.streamforge.ui.card
import com.mohamedt.streamforge.ui.isTv
import com.mohamedt.streamforge.ui.screens.timeText
import kotlin.math.abs
import kotlinx.coroutines.delay

private enum class Panel { AUDIO, SUBTITLES, CHANNELS, SETTINGS }

/** Feedback for seeks made with the controls hidden: accumulated offset, shown left or right. */
private data class SeekFlash(val totalMs: Long, val stamp: Long)

/** Remote keys that move focus or activate. */
private val NavKeys = setOf(Key.DirectionLeft, Key.DirectionRight, Key.DirectionUp, Key.DirectionDown, Key.DirectionCenter, Key.Enter, Key.NumPadEnter)

/**
 * Player overlay.
 *
 * TV (remote), same model as the Apple TV app:
 *  - controls hidden: OK shows them (focus on play/pause); Left/Right skip back/forward with a
 *    bubble (hold to keep skipping); Up shows the controls (live: previous channel); Down shows
 *    them (live: channel list). A visible "Skip intro" / "Up next" takes focus, so OK presses it.
 *  - controls shown: the D-pad only moves focus between the buttons and the seek bar; OK presses
 *    the focused one. Left/Right scrub only while the seek bar itself is focused.
 *  - side panels take focus, keep it, and give it back to the button that opened them.
 *  - Back: closes a panel, else hides the controls, else leaves the player.
 *  No touch gestures are active on TV.
 * Touch: tap toggles the controls, double-tap on the sides skips, in the middle pauses.
 */
@Composable
fun PlayerScreen(c: PlayerController, surface: SurfaceView, inPip: Boolean, interaction: Long, onClose: () -> Unit, onPip: () -> Unit) {
    val tv = isTv()
    var controls by remember { mutableStateOf(true) }
    var panel by remember { mutableStateOf<Panel?>(null) }
    // The panel being drawn: stays set while the panel slides out after closing.
    var shownPanel by remember { mutableStateOf(Panel.AUDIO) }
    var panelOrigin by remember { mutableStateOf<FocusRequester?>(null) }
    var returnFocus by remember { mutableStateOf<FocusRequester?>(null) }
    var lastTouch by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var flash by remember { mutableStateOf<SeekFlash?>(null) }
    var heldSeek by remember { mutableLongStateOf(0L) }
    var zapStamp by remember { mutableLongStateOf(0L) }
    var hasFocusInside by remember { mutableStateOf(false) }
    var rootFocused by remember { mutableStateOf(false) }
    val rootFocus = remember { FocusRequester() }
    val playFocus = remember { FocusRequester() }
    val seekFocus = remember { FocusRequester() }
    val errorFocus = remember { FocusRequester() }
    val skipFocus = remember { FocusRequester() }
    val nextFocus = remember { FocusRequester() }
    val step = Settings.values.seekStep * 1000L
    val hasError = c.error != null
    val skipShown = c.activeSegment != null
    val nextShown = c.showNextCard && c.nextEpisode != null
    // Live without a rewind buffer can't skip; the arrows then just bring up the controls.
    val canSkipHidden = !c.isLive || Settings.values.timeshiftMinutes > 0

    val openPanel: (Panel, FocusRequester?) -> Unit = { p, origin ->
        panelOrigin = origin
        shownPanel = p
        panel = p
        // TV: the controls step aside so focus can't wander from the panel to buttons behind it.
        if (tv) controls = false
    }
    val closePanel: () -> Unit = {
        val origin = panelOrigin
        panelOrigin = null
        panel = null
        lastTouch = System.currentTimeMillis()
        if (tv && origin != null) {
            returnFocus = origin
            controls = true
        }
    }

    LaunchedEffect(interaction) {
        if (interaction <= 0) return@LaunchedEffect
        lastTouch = System.currentTimeMillis()
        if (panel == null) controls = true
        // A key reached the activity because nothing in the overlay had focus: put it back.
        if (tv && !hasFocusInside && panel == null) {
            delay(80)
            runCatching { (if (hasError) errorFocus else playFocus).requestFocus() }
        }
    }
    LaunchedEffect(lastTouch, c.paused, panel) {
        delay(4500)
        if (!c.paused && panel == null) controls = false
    }
    LaunchedEffect(flash) {
        if (flash != null) {
            delay(1100)
            flash = null
        }
    }
    LaunchedEffect(zapStamp) {
        if (zapStamp > 0) {
            delay(2600)
            zapStamp = 0
        }
    }

    // Focus placement. While the controls are up it doesn't follow the skip/next cards, so it never jumps under the user.
    val hiddenTarget = when {
        controls -> -1
        skipShown -> 1
        nextShown -> 2
        else -> 0
    }
    LaunchedEffect(tv, controls, panel, hasError, hiddenTarget) {
        if (!tv) {
            // Touch: the root takes focus so keyboard/remote keys still arrive.
            runCatching { rootFocus.requestFocus() }
            return@LaunchedEffect
        }
        if (panel != null) return@LaunchedEffect
        delay(50)
        val target = when {
            hasError -> errorFocus
            controls -> returnFocus ?: playFocus
            hiddenTarget == 1 -> skipFocus
            hiddenTarget == 2 -> nextFocus
            else -> rootFocus
        }
        returnFocus = null
        // The target may still be composing (controls fading in): retry briefly.
        repeat(6) {
            if (runCatching { target.requestFocus() }.isSuccess) return@LaunchedEffect
            delay(60)
        }
    }

    BackHandler(enabled = panel != null || (tv && controls && c.started && !hasError)) {
        if (panel != null) closePanel() else controls = false
    }

    fun handleTvKey(e: KeyEvent): Boolean {
        val down = e.type == KeyEventType.KeyDown
        val repeat = e.nativeKeyEvent.repeatCount
        if (down) lastTouch = System.currentTimeMillis()
        if (panel != null || hasError) return false
        if (controls) {
            // Focus parked on the root while the controls show: bring it onto them instead of acting.
            if (rootFocused && e.key in NavKeys) {
                if (down) runCatching { playFocus.requestFocus() }
                return true
            }
            return false
        }
        when (e.key) {
            Key.DirectionLeft, Key.DirectionRight -> {
                if (!canSkipHidden) {
                    if (down && repeat == 0) controls = true
                    return true
                }
                // Nothing to skip in yet (still connecting).
                if (!c.started) return true
                val sign = if (e.key == Key.DirectionLeft) -1L else 1L
                val now = System.currentTimeMillis()
                val previous = flash?.totalMs?.takeIf { (it > 0) == (sign > 0) } ?: 0L
                if (down && repeat == 0) {
                    c.seekBy(sign * step)
                    flash = SeekFlash(previous + sign * step, now)
                } else if (down) {
                    // Held: skip faster, applied once on release so the player doesn't seek on every repeat.
                    val mult = when { repeat > 40 -> 6L; repeat > 15 -> 3L; else -> 1L }
                    heldSeek += sign * step * mult
                    flash = SeekFlash(previous + sign * step * mult, now)
                } else if (e.type == KeyEventType.KeyUp && heldSeek != 0L) {
                    c.seekBy(heldSeek)
                    heldSeek = 0L
                    flash = flash?.copy(stamp = now)
                }
                return true
            }
            Key.DirectionUp -> {
                if (down && repeat == 0) {
                    if (c.isLive && c.request.channelList.size > 1) {
                        c.zap(-1)
                        zapStamp = System.currentTimeMillis()
                    } else {
                        controls = true
                    }
                }
                return true
            }
            Key.DirectionDown -> {
                if (down && repeat == 0) {
                    if (c.isLive && c.request.channelList.size > 1) openPanel(Panel.CHANNELS, null) else controls = true
                }
                return true
            }
            Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> {
                // A focused "Skip intro" / "Up next" card handles OK itself.
                if (!rootFocused) return false
                if (down && repeat == 0) controls = true
                return true
            }
            else -> return false
        }
    }

    Box(
        Modifier.fillMaxSize().background(Color.Black)
            .onPreviewKeyEvent { e -> tv && handleTvKey(e) }
            .onFocusChanged { s ->
                hasFocusInside = s.hasFocus
                rootFocused = s.isFocused
            }
            .focusRequester(rootFocus)
            // TV: the root only holds focus while nothing else should (like the Apple TV app), so the
            // D-pad never has to "find its way" from the root into the controls.
            .focusable(enabled = !tv || (!controls && panel == null && !hasError)),
    ) {
        AndroidView(factory = { surface }, modifier = Modifier.fillMaxSize())

        if (!inPip && !tv) {
            Box(Modifier.fillMaxSize().pointerInput(Unit) {
                detectTapGestures(
                    onTap = {
                        if (panel != null) closePanel() else controls = !controls
                        lastTouch = System.currentTimeMillis()
                    },
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
                c.status?.let { Spacer(Modifier.height(10.dp)); Text(it, color = Color.White.copy(alpha = 0.8f), fontSize = if (tv) 17.sp else 13.sp) }
            }
        }

        c.error?.let { err ->
            Column(Modifier.align(Alignment.Center).padding(24.dp).widthIn(max = if (tv) 640.dp else 480.dp).clip(RoundedCornerShape(20.dp)).background(Color(0xE0101020))
                .padding(if (tv) 32.dp else 24.dp),
                horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Can't play this", fontSize = if (tv) 28.sp else 20.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(6.dp))
                Text(err, color = Palette.secondary, fontSize = if (tv) 18.sp else 14.sp, textAlign = TextAlign.Center)
                if (tv) {
                    Spacer(Modifier.height(20.dp))
                    Row(Modifier.focusGroup(), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
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
                fontWeight = FontWeight.Bold, fontSize = if (tv) 19.sp else 14.sp)
        }

        if (!inPip) {
            // Hidden-controls feedback (TV): skip bubble and the channel banner after Up.
            flash?.let { f -> if (!controls) SeekFlashView(f, c, heldSeek) }
            if (zapStamp > 0 && !controls && panel == null) ZapBanner(c, Modifier.align(Alignment.TopStart))

            // Skip intro / next episode stay visible without the controls (not behind a TV side panel).
            if (!(tv && panel != null)) {
                Column(Modifier.align(Alignment.BottomEnd).padding(end = if (tv) 48.dp else 32.dp, bottom = if (controls) (if (tv) 200.dp else 130.dp) else 40.dp),
                    horizontalAlignment = Alignment.End) {
                    c.activeSegment?.let { s ->
                        var focused by remember { mutableStateOf(false) }
                        Text(s.label, fontWeight = FontWeight.Bold, fontSize = if (tv) 19.sp else 14.sp,
                            modifier = Modifier.card({ c.skipSegment() }, shape = RoundedCornerShape(10.dp), focusRequester = skipFocus, onFocus = { focused = it })
                                .background(Color.White.copy(alpha = if (focused || !tv) 0.95f else 0.7f))
                                .padding(horizontal = if (tv) 26.dp else 18.dp, vertical = if (tv) 14.dp else 10.dp), color = Color.Black)
                    }
                    if (c.showNextCard) c.nextEpisode?.let { n ->
                        Spacer(Modifier.height(8.dp))
                        Row(Modifier.card({ c.playNextEpisode() }, shape = RoundedCornerShape(12.dp), focusRequester = nextFocus)
                            .background(Color.Black.copy(alpha = 0.8f)).padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.SkipNext, null)
                            Spacer(Modifier.width(8.dp))
                            Column {
                                Text("Up next in ${(c.durationMs - c.positionMs) / 1000}s", fontSize = if (tv) 14.sp else 11.sp, color = Palette.secondary)
                                Text("${n.code} · ${n.title}", fontWeight = FontWeight.SemiBold, maxLines = 1, fontSize = if (tv) 18.sp else 14.sp)
                            }
                        }
                    }
                }
            }

            AnimatedVisibility(controls && c.error == null, enter = fadeIn(tween(180)), exit = fadeOut(tween(if (tv) 140 else 220))) {
                if (tv) {
                    TvControls(c, playFocus, seekFocus, onInteract = { lastTouch = System.currentTimeMillis() }, openPanel = openPanel)
                } else {
                    Controls(c, onClose, onPip, playFocus) { openPanel(it, null) }
                }
            }

            AnimatedVisibility(
                panel != null,
                enter = fadeIn(tween(160)) + slideInHorizontally(tween(200)) { it / 6 },
                exit = fadeOut(tween(140)) + slideOutHorizontally(tween(160)) { it / 6 },
            ) {
                key(shownPanel) { SidePanel(c, shownPanel, active = panel != null, onClose = closePanel, onPanel = { openPanel(it, null) }) }
            }
        }
    }
}

/** "−30 s" / "+30 s" bubble on the side of the skip, with a slim progress line underneath for films. */
@Composable
private fun SeekFlashView(f: SeekFlash, c: PlayerController, held: Long) {
    val forward = f.totalMs > 0
    val secs = abs(f.totalMs) / 1000
    val amount = if (secs >= 60) "%d:%02d".format(secs / 60, secs % 60) else "$secs s"
    Box(Modifier.fillMaxSize()) {
        Column(
            Modifier.align(if (forward) Alignment.CenterEnd else Alignment.CenterStart).padding(horizontal = 120.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(Modifier.size(104.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.55f)), contentAlignment = Alignment.Center) {
                Icon(if (forward) Icons.Filled.FastForward else Icons.Filled.FastRewind, null, tint = Color.White, modifier = Modifier.size(46.dp))
            }
            Spacer(Modifier.height(10.dp))
            Text((if (forward) "+" else "−") + amount, fontSize = 24.sp, fontWeight = FontWeight.Bold)
        }
        if (!c.isLive && c.durationMs > 0) {
            val target = (c.positionMs + held).coerceIn(0L, c.durationMs)
            Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(horizontal = 48.dp, vertical = 30.dp)) {
                Row {
                    Text(target.clockText(), fontSize = 19.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.weight(1f))
                    Text("-" + (c.durationMs - target).coerceAtLeast(0).clockText(), fontSize = 19.sp, color = Color.White.copy(alpha = 0.8f))
                }
                Spacer(Modifier.height(8.dp))
                ProgressLine(target.toFloat() / c.durationMs.coerceAtLeast(1), height = 6.dp)
            }
        }
    }
}

/** Channel banner after changing channel with the remote while the controls are hidden. */
@Composable
private fun ZapBanner(c: PlayerController, modifier: Modifier) {
    val ch = c.currentChannel ?: return
    Row(
        modifier.padding(horizontal = 48.dp, vertical = 27.dp).clip(RoundedCornerShape(18.dp))
            .background(Color.Black.copy(alpha = 0.72f)).padding(horizontal = 20.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ChannelLogo(ch.icon, ch.name, 56.dp)
        Spacer(Modifier.width(16.dp))
        Column(Modifier.widthIn(max = 520.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                ch.number?.let { Text("$it  ", fontSize = 20.sp, color = Palette.secondary, fontWeight = FontWeight.SemiBold) }
                Text(ch.name, fontSize = 22.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Spacer(Modifier.width(10.dp))
                LiveBadge()
            }
            c.nowProgramme?.let { Text(it.title, fontSize = 17.sp, color = Color.White.copy(alpha = 0.85f), maxLines = 1, overflow = TextOverflow.Ellipsis) }
            Text("▲ previous  ·  ▼ channel list", fontSize = 14.sp, color = Palette.tertiary)
        }
    }
}

@Composable
private fun Controls(c: PlayerController, onClose: () -> Unit, onPip: () -> Unit, playFocus: FocusRequester, openPanel: (Panel) -> Unit) {
    val step = Settings.values.seekStep * 1000L
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.75f), Color.Transparent, Color.Transparent, Color.Black.copy(alpha = 0.85f))))) {
        // Inside the display cutout / gesture areas, so nothing sits under the notch in landscape.
        Box(Modifier.fillMaxSize().safeDrawingPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                CtrlButton(Icons.Filled.Close, "Close", onClose, 48.dp)
                Spacer(Modifier.width(4.dp))
                if (c.isLive) c.currentChannel?.let { ChannelLogo(it.icon, it.name, 44.dp); Spacer(Modifier.width(10.dp)) }
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(c.title, fontSize = 18.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                        if (c.isLive) { Spacer(Modifier.width(8.dp)); LiveBadge() }
                    }
                    c.subtitle?.let { Text(it, color = Color.White.copy(alpha = 0.75f), maxLines = 1, overflow = TextOverflow.Ellipsis) }
                    if (c.isLive) c.nextProgramme?.let { Text("Next · ${timeText(it.start)} ${it.title}", fontSize = 12.sp, color = Palette.secondary, maxLines = 1) }
                }
                CtrlButton(Icons.Filled.PictureInPictureAlt, "Picture in picture", onPip, 48.dp)
            }

            Row(Modifier.align(Alignment.Center), horizontalArrangement = Arrangement.spacedBy(40.dp), verticalAlignment = Alignment.CenterVertically) {
                if (c.isLive) CtrlButton(Icons.Filled.KeyboardArrowUp, "Previous channel", { c.zap(-1) }, 60.dp)
                else CtrlButton(Icons.Filled.FastRewind, "Back ${step / 1000} seconds", { c.seekBy(-step) }, 60.dp)
                CtrlButton(if (c.paused) Icons.Filled.PlayArrow else Icons.Filled.Pause, if (c.paused) "Play" else "Pause", { c.togglePause() }, 80.dp,
                    Modifier.focusRequester(playFocus), filled = true)
                if (c.isLive) CtrlButton(Icons.Filled.KeyboardArrowDown, "Next channel", { c.zap(1) }, 60.dp)
                else CtrlButton(Icons.Filled.FastForward, "Forward ${step / 1000} seconds", { c.seekBy(step) }, 60.dp)
            }

            Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
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
                            Text("GO LIVE", fontWeight = FontWeight.Bold, color = Palette.live,
                                modifier = Modifier.card({ c.goLive() }, shape = RoundedCornerShape(16.dp)).padding(horizontal = 12.dp, vertical = 10.dp))
                        }
                    }
                } else {
                    var scrub by remember { mutableStateOf<Float?>(null) }
                    val total = c.durationMs.coerceAtLeast(1).toFloat()
                    Slider(
                        value = scrub ?: (c.positionMs / total).coerceIn(0f, 1f),
                        onValueChange = { scrub = it },
                        onValueChangeFinished = { scrub?.let { c.seekTo((it * total).toLong()) }; scrub = null },
                        colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Palette.accent, inactiveTrackColor = Color.White.copy(alpha = 0.25f)),
                    )
                    Row {
                        Text(((scrub?.let { (it * total).toLong() }) ?: c.positionMs).clockText(), fontSize = 12.sp)
                        Spacer(Modifier.weight(1f))
                        Text("-" + (c.durationMs - c.positionMs).coerceAtLeast(0).clockText(), fontSize = 12.sp)
                    }
                }
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {

                    TextChipIcon(Icons.Filled.Audiotrack, "Audio") { openPanel(Panel.AUDIO) }
                    TextChipIcon(Icons.Filled.Subtitles, "Subtitles") { openPanel(Panel.SUBTITLES) }

                    Spacer(Modifier.weight(1f))
                    TextChipIcon(Icons.Filled.Tune, "More") { openPanel(Panel.SETTINGS) }
                }
            }
        }
    }
}

/**
 * 10-foot controls: big title top-left, a focusable seek bar and a row of large buttons. Focus
 * starts on play/pause; Up reaches the seek bar, where Left/Right scrub.
 */
@Composable
private fun TvControls(
    c: PlayerController,
    playFocus: FocusRequester,
    seekFocus: FocusRequester,
    onInteract: () -> Unit,
    openPanel: (Panel, FocusRequester?) -> Unit,
) {
    val step = Settings.values.seekStep * 1000L
    val live = c.isLive
    val audioFocus = remember { FocusRequester() }
    val subsFocus = remember { FocusRequester() }
    val settingsFocus = remember { FocusRequester() }
    val channelsFocus = remember { FocusRequester() }
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

        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(horizontal = 48.dp, vertical = 27.dp).focusGroup()) {
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
                    Text("−${c.behindLiveMs.clockText()} behind live", fontSize = 17.sp, color = Palette.gold)
                }
            } else {
                TvSeekBar(c, step, seekFocus, onInteract)
            }
            Spacer(Modifier.height(18.dp))
            Row(Modifier.fillMaxWidth().focusGroup(), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                SfButton(null, { c.togglePause(); onInteract() }, icon = if (c.paused) Icons.Filled.PlayArrow else Icons.Filled.Pause, kind = ButtonKind.PRIMARY,
                    focusRequester = playFocus, contentDescription = if (c.paused) "Play" else "Pause")
                if (live) {
                    SfButton(null, { c.zap(-1) }, icon = Icons.Filled.KeyboardArrowUp, contentDescription = "Previous channel")
                    SfButton(null, { c.zap(1) }, icon = Icons.Filled.KeyboardArrowDown, contentDescription = "Next channel")
                    SfButton("Channels", { openPanel(Panel.CHANNELS, channelsFocus) }, icon = Icons.AutoMirrored.Filled.List, focusRequester = channelsFocus)
                    SfButton(null, { c.lastChannel() }, icon = Icons.Filled.History, contentDescription = "Last channel")
                    if (c.behindLiveMs > 5_000) SfButton("Go live", { c.goLive() }, kind = ButtonKind.DANGER)
                } else {
                    SfButton(null, { c.seekBy(-step); onInteract() }, icon = Icons.Filled.FastRewind, contentDescription = "Back ${step / 1000} seconds")
                    SfButton(null, { c.seekBy(step); onInteract() }, icon = Icons.Filled.FastForward, contentDescription = "Forward ${step / 1000} seconds")
                    c.nextEpisode?.let { n -> SfButton("Next: ${n.code}", { c.playNextEpisode() }, icon = Icons.Filled.SkipNext) }
                }
                Spacer(Modifier.weight(1f))
                SfButton("Audio", { openPanel(Panel.AUDIO, audioFocus) }, icon = Icons.Filled.Audiotrack, focusRequester = audioFocus)
                SfButton("Subtitles", { openPanel(Panel.SUBTITLES, subsFocus) }, icon = Icons.Filled.Subtitles, focusRequester = subsFocus)
                SfButton(null, { openPanel(Panel.SETTINGS, settingsFocus) }, icon = Icons.Filled.Tune, contentDescription = "Playback settings",
                    focusRequester = settingsFocus)
            }
        }
    }
}

/**
 * Focusable progress bar. Left/Right scrub (held keys speed up) with a time preview over the thumb;
 * OK jumps there (or plays/pauses when not scrubbing), the jump also happens after a short pause or
 * when focus leaves the bar. Back cancels the scrub.
 */
@Composable
private fun TvSeekBar(c: PlayerController, step: Long, requester: FocusRequester, onInteract: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    var scrub by remember { mutableStateOf<Long?>(null) }
    var scrubStamp by remember { mutableLongStateOf(0L) }
    val duration = c.durationMs
    val total = duration.coerceAtLeast(1)
    val shownMs = scrub ?: c.positionMs
    val fraction = (shownMs.toFloat() / total).coerceIn(0f, 1f)
    val played = (c.positionMs.toFloat() / total).coerceIn(0f, 1f)
    val commit = {
        scrub?.let { c.seekTo(it) }
        scrub = null
    }

    LaunchedEffect(scrub, scrubStamp) {
        if (scrub == null) return@LaunchedEffect
        delay(1300)
        commit()
    }
    BackHandler(enabled = scrub != null) { scrub = null }

    Column {
        // Time preview above the thumb while scrubbing.
        BoxWithConstraints(Modifier.fillMaxWidth().height(40.dp).padding(start = 96.dp, end = 110.dp)) {
            val s = scrub
            if (s != null) {
                val bubble = 120.dp
                val x = minOf(maxOf(maxWidth * fraction - bubble / 2, 0.dp), (maxWidth - bubble).coerceAtLeast(0.dp))
                val delta = s - c.positionMs
                Column(Modifier.offset(x = x).width(bubble), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(s.clockText(), fontSize = 19.sp, fontWeight = FontWeight.Bold, color = Palette.onFocus, maxLines = 1,
                        modifier = Modifier.clip(RoundedCornerShape(8.dp)).background(Color.White).padding(horizontal = 10.dp, vertical = 2.dp))
                    Text((if (delta >= 0) "+" else "−") + abs(delta).clockText(), fontSize = 13.sp, color = Color.White.copy(alpha = 0.85f), maxLines = 1)
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(shownMs.clockText(), fontSize = 19.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.width(96.dp))
            Box(
                Modifier.weight(1f).height(32.dp)
                    .focusRequester(requester)
                    .onFocusChanged { s ->
                        focused = s.isFocused
                        if (!s.isFocused) commit()
                    }
                    .onKeyEvent { e ->
                        when (e.key) {
                            Key.DirectionLeft, Key.DirectionRight -> {
                                if (e.type == KeyEventType.KeyDown && duration > 0) {
                                    val r = e.nativeKeyEvent.repeatCount
                                    val mult = when { r > 40 -> 12L; r > 15 -> 4L; r > 5 -> 2L; else -> 1L }
                                    val d = (if (e.key == Key.DirectionLeft) -step else step) * mult
                                    scrub = ((scrub ?: c.positionMs) + d).coerceIn(0L, maxOf(0L, duration - 1000))
                                    scrubStamp = System.currentTimeMillis()
                                    onInteract()
                                }
                                true
                            }
                            Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> {
                                if (e.type == KeyEventType.KeyDown && e.nativeKeyEvent.repeatCount == 0) {
                                    if (scrub != null) commit() else c.togglePause()
                                    onInteract()
                                }
                                true
                            }
                            else -> false
                        }
                    }
                    .focusable(),
                contentAlignment = Alignment.CenterStart,
            ) {
                val h = if (focused) 10.dp else 6.dp
                Box(Modifier.fillMaxWidth().height(h).clip(CircleShape).background(Color.White.copy(alpha = 0.25f)))
                Box(Modifier.fillMaxWidth(played).height(h).clip(CircleShape).background(Palette.gradient))
                if (scrub != null) {
                    // Where it will jump to.
                    Box(Modifier.fillMaxWidth(fraction).height(h).clip(CircleShape).background(Color.White.copy(alpha = 0.35f)))
                }
                if (focused) {
                    Box(Modifier.fillMaxWidth(fraction), contentAlignment = Alignment.CenterEnd) {
                        Box(Modifier.size(26.dp).clip(CircleShape).background(Color.White).padding(5.dp).clip(CircleShape).background(Palette.accent))
                    }
                }
            }
            Text("-" + (c.durationMs - shownMs).coerceAtLeast(0).clockText(), fontSize = 19.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.width(110.dp).padding(start = 14.dp))
        }
        val hint = when {
            !focused -> " "
            scrub != null -> "OK jump here   ·   Back cancel"
            else -> "◀ ▶ scrub ${step / 1000} s   ·   OK ${if (c.paused) "play" else "pause"}"
        }
        Text(hint, fontSize = 15.sp, color = Palette.secondary, modifier = Modifier.padding(start = 96.dp, top = 4.dp))
    }
}

@Composable
private fun CtrlButton(icon: ImageVector, label: String, onClick: () -> Unit, size: Dp = 48.dp, modifier: Modifier = Modifier, filled: Boolean = false) {
    Box(
        modifier.size(size).card(onClick, shape = CircleShape)
            .background(if (filled) Color.White.copy(alpha = 0.18f) else Color.Transparent),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, label, Modifier.size(size * 0.58f), tint = Color.White)
    }
}

@Composable
private fun TextChip(text: String, onClick: () -> Unit) {
    val tv = isTv()
    Text(text, fontSize = if (tv) 17.sp else 13.sp, fontWeight = FontWeight.SemiBold,
        modifier = Modifier.heightIn(min = if (tv) 0.dp else 40.dp).card(onClick, shape = RoundedCornerShape(20.dp)).background(Color.White.copy(alpha = 0.12f))
            .padding(horizontal = 14.dp, vertical = if (tv) 10.dp else 11.dp))
}

@Composable
private fun TextChipIcon(icon: ImageVector, text: String, onClick: () -> Unit) {
    Row(Modifier.heightIn(min = 48.dp).card(onClick, shape = RoundedCornerShape(20.dp)).background(Color.White.copy(alpha = 0.12f)).padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

/**
 * Audio / subtitles / channels / playback panel on the right. On TV it takes focus when it opens and
 * keeps it (nothing else is focusable while it's open); Back or picking a channel closes it.
 */
@Composable
private fun SidePanel(c: PlayerController, panel: Panel, active: Boolean, onClose: () -> Unit, onPanel: (Panel) -> Unit) {
    val tv = isTv()
    val first = remember { FocusRequester() }
    val channels = c.request.channelList
    val focusChannelId = channels.firstOrNull { it.id == c.request.channelId }?.id ?: channels.firstOrNull()?.id
    val listState = rememberLazyListState(
        initialFirstVisibleItemIndex = if (panel == Panel.CHANNELS) channels.distinctBy { it.id }.indexOfFirst { it.id == focusChannelId }.coerceAtLeast(0) else 0)
    // Give the remote something to focus inside the panel (retry while the list composes).
    LaunchedEffect(panel) {
        if (!tv) return@LaunchedEffect
        repeat(8) {
            delay(60)
            if (runCatching { first.requestFocus() }.isSuccess) return@LaunchedEffect
        }
    }
    val outside = if (tv || !active) Modifier else Modifier.pointerInput(Unit) { detectTapGestures { onClose() } }
    BoxWithConstraints(Modifier.fillMaxSize().then(outside)) {
        Column(Modifier.align(Alignment.CenterEnd).fillMaxHeight().width(minOf(maxWidth, if (tv) 460.dp else 380.dp)).background(Color(0xF215131F))
            .then(if (tv) Modifier else Modifier.safeDrawingPadding())
            .padding(horizontal = if (tv) 28.dp else 16.dp, vertical = if (tv) 27.dp else 16.dp)
            .pointerInput(Unit) { detectTapGestures { } }
            .focusGroup()) {
            Text(when (panel) { Panel.AUDIO -> "Audio"; Panel.SUBTITLES -> "Subtitles"; Panel.CHANNELS -> "Channels"; Panel.SETTINGS -> "Playback" },
                fontSize = if (tv) 26.sp else 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(10.dp))
            LazyColumn(state = listState, verticalArrangement = Arrangement.spacedBy(if (tv) 4.dp else 0.dp)) {
                when (panel) {
                    Panel.AUDIO -> {
                        if (c.audioTracks.isEmpty()) item { Text("No audio tracks", color = Palette.secondary, fontSize = if (tv) 17.sp else 13.sp) }
                        itemsIndexed(c.audioTracks) { i, t ->
                            Option(t.label, t.selected, if (i == 0) Modifier.focusRequester(first) else Modifier) { c.selectAudio(t) }
                        }
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
                                Spacer(Modifier.width(8.dp))
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
                        if (!tv && c.isLive) {
                            item { Option("Channels", false) { onPanel(Panel.CHANNELS) } }
                            item { Option("Previous channel", false) { c.lastChannel(); onClose() } }
                        }
                        if (!tv && !c.isLive && c.nextEpisode != null) {
                            item { Option("Next episode", false) { c.playNextEpisode(); onClose() } }
                        }
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
