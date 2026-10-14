package com.mohamedt.streamforge

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudDownload
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import com.mohamedt.streamforge.core.MediaType
import com.mohamedt.streamforge.player.Player
import com.mohamedt.streamforge.stremio.Addons
import com.mohamedt.streamforge.ui.LocalNav
import com.mohamedt.streamforge.ui.Navigator
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.Screen
import com.mohamedt.streamforge.ui.StreamForgeTheme
import com.mohamedt.streamforge.ui.Tab
import com.mohamedt.streamforge.ui.isTv
import com.mohamedt.streamforge.ui.isWide
import com.mohamedt.streamforge.ui.screens.ActivityScreen
import com.mohamedt.streamforge.ui.screens.CatalogScreen
import com.mohamedt.streamforge.ui.screens.CategoryScreen
import com.mohamedt.streamforge.ui.screens.CollectionScreen
import com.mohamedt.streamforge.ui.screens.DetailScreen
import com.mohamedt.streamforge.ui.screens.GuideScreen
import com.mohamedt.streamforge.ui.screens.HomeScreen
import com.mohamedt.streamforge.ui.screens.LiveScreen
import com.mohamedt.streamforge.ui.screens.PersonScreen
import com.mohamedt.streamforge.ui.screens.RecordingsScreen
import com.mohamedt.streamforge.ui.screens.SearchScreen
import com.mohamedt.streamforge.ui.screens.SettingsScreen
import com.mohamedt.streamforge.ui.screens.VodScreen
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import com.mohamedt.streamforge.torrent.TorrentSource
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.Origin
import com.mohamedt.streamforge.player.PlaybackRequest
import com.mohamedt.streamforge.player.PlaybackSource
import com.mohamedt.streamforge.player.SourceKind

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        handleIntent(intent)
        setContent { StreamForgeTheme { Root() } }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    /** magnet: links and stremio:// addon links. */
    private fun handleIntent(intent: Intent?) {
        val data = intent?.data?.toString() ?: return
        when {
            data.startsWith("magnet:") -> TorrentSource.parse(data)?.let { t ->
                Player.play(this, PlaybackRequest(
                    MediaItem("torrent:${t.infoHash}", MediaType.OTHER, t.title ?: "Torrent", origin = Origin("tmdb")),
                    source = PlaybackSource("magnet:${t.infoHash}", SourceKind.Torrent(t), t.title ?: "Torrent", provider = "Magnet")))
            }
            data.startsWith("stremio://") -> CoroutineScope(Dispatchers.Main).launch { runCatching { Addons.install(data) } }
        }
    }
}

private fun icon(tab: Tab): ImageVector = when (tab) {
    Tab.HOME -> Icons.Filled.Home
    Tab.LIVE -> Icons.Filled.LiveTv
    Tab.MOVIES -> Icons.Filled.Movie
    Tab.SERIES -> Icons.Filled.Tv
    Tab.SEARCH -> Icons.Filled.Search
    Tab.ACTIVITY -> Icons.Filled.CloudDownload
    Tab.SETTINGS -> Icons.Filled.Settings
}

@Composable
private fun Root() {
    val nav = remember { Navigator() }
    var tab by rememberSaveable { mutableStateOf(Tab.HOME) }
    val tv = isTv()
    val side = tv || isWide()
    val tabs = if (side) Tab.entries.toList() else listOf(Tab.HOME, Tab.LIVE, Tab.MOVIES, Tab.SERIES, Tab.ACTIVITY)

    BackHandler(enabled = nav.stack.isNotEmpty()) { nav.pop() }

    CompositionLocalProvider(LocalNav provides nav) {
        val content: @Composable () -> Unit = {
            Box(Modifier.fillMaxSize().background(Palette.background)) {
                val top = nav.stack.lastOrNull()
                if (top == null) {
                    when (tab) {
                        Tab.HOME -> HomeScreen(onSearch = { tab = Tab.SEARCH }, onSettings = { tab = Tab.SETTINGS })
                        Tab.LIVE -> LiveScreen()
                        Tab.MOVIES -> VodScreen(MediaType.MOVIE)
                        Tab.SERIES -> VodScreen(MediaType.SERIES)
                        Tab.SEARCH -> SearchScreen()
                        Tab.ACTIVITY -> ActivityScreen()
                        Tab.SETTINGS -> SettingsScreen()
                    }
                } else {
                    when (top) {
                        is Screen.Detail -> DetailScreen(top.item)
                        is Screen.Person -> PersonScreen(top.id, top.name)
                        is Screen.Collection -> CollectionScreen(top.id, top.name)
                        is Screen.Catalog -> CatalogScreen(top.entry)
                        is Screen.Category -> CategoryScreen(top.kind, top.categoryId, top.title)
                        Screen.Guide -> GuideScreen()
                        Screen.Recordings -> RecordingsScreen()
                    }
                }
            }
        }
        if (side) {
            Row(Modifier.fillMaxSize().background(Palette.background)) {
                NavigationRail(containerColor = Palette.background) {
                    tabs.forEach { t ->
                        NavigationRailItem(selected = tab == t && nav.stack.isEmpty(), onClick = { tab = t; nav.clear() },
                            icon = { Icon(icon(t), t.title) }, label = { Text(t.title, maxLines = 1, overflow = TextOverflow.Ellipsis) })
                    }
                }
                Box(Modifier.weight(1f).safeDrawingPadding()) { content() }
            }
        } else {
            Scaffold(
                containerColor = Palette.background,
                bottomBar = {
                    NavigationBar(containerColor = Palette.background) {
                        tabs.forEach { t ->
                            NavigationBarItem(selected = tab == t && nav.stack.isEmpty(), onClick = { tab = t; nav.clear() },
                                icon = { Icon(icon(t), t.title) }, label = { Text(t.title, maxLines = 1) })
                        }
                    }
                },
            ) { padding -> Box(Modifier.fillMaxSize().background(Palette.background).padding(padding)) { content() } }
        }
    }
}
