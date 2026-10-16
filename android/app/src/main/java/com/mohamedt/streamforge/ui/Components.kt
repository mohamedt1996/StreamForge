package com.mohamedt.streamforge.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import com.mohamedt.streamforge.core.Settings
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.library.Library
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily

/** Same palette as the Apple TV app: near-black violet night, violet → pink accent, gold for 4K. */
object Palette {
    val background = Color(0xFF0C0D11)
    val surface = Color(0x14FFFFFF)
    val surfaceHigh = Color(0x22FFFFFF)
    /** Opaque panel colour (side panels, dialogs). */
    val raised = Color(0xFF191B22)
    val accent = Color(0xFF8C5CF5)
    val accent2 = accent
    val live = Color(0xFFF5424D)
    val gold = Color(0xFFFACC15)
    val secondary = Color(0x9EFFFFFF)
    val tertiary = Color(0x6BFFFFFF)
    /** Text/icons drawn on a focused (white) control. */
    val onFocus = Color(0xFF0D0B16)
    val gradient = Brush.linearGradient(listOf(accent, accent2))
}

val LocalWatchlistAction = compositionLocalOf<(MediaItem) -> Unit> { {} }
private val typography = Typography(
    titleLarge = TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Bold, fontSize = 24.sp, lineHeight = 30.sp),
    titleMedium = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 16.sp, lineHeight = 22.sp),
    bodyMedium = TextStyle(fontSize = 14.sp, lineHeight = 20.sp),
    labelLarge = TextStyle(fontWeight = FontWeight.SemiBold, fontSize = 14.sp, lineHeight = 20.sp),
)

private val colors = darkColorScheme(
    primary = Palette.accent,
    secondary = Palette.accent2,
    background = Palette.background,
    surface = Color(0xFF13111E),
    surfaceVariant = Color(0xFF1C1A2B),
    onPrimary = Color.White,
    onBackground = Color.White,
    onSurface = Color.White,
)

/**
 * App theme. Also decides, once per activity, whether the 10-foot (remote) interface or the touch
 * interface is used (hardware detection + Settings → Interface + the last input seen), and
 * provides it through [LocalTvMode] so every screen agrees.
 */
@Composable
fun StreamForgeTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    val hardware = remember { DeviceInput.isTvHardware(context) }
    val lowEnd = remember { Perf.lowEnd(context) }
    val tv = DeviceInput.resolve(InterfaceMode.of(Settings.values.interfaceMode), hardware)
    // Phone vs tablet by the smallest screen side (stable across rotation); TV always wins.
    val smallestWidth = LocalConfiguration.current.smallestScreenWidthDp
    val formFactor = when {
        tv -> FormFactor.TV
        smallestWidth >= 600 -> FormFactor.TABLET
        else -> FormFactor.PHONE
    }
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val toggleSaved: (MediaItem) -> Unit = { item ->
        val removed = Library.isFavorite(item)
        Library.setFavorite(item, !removed)
        scope.launch {
            snackbar.currentSnackbarData?.dismiss()
            if (snackbar.showSnackbar(if (removed) "Removed ${item.title} from My List" else "Added ${item.title} to My List",
                    actionLabel = "Undo", withDismissAction = true) == SnackbarResult.ActionPerformed) {
                Library.setFavorite(item, removed)
            }
        }
    }
    CompositionLocalProvider(
        LocalTvMode provides tv,
        LocalFormFactor provides formFactor,
        LocalLowEnd provides lowEnd,
        LocalWatchlistAction provides toggleSaved,
    ) {
        MaterialTheme(colorScheme = colors, typography = typography) {
            Box(Modifier.fillMaxSize()) {
                content()
                SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).padding(horizontal = 16.dp, vertical = 88.dp))
            }
        }
    }
}

/** True when the remote-driven 10-foot interface is active (see [DeviceInput]). */
@Composable
fun isTv(): Boolean = LocalTvMode.current

/** Phone, tablet or TV (see [StreamForgeTheme]). */
@Composable
fun formFactor(): FormFactor = LocalFormFactor.current

/** Low-end device: skip costly effects (see [Perf]). */
@Composable
fun isLowEnd(): Boolean = LocalLowEnd.current

// The width checks below pick phone vs tablet layouts. They are always false on TV: a TV screen
// is ~960 dp wide, which would otherwise pull in the tablet layouts (rails, two-pane pages).

/** Wide window (large tablet, landscape tablet): poster sizes and two-column layouts. */
@Composable
fun isWide(): Boolean = !isTv() && LocalConfiguration.current.screenWidthDp >= 720

/** Medium or wider window (tablet, phone in landscape): navigation rail instead of a bottom bar. */
@Composable
fun isMediumWidth(): Boolean = !isTv() && LocalConfiguration.current.screenWidthDp >= 600

/** Expanded window (tablet in landscape, large foldables): two-pane layouts. */
@Composable
fun isExpandedWidth(): Boolean = !isTv() && LocalConfiguration.current.screenWidthDp >= 840

object Dims {
    @Composable fun poster(): Dp = if (isTv()) 140.dp else if (isWide()) 140.dp else 112.dp
    @Composable fun landscape(): Dp = if (isTv()) 280.dp else if (isWide()) 300.dp else 240.dp
    /** Horizontal page margin; on TV it is the overscan-safe keyline (≈5 % of 960 dp). */
    @Composable fun gutter(): Dp = if (isTv()) 48.dp else 16.dp
    /** Overscan-safe top/bottom margin on TV. */
    val overscanY = 27.dp
}

/** Rows set this so their cards can remember/restore focus as "row/item". */
val LocalShelfKey = compositionLocalOf<String?> { null }

/** Screens that react to the focused item (the Home billboard) provide this. */
val LocalItemFocus = compositionLocalOf<((MediaItem) -> Unit)?> { null }

/**
 * Clickable that works with a remote and with touch. Focused: grows (1.08 on TV), white border,
 * soft violet glow; optionally dims while unfocused. [focusKey] lets the screen restore focus to
 * this element when it is shown again.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun Modifier.card(
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
    shape: Shape = RoundedCornerShape(10.dp),
    focusScale: Float? = null,
    glow: Boolean = true,
    dimUnfocused: Boolean = false,
    focusKey: String? = null,
    focusRequester: FocusRequester? = null,
    border: Boolean = true,
    onFocus: ((Boolean) -> Unit)? = null,
): Modifier {
    val tv = isTv()
    val lowEnd = isLowEnd()
    var focused by remember { mutableStateOf(false) }
    val memory = LocalFocusMemory.current
    val restore = remember { FocusRequester() }
    val target = if (focused) (focusScale ?: if (tv) 1.08f else 1.04f) else 1f
    // Short and snappy on TV: a long scale animation on every D-pad press reads as lag.
    val scale by animateFloatAsState(target, tween(if (tv) (if (lowEnd) 110 else 150) else 120), label = "card-scale")
    val restoring = focusKey != null && memory != null
    if (restoring) {
        val pending = memory?.pending
        LaunchedEffect(pending, focusKey) {
            if (pending != null && pending == focusKey) {
                delay(40)
                if (runCatching { restore.requestFocus() }.isSuccess) memory?.pending = null
            }
        }
    }
    var m: Modifier = this.graphicsLayer {
        scaleX = scale
        scaleY = scale
    }
    // The coloured elevation glow is re-rendered on every frame of the scale animation; low-end TVs
    // (Chromecast with Google TV) get the white border alone, which reads just as clearly at 3 m.
    if (focused && tv && glow && !lowEnd) m = m.shadow(18.dp, shape, clip = false, ambientColor = Palette.accent, spotColor = Palette.accent)
    if (border) {
        m = m.border(if (focused) BorderStroke(if (tv) 3.dp else 2.dp, Color.White) else BorderStroke(0.dp, Color.Transparent), shape)
    }
    m = m.clip(shape)
    if (dimUnfocused && tv) {
        m = m.drawWithContent {
            drawContent()
            if (!focused) drawRect(Color.Black.copy(alpha = 0.28f))
        }
    }
    if (restoring) m = m.focusRequester(restore)
    if (focusRequester != null) m = m.focusRequester(focusRequester)
    return m
        .onFocusChanged { s ->
            if (s.isFocused != focused) {
                focused = s.isFocused
                if (s.isFocused && focusKey != null) memory?.record(focusKey)
                onFocus?.invoke(s.isFocused)
            }
        }
        .combinedClickable(onClick = onClick, onLongClick = onLongClick)
}

@Composable
fun Artwork(url: String?, modifier: Modifier = Modifier, contentScale: ContentScale = ContentScale.Crop, label: String? = null) {
    Box(modifier.background(Brush.verticalGradient(listOf(Palette.surfaceHigh, Palette.surface))), contentAlignment = Alignment.Center) {
        if (label != null) {
            Text(label, color = Color.White.copy(alpha = 0.6f), fontSize = if (isTv()) 15.sp else 12.sp, fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center, maxLines = 3, modifier = Modifier.padding(8.dp))
        } else {
            Icon(Icons.Filled.Movie, null, tint = Color.White.copy(alpha = 0.25f))
        }
        if (url != null) AsyncImage(model = url, contentDescription = null, contentScale = contentScale, modifier = Modifier.fillMaxSize())
    }
}

@Composable
fun ProgressLine(fraction: Float, modifier: Modifier = Modifier, height: Dp = 3.dp) {
    Box(modifier.fillMaxWidth().height(height).clip(CircleShape).background(Color.White.copy(alpha = 0.22f))) {
        Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).height(height).background(Palette.gradient))
    }
}

@Composable
fun PosterCard(item: MediaItem, onClick: () -> Unit, onLongClick: (() -> Unit)? = null) {
    val tv = isTv()
    val width = Dims.poster()
    var focused by remember { mutableStateOf(false) }
    val shelf = LocalShelfKey.current
    val onItemFocus = LocalItemFocus.current
    Column(Modifier.width(width)) {
        Box(
            Modifier.width(width).aspectRatio(2f / 3f).card(
                onClick, onLongClick, RoundedCornerShape(if (tv) 12.dp else 10.dp),
                dimUnfocused = true,
                focusKey = shelf?.let { "$it/${item.id}" },
                onFocus = { f -> focused = f; if (f) onItemFocus?.invoke(item) },
            ),
        ) {
            Artwork(item.poster, Modifier.fillMaxSize(), label = item.title)
            val p = Library.progress(item)
            if (p != null && p.fraction > 0.02f) ProgressLine(p.fraction, Modifier.align(Alignment.BottomCenter).padding(6.dp), if (tv) 4.dp else 3.dp)
            if (Library.isWatched(item)) {
                Icon(Icons.Filled.CheckCircle, null, tint = Palette.accent, modifier = Modifier.align(Alignment.TopEnd).padding(6.dp))
            } else item.rating?.let { r ->
                Row(Modifier.align(Alignment.TopEnd).padding(6.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.65f)).padding(horizontal = 6.dp, vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Star, null, tint = Palette.gold, modifier = Modifier.size(if (tv) 14.dp else 12.dp))
                    Text(" %.1f".format(r), fontSize = if (tv) 13.sp else 11.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
        if (tv) {
            // 10-foot: only the focused card names itself; the space is reserved so rows don't jump.
            Spacer(Modifier.height(10.dp))
            Text(item.title, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.height(22.dp).alpha(if (focused) 1f else 0f))
        } else {
            Spacer(Modifier.height(6.dp))
            Text(item.title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            item.year?.let { Text(it.toString(), fontSize = 11.sp, color = Palette.secondary) }
        }
    }
}

@Composable
fun LandscapeCard(
    title: String,
    subtitle: String?,
    image: String?,
    progress: Float? = null,
    badge: String? = null,
    item: MediaItem? = null,
    focusId: String? = null,
    onLongClick: (() -> Unit)? = null,
    onClick: () -> Unit,
) {
    val tv = isTv()
    val width = Dims.landscape()
    var focused by remember { mutableStateOf(false) }
    val shelf = LocalShelfKey.current
    val onItemFocus = LocalItemFocus.current
    Column(Modifier.width(width)) {
        Box(
            Modifier.width(width).aspectRatio(16f / 9f).card(
                onClick, onLongClick, RoundedCornerShape(if (tv) 14.dp else 12.dp),
                dimUnfocused = true,
                focusKey = shelf?.let { s -> "$s/${focusId ?: item?.id ?: title}" },
                onFocus = { f -> focused = f; if (f && item != null) onItemFocus?.invoke(item) },
            ),
        ) {
            Artwork(image, Modifier.fillMaxSize(), label = title)
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.7f)))))
            Column(Modifier.align(Alignment.BottomStart).padding(if (tv) 12.dp else 8.dp)) {
                badge?.let { Pill(it, Color.Black.copy(alpha = 0.6f)) }
                progress?.let { Spacer(Modifier.height(6.dp)); ProgressLine(it, height = if (tv) 4.dp else 3.dp) }
            }
        }
        if (tv) {
            Spacer(Modifier.height(10.dp))
            Column(Modifier.height(44.dp).alpha(if (focused) 1f else 0f)) {
                Text(title, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                subtitle?.let { Text(it, fontSize = 14.sp, color = Palette.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            }
        } else {
            Spacer(Modifier.height(6.dp))
            Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            subtitle?.let { Text(it, fontSize = 12.sp, color = Palette.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
    }
}

@Composable
fun Pill(text: String, color: Color = Palette.surfaceHigh, textColor: Color = Color.White) {
    val tv = isTv()
    Text(text, fontSize = if (tv) 13.sp else 10.sp, fontWeight = FontWeight.Bold, color = textColor, maxLines = 1,
        modifier = Modifier.clip(RoundedCornerShape(5.dp)).background(color).padding(horizontal = if (tv) 9.dp else 7.dp, vertical = if (tv) 4.dp else 3.dp))
}

@Composable
fun LiveBadge() = Pill("● LIVE", Palette.live)

@Composable
fun SectionHeader(title: String, subtitle: String? = null, action: (() -> Unit)? = null) {
    if (isTv()) {
        // One fixed-height line, so the vertical keyline of each row is predictable.
        Row(Modifier.fillMaxWidth().height(34.dp).padding(horizontal = Dims.gutter()), verticalAlignment = Alignment.Bottom) {
            Text(title, fontSize = 22.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
            subtitle?.let {
                Spacer(Modifier.width(14.dp))
                Text(it, fontSize = 15.sp, color = Palette.tertiary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(bottom = 2.dp))
            }
        }
        return
    }
    Row(Modifier.fillMaxWidth().padding(horizontal = Dims.gutter()), verticalAlignment = Alignment.Bottom) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            subtitle?.let { Text(it, fontSize = 12.sp, color = Palette.secondary) }
        }
        if (action != null) {
            Text("See all", color = Palette.accent, fontWeight = FontWeight.SemiBold, fontSize = 14.sp,
                modifier = Modifier.card(action, shape = RoundedCornerShape(16.dp)).padding(horizontal = 12.dp, vertical = 10.dp))
        }
    }
}

/** Distance from a row's top to its cards' top on TV (header 34 + gap 4 + padding 6 + 12). */
val TvRowCardOffset = 56.dp

@Composable
fun <T> Shelf(
    title: String,
    items: List<T>,
    subtitle: String? = null,
    seeAll: (() -> Unit)? = null,
    key: ((T) -> Any)? = null,
    rowKey: String? = null,
    content: @Composable (T) -> Unit,
) {
    if (items.isEmpty()) return
    val tv = isTv()
    Column(Modifier.padding(vertical = if (tv) 6.dp else 10.dp)) {
        SectionHeader(title, subtitle, if (tv) null else seeAll)
        Spacer(Modifier.height(if (tv) 4.dp else 10.dp))
        CompositionLocalProvider(LocalShelfKey provides (rowKey ?: title)) {
            KeylineScroll(Dims.gutter(), enabled = tv) {
                LazyRow(
                    contentPadding = PaddingValues(horizontal = Dims.gutter(), vertical = if (tv) 12.dp else 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(if (tv) 20.dp else 12.dp),
                ) {
                    // Duplicate keys crash a lazy list (addons, TMDB credits and providers do repeat ids).
                    if (key != null) items(items.distinctBy { key(it) }, key = key) { content(it) } else items(items) { content(it) }
                    // TV: "See all" is the last stop of the row instead of a small header link.
                    if (tv && seeAll != null) item(key = "__see_all__") { SeeAllTile(seeAll) }
                }
            }
        }
    }
}

@Composable
private fun SeeAllTile(onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    Column(Modifier.width(Dims.poster())) {
        Column(
            Modifier.width(Dims.poster()).aspectRatio(2f / 3f)
                .card(onClick, shape = RoundedCornerShape(12.dp), focusKey = LocalShelfKey.current?.let { "$it/__see_all__" }, onFocus = { focused = it })
                .background(if (focused) SolidColor(Color.White) else SolidColor(Palette.surface)),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Icon(Icons.AutoMirrored.Filled.ArrowForward, null, tint = if (focused) Palette.onFocus else Color.White, modifier = Modifier.size(34.dp))
            Spacer(Modifier.height(10.dp))
            Text("See all", fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = if (focused) Palette.onFocus else Color.White)
        }
    }
}

@Composable
fun ChannelLogo(url: String?, name: String, size: Dp = 44.dp) {
    Box(Modifier.size(size).clip(RoundedCornerShape(size * 0.22f)).background(Palette.surfaceHigh), contentAlignment = Alignment.Center) {
        if (url != null) {
            AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize().padding(size * 0.12f))
        } else {
            Text(name.split(" ").take(2).mapNotNull { it.firstOrNull() }.joinToString("").uppercase(), fontWeight = FontWeight.Bold, fontSize = (size.value * 0.32f).sp)
        }
    }
}

@Composable
fun Chip(text: String, selected: Boolean, modifier: Modifier = Modifier, focusRequester: FocusRequester? = null, onClick: () -> Unit) {
    val tv = isTv()
    var focused by remember { mutableStateOf(false) }
    val bg = when {
        focused && tv -> SolidColor(Color.White)
        selected -> Palette.gradient
        else -> SolidColor(if (tv) Palette.surfaceHigh else Palette.surface)
    }
    Text(text, fontSize = if (tv) 17.sp else 14.sp, fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium, maxLines = 1,
        color = if (focused && tv) Palette.onFocus else Color.White,
        modifier = modifier.card(onClick, shape = RoundedCornerShape(24.dp), focusScale = if (tv) 1.06f else null, border = !tv,
            glow = false, focusRequester = focusRequester, onFocus = { focused = it })
            .background(bg)
            .padding(horizontal = if (tv) 22.dp else 16.dp, vertical = if (tv) 11.dp else 9.dp))
}

@Composable
fun EmptyState(title: String, message: String, actionTitle: String? = null, action: (() -> Unit)? = null) {
    val tv = isTv()
    val first = remember { FocusRequester() }
    Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Text(title, fontSize = if (tv) 30.sp else 20.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
        Spacer(Modifier.height(if (tv) 12.dp else 8.dp))
        Text(message, fontSize = if (tv) 18.sp else 14.sp, color = Palette.secondary, textAlign = TextAlign.Center,
            modifier = Modifier.width(if (tv) 620.dp else 520.dp))
        if (actionTitle != null && action != null) {
            Spacer(Modifier.height(if (tv) 24.dp else 16.dp))
            SfButton(actionTitle, action, kind = ButtonKind.PRIMARY, focusRequester = first)
            InitialFocus(first)
        }
    }
}

@Composable
fun Loading(text: String = "Loading…") {
    Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        CircularProgressIndicator(color = Color.White)
        Spacer(Modifier.height(12.dp))
        Text(text, color = Palette.secondary, fontSize = if (isTv()) 18.sp else 14.sp)
    }
}

/** Big page title used by TV screens (and modestly on phones). */
@Composable
fun PageTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, fontSize = if (isTv()) 32.sp else 26.sp, fontWeight = FontWeight.Bold, modifier = modifier)
}

/** Pull-to-refresh for touch lists: shows the indicator briefly while [onRefresh] reloads in the background. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PullRefresh(onRefresh: () -> Unit, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    if (isTv()) {
        Box(modifier.fillMaxSize()) { content() }
        return
    }
    var refreshing by remember { mutableStateOf(false) }
    LaunchedEffect(refreshing) {
        if (refreshing) {
            onRefresh()
            delay(1200)
            refreshing = false
        }
    }
    PullToRefreshBox(isRefreshing = refreshing, onRefresh = { refreshing = true }, modifier = modifier.fillMaxSize()) { content() }
}
