package com.mohamedt.streamforge.ui.screens

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.MediaType
import com.mohamedt.streamforge.core.Origin
import com.mohamedt.streamforge.core.byteText
import com.mohamedt.streamforge.player.PlaybackRequest
import com.mohamedt.streamforge.player.PlaybackSource
import com.mohamedt.streamforge.player.Player
import com.mohamedt.streamforge.player.SourceKind
import com.mohamedt.streamforge.torrent.TorrServer
import com.mohamedt.streamforge.torrent.TorrentSource
import com.mohamedt.streamforge.torrent.TorrentStatus
import com.mohamedt.streamforge.ui.Artwork
import com.mohamedt.streamforge.ui.Dims
import com.mohamedt.streamforge.ui.EmptyState
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.Pill
import com.mohamedt.streamforge.ui.ProgressLine
import com.mohamedt.streamforge.ui.card
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Torrent status: peers, seeders, speeds, downloaded, buffer, and which title/addon each belongs to. */
@Composable
fun ActivityScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var magnet by remember { mutableStateOf("") }
    var reachable by remember { mutableStateOf<Boolean?>(null) }

    LaunchedEffect(Unit) {
        while (true) {
            if (TorrServer.embedded) TorrServer.startEmbeddedIfNeeded()
            reachable = TorrServer.ping()
            TorrServer.refreshList()
            delay(2000)
        }
    }

    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(Dims.gutter()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Text("Activity", fontSize = 26.sp, fontWeight = FontWeight.Bold)
            val engine = if (TorrServer.embedded) "On-device engine" else "Remote TorrServer"
            val state = when (reachable) { true -> "running"; false -> "not reachable"; null -> "checking…" }
            Text("$engine · $state", color = if (reachable == false) Palette.live else Palette.secondary)
            TorrServer.lastError?.let { Text(it, color = Palette.live, fontSize = 12.sp) }
        }
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(magnet, { magnet = it }, Modifier.weight(1f), placeholder = { Text("Paste a magnet link") }, singleLine = true)
                TextButton(onClick = {
                    TorrentSource.parse(magnet.trim())?.let { t ->
                        Player.play(context, PlaybackRequest(MediaItem("torrent:${t.infoHash}", MediaType.OTHER, t.title ?: "Torrent", origin = Origin("tmdb")),
                            source = PlaybackSource("magnet:${t.infoHash}", SourceKind.Torrent(t), t.title ?: "Torrent", provider = "Magnet")))
                        magnet = ""
                    }
                }) { Text("Play") }
            }
        }
        if (TorrServer.torrents.isEmpty()) {
            item { Spacer(Modifier.height(40.dp)); EmptyState("No active torrents", "Torrents you stream from addons appear here with live peer and speed stats.") }
        }
        items(TorrServer.torrents, key = { it.hash }) { t -> TorrentCard(t) { scope.launch { TorrServer.remove(t.hash) } } }
    }
}

@Composable
private fun TorrentCard(t: TorrentStatus, onRemove: () -> Unit) {
    val context = LocalContext.current
    val ctx = TorrServer.contexts[t.hash]
    val history = TorrServer.speedHistory[t.hash] ?: emptyList()
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Palette.surface).padding(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Artwork(ctx?.poster ?: t.poster, Modifier.width(54.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(8.dp)), label = (ctx?.title ?: t.title).take(1))
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(ctx?.title ?: t.title.ifEmpty { t.hash.take(12) }, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                listOfNotNull(ctx?.subtitle, ctx?.addon?.let { "via $it" }).joinToString(" · ").takeIf { it.isNotEmpty() }?.let {
                    Text(it, fontSize = 12.sp, color = Palette.secondary)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(top = 4.dp)) {
                    Pill(t.statText.ifEmpty { "Active" }, Palette.accent.copy(alpha = 0.35f))
                    if (t.size > 0) Pill(t.size.byteText())
                }
            }
            TextButton(onClick = onRemove) { Text("Remove", color = Palette.live) }
        }
        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Stat("Download", "${(t.downloadSpeed.toLong()).byteText()}/s")
            Stat("Upload", "${(t.uploadSpeed.toLong()).byteText()}/s")
            Stat("Peers", "${t.activePeers}/${t.totalPeers}")
            Stat("Seeders", "${t.seeders}")
            Stat("Downloaded", maxOf(t.loaded, t.bytesRead).byteText())
        }
        if (t.preloadSize > 0) {
            Spacer(Modifier.height(8.dp))
            Text("Buffer ${t.preloaded.byteText()} / ${t.preloadSize.byteText()}", fontSize = 11.sp, color = Palette.secondary)
            ProgressLine((t.preloaded.toFloat() / t.preloadSize).coerceIn(0f, 1f))
        }
        if (history.size > 2) {
            Spacer(Modifier.height(8.dp))
            SpeedGraph(history, Modifier.fillMaxWidth().height(44.dp))
        }
        if (t.videoFiles.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            t.videoFiles.take(12).forEach { f ->
                Text("▶ ${f.name} · ${f.length.byteText()}", fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.fillMaxWidth().card({
                        val src = TorrentSource(t.hash, f.id - 1, f.name, title = ctx?.title ?: t.title, poster = t.poster)
                        Player.play(context, PlaybackRequest(MediaItem("torrent:${t.hash}:${f.id}", MediaType.OTHER, f.name, poster = t.poster, origin = Origin("tmdb")),
                            source = PlaybackSource("tfile:${t.hash}:${f.id}", SourceKind.Torrent(src), f.name, provider = "Torrent")))
                    }).padding(vertical = 6.dp))
            }
        }
    }
}

@Composable
private fun Stat(label: String, value: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, fontWeight = FontWeight.Bold, fontSize = 14.sp)
        Text(label, fontSize = 11.sp, color = Palette.secondary)
    }
}

@Composable
private fun SpeedGraph(values: List<Double>, modifier: Modifier) {
    val max = (values.maxOrNull() ?: 1.0).coerceAtLeast(1.0)
    Canvas(modifier) {
        val step = size.width / (values.size - 1).coerceAtLeast(1)
        val path = Path()
        values.forEachIndexed { i, v ->
            val p = Offset(i * step, size.height - (v / max).toFloat() * size.height)
            if (i == 0) path.moveTo(p.x, p.y) else path.lineTo(p.x, p.y)
        }
        drawPath(path, Palette.accent, style = Stroke(width = 3f))
    }
}
