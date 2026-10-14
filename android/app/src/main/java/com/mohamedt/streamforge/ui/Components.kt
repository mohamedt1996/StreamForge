package com.mohamedt.streamforge.ui

import android.content.res.Configuration
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
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.library.Library

object Palette {
    val background = Color(0xFF08071A)
    val surface = Color(0x14FFFFFF)
    val surfaceHigh = Color(0x22FFFFFF)
    val accent = Color(0xFF8B5CF6)
    val accent2 = Color(0xFFEC4899)
    val live = Color(0xFFF5424D)
    val gold = Color(0xFFFAC83F)
    val secondary = Color(0x9EFFFFFF)
    val gradient = Brush.linearGradient(listOf(accent, accent2))
}

private val colors = darkColorScheme(
    primary = Palette.accent,
    secondary = Palette.accent2,
    background = Palette.background,
    surface = Color(0xFF13112A),
    surfaceVariant = Color(0xFF1C1A35),
    onPrimary = Color.White,
    onBackground = Color.White,
    onSurface = Color.White,
)

@Composable
fun StreamForgeTheme(content: @Composable () -> Unit) = MaterialTheme(colorScheme = colors, content = content)

@Composable
fun isTv(): Boolean =
    (LocalConfiguration.current.uiMode and Configuration.UI_MODE_TYPE_MASK) == Configuration.UI_MODE_TYPE_TELEVISION

@Composable
fun isWide(): Boolean = LocalConfiguration.current.screenWidthDp >= 720

object Dims {
    @Composable fun poster(): Dp = if (isTv()) 150.dp else if (isWide()) 140.dp else 112.dp
    @Composable fun landscape(): Dp = if (isTv()) 300.dp else if (isWide()) 300.dp else 240.dp
    @Composable fun gutter(): Dp = if (isTv()) 48.dp else 16.dp
}

/** Clickable that also works with a TV remote: grows and gets an accent border when focused. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun Modifier.card(onClick: () -> Unit, onLongClick: (() -> Unit)? = null, shape: RoundedCornerShape = RoundedCornerShape(10.dp)): Modifier {
    var focused by remember { mutableStateOf(false) }
    return this
        .scale(if (focused) 1.06f else 1f)
        .border(if (focused) BorderStroke(3.dp, Color.White) else BorderStroke(0.dp, Color.Transparent), shape)
        .clip(shape)
        .onFocusChanged { focused = it.isFocused }
        .combinedClickable(onClick = onClick, onLongClick = onLongClick)
}

@Composable
fun Artwork(url: String?, modifier: Modifier = Modifier, contentScale: ContentScale = ContentScale.Crop, label: String? = null) {
    Box(modifier.background(Brush.verticalGradient(listOf(Palette.surfaceHigh, Palette.surface))), contentAlignment = Alignment.Center) {
        if (url == null && label != null) {
            Text(label, color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center, maxLines = 3, modifier = Modifier.padding(8.dp))
        } else if (url == null) {
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
    val width = Dims.poster()
    Column(Modifier.width(width)) {
        Box(Modifier.width(width).aspectRatio(2f / 3f).card(onClick, onLongClick)) {
            Artwork(item.poster, Modifier.fillMaxSize(), label = item.title)
            val p = Library.progress(item)
            if (p != null && p.fraction > 0.02f) ProgressLine(p.fraction, Modifier.align(Alignment.BottomCenter).padding(6.dp))
            if (Library.isWatched(item)) {
                Icon(Icons.Filled.CheckCircle, null, tint = Palette.accent, modifier = Modifier.align(Alignment.TopEnd).padding(6.dp))
            } else item.rating?.let { r ->
                Row(Modifier.align(Alignment.TopEnd).padding(6.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.65f)).padding(horizontal = 6.dp, vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Star, null, tint = Palette.gold, modifier = Modifier.size(12.dp))
                    Text(" %.1f".format(r), fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(item.title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        item.year?.let { Text(it.toString(), fontSize = 11.sp, color = Palette.secondary) }
    }
}

@Composable
fun LandscapeCard(title: String, subtitle: String?, image: String?, progress: Float? = null, badge: String? = null, onClick: () -> Unit) {
    val width = Dims.landscape()
    Column(Modifier.width(width)) {
        Box(Modifier.width(width).aspectRatio(16f / 9f).card(onClick, shape = RoundedCornerShape(12.dp))) {
            Artwork(image, Modifier.fillMaxSize(), label = title)
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.7f)))))
            Column(Modifier.align(Alignment.BottomStart).padding(8.dp)) {
                badge?.let { Pill(it, Color.Black.copy(alpha = 0.6f)) }
                progress?.let { Spacer(Modifier.height(6.dp)); ProgressLine(it) }
            }
        }
        Spacer(Modifier.height(6.dp))
        Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        subtitle?.let { Text(it, fontSize = 12.sp, color = Palette.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis) }
    }
}

@Composable
fun Pill(text: String, color: Color = Palette.surfaceHigh, textColor: Color = Color.White) {
    Text(text, fontSize = 10.sp, fontWeight = FontWeight.Bold, color = textColor,
        modifier = Modifier.clip(RoundedCornerShape(5.dp)).background(color).padding(horizontal = 7.dp, vertical = 3.dp))
}

@Composable
fun LiveBadge() = Pill("● LIVE", Palette.live)

@Composable
fun SectionHeader(title: String, subtitle: String? = null, action: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().padding(horizontal = Dims.gutter()), verticalAlignment = Alignment.Bottom) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            subtitle?.let { Text(it, fontSize = 12.sp, color = Palette.secondary) }
        }
        if (action != null) {
            Text("See all", color = Palette.accent, fontWeight = FontWeight.SemiBold, fontSize = 14.sp,
                modifier = Modifier.card(action, shape = RoundedCornerShape(6.dp)).padding(6.dp))
        }
    }
}

@Composable
fun <T> Shelf(title: String, items: List<T>, subtitle: String? = null, seeAll: (() -> Unit)? = null, key: ((T) -> Any)? = null, content: @Composable (T) -> Unit) {
    if (items.isEmpty()) return
    Column(Modifier.padding(vertical = 10.dp)) {
        SectionHeader(title, subtitle, seeAll)
        Spacer(Modifier.height(10.dp))
        LazyRow(contentPadding = PaddingValues(horizontal = Dims.gutter(), vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(if (isTv()) 22.dp else 12.dp)) {
            // Duplicate keys crash a lazy list (addons, TMDB credits and providers do repeat ids).
            if (key != null) items(items.distinctBy { key(it) }, key = key) { content(it) } else items(items) { content(it) }
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
fun Chip(text: String, selected: Boolean, onClick: () -> Unit) {
    Text(text, fontSize = 14.sp, fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium, maxLines = 1,
        modifier = Modifier.card(onClick, shape = RoundedCornerShape(20.dp))
            .background(if (selected) Palette.gradient else Brush.linearGradient(listOf(Palette.surface, Palette.surface)))
            .padding(horizontal = 14.dp, vertical = 7.dp))
}

@Composable
fun EmptyState(title: String, message: String, actionTitle: String? = null, action: (() -> Unit)? = null) {
    Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Text(title, fontSize = 20.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
        Spacer(Modifier.height(8.dp))
        Text(message, fontSize = 14.sp, color = Palette.secondary, textAlign = TextAlign.Center)
        if (actionTitle != null && action != null) {
            Spacer(Modifier.height(16.dp))
            Button(onClick = action, colors = ButtonDefaults.buttonColors(containerColor = Palette.accent)) { Text(actionTitle) }
        }
    }
}

@Composable
fun Loading(text: String = "Loading…") {
    Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        CircularProgressIndicator(color = Color.White)
        Spacer(Modifier.height(12.dp))
        Text(text, color = Palette.secondary)
    }
}
