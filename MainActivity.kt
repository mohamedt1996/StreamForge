package com.mohamedt.streamforge

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.KeyEvent
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CloudDownload
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusRestorer
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.MediaType
import com.mohamedt.streamforge.core.Origin
import com.mohamedt.streamforge.player.PlaybackRequest
import com.mohamedt.streamforge.player.PlaybackSource
import com.mohamedt.streamforge.player.Player
import com.mohamedt.streamforge.player.SourceKind
import com.mohamedt.streamforge.stremio.Addons
import com.mohamedt.streamforge.torrent.TorrentSource
import com.mohamedt.streamforge.ui.DeviceInput
import com.mohamedt.streamforge.ui.Dims
import com.mohamedt.streamforge.ui.LocalFocusMemory
import com.mohamedt.streamforge.ui.LocalNav
import com.mohamedt.streamforge.ui.LocalTvShell
import com.mohamedt.streamforge.ui.Navigator
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.Screen
import com.mohamedt.streamforge.ui.StreamForgeTheme
import com.mohamedt.streamforge.ui.Tab
import com.mohamedt.streamforge.ui.TvShellFocus
import com.mohamedt.streamforge.ui.isMediumWidth
import com.mohamedt.streamforge.ui.isTv
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private var localNetworkWasGranted = false
    override fun onResume() {
        super.onResume()
        val granted = android.os.Build.VERSION.SDK_INT < 37 ||
            checkSelfPermission("android.permission.ACCESS_LOCAL_NETWORK") == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (granted && !localNetworkWasGranted) {
            com.mohamedt.streamforge.dispatcharr.DispatcharrRepo.refreshAll(force = true)
        }
        localNetworkWasGranted = granted
    }

    private val localNetworkPermission = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted) {
            com.mohamedt.streamforge.dispatcharr.DispatcharrRepo.refreshAll(force = true)
            com.mohamedt.streamforge.dispatcharr.GuideRepo.refresh()
        } else {
            android.widget.Toast.makeText(this,
                "Local servers need Nearby devices access. You can enable it in Android Settings > Apps > StreamForge > Permissions.",
                android.widget.Toast.LENGTH_LONG).show()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The UI is always dark: keep light status/navigation bar icons even when the system is in light mode.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        DeviceInput.init(this)
        handleIntent(intent)
        val permissionPrefs = getSharedPreferences("network-permission", MODE_PRIVATE)
        if (android.os.Build.VERSION.SDK_INT >= 37 &&
            checkSelfPermission("android.permission.ACCESS_LOCAL_NETWORK") != android.content.pm.PackageManager.PERMISSION_GRANTED &&
            !permissionPrefs.getBoolean("requested", false)) {
            permissionPrefs.edit().putBoolean("requested", true).apply()
            localNetworkPermission.launch("android.permission.ACCESS_LOCAL_NETWORK")
        }
        setContent {
            StreamForgeTheme {
                Root()
                // "Set up by your server" questions from the sync server (admin-managed items).
                com.mohamedt.streamforge.sync.ManagedSyncPrompts()
            }
        }
    }

    /** Remote D-pad input switches "Automatic" to the TV interface (TV boxes that don't say they're TVs). */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        DeviceInput.onKey(event)
        return super.dispatchKeyEvent(event)
    }

    /** A finger on the screen switches "Automatic" back to the touch interface. */
    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        DeviceInput.onTouch(ev)
        return super.dispatchTouchEvent(ev)
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
    val select: (Tab) -> Unit = { t -> tab = t; nav.clear() }

    CompositionLocalProvider(LocalNav provides nav) {
        if (tv) {
            TvRoot(nav, tab, select)
        } else {
            PhoneRoot(nav, tab, rail = isMediumWidth(), select = select)
        }
    }
}

// MARK: Phone / tablet

/** Phones in portrait: bottom bar with the five main tabs. Tablets and landscape: a navigation rail with all of them. */
@Composable
private fun PhoneRoot(nav: Navigator, tab: Tab, rail: Boolean, select: (Tab) -> Unit) {
    BackHandler(enabled = nav.stack.isNotEmpty()) { nav.pop() }
    // Back on another tab returns Home first, like most streaming apps.
    BackHandler(enabled = nav.stack.isEmpty() && tab != Tab.HOME) { select(Tab.HOME) }
    val atRoot = nav.stack.isEmpty()
    if (rail) {
        Row(Modifier.fillMaxSize().background(Palette.background)) {
            NavigationRail(
                containerColor = Palette.background,
                windowInsets = WindowInsets.safeDrawing.only(WindowInsetsSides.Vertical + WindowInsetsSides.Start),
                header = { AppMark(Modifier.padding(top = 8.dp, bottom = 4.dp)) },
            ) {
                val colors = NavigationRailItemDefaults.colors(
                    selectedIconColor = Color.White,
                    selectedTextColor = Color.White,
                    indicatorColor = Palette.accent.copy(alpha = 0.34f),
                    unselectedIconColor = Palette.secondary,
                    unselectedTextColor = Palette.secondary,
                )
                Spacer(Modifier.weight(1f))
                Tab.entries.filter { it != Tab.SETTINGS }.forEach { t ->
                    NavigationRailItem(selected = tab == t && atRoot, onClick = { select(t) }, colors = colors,
                        icon = { Icon(icon(t), null) }, label = { Text(t.title, maxLines = 1, overflow = TextOverflow.Ellipsis) })
                }
                Spacer(Modifier.weight(1f))
                NavigationRailItem(selected = tab == Tab.SETTINGS && atRoot, onClick = { select(Tab.SETTINGS) }, colors = colors,
                    icon = { Icon(icon(Tab.SETTINGS), null) }, label = { Text(Tab.SETTINGS.title, maxLines = 1) },
                    modifier = Modifier.padding(bottom = 8.dp))
            }
            Box(
                Modifier.weight(1f).fillMaxHeight().background(Palette.background)
                    .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Bottom + WindowInsetsSides.End)),
            ) { TouchFrame(nav) { ScreenContent(nav, tab, select) } }
        }
    } else {
        val tabs = listOf(Tab.HOME, Tab.LIVE, Tab.MOVIES, Tab.SERIES, Tab.ACTIVITY)
        Scaffold(
            containerColor = Palette.background,
            bottomBar = {
                NavigationBar(containerColor = Palette.raised.copy(alpha = 0.96f), tonalElevation = 0.dp) {
                    val colors = NavigationBarItemDefaults.colors(
                        selectedIconColor = Color.White,
                        selectedTextColor = Color.White,
                        indicatorColor = Palette.accent.copy(alpha = 0.34f),
                        unselectedIconColor = Palette.secondary,
                        unselectedTextColor = Palette.secondary,
                    )
                    tabs.forEach { t ->
                        NavigationBarItem(selected = tab == t && atRoot, onClick = { select(t) }, colors = colors,
                            icon = { Icon(icon(t), null) }, label = { Text(t.title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 11.sp) })
                    }
                }
            },
        ) { padding ->
            Box(Modifier.fillMaxSize().background(Palette.background).padding(padding)) {
                TouchFrame(nav) { ScreenContent(nav, tab, select) }
            }
        }
    }
}

/** Gradient "S" mark used at the top of the navigation rails. */
@Composable
private fun AppMark(modifier: Modifier = Modifier) {
    Box(modifier.size(40.dp).clip(RoundedCornerShape(11.dp)).background(Palette.gradient), contentAlignment = Alignment.Center) {
        Text("S", fontSize = 22.sp, fontWeight = FontWeight.Black, color = Color.White)
    }
}

/**
 * Touch: pushed pages get a visible way back (gesture navigation alone isn't discoverable).
 * Detail pages float the button over their artwork; other pages get a slim bar.
 */
@Composable
private fun TouchFrame(nav: Navigator, content: @Composable () -> Unit) {
    val top = nav.stack.lastOrNull()
    when {
        top == null -> content()
        top is Screen.Detail -> Box(Modifier.fillMaxSize()) {
            content()
            BackButton(floating = true, modifier = Modifier.align(Alignment.TopStart).padding(8.dp)) { nav.pop() }
        }
        else -> Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().height(48.dp).padding(start = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                BackButton(floating = false) { nav.pop() }
            }
            Box(Modifier.weight(1f).fillMaxWidth()) { content() }
        }
    }
}

@Composable
private fun BackButton(floating: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    IconButton(onClick = onClick, modifier = modifier.size(48.dp)) {
        Box(
            Modifier.size(40.dp).clip(CircleShape).background(if (floating) Color.Black.copy(alpha = 0.45f) else Color.Transparent),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = Color.White)
        }
    }
}

/**
 * The current tab or pushed screen. Each one keeps its saveable state (scroll positions) and its
 * focus memory while it is covered, so Back returns to the same row and the same card.
 */
@Composable
private fun ScreenContent(nav: Navigator, tab: Tab, select: (Tab) -> Unit) {
    val holder = rememberSaveableStateHolder()
    val top = nav.stack.lastOrNull()
    val key = if (top == null) "tab:${tab.name}" else "stack:${nav.stack.size}:${top.hashCode()}"
    val memory = nav.memory(key)
    LaunchedEffect(key) { memory.beginRestore() }
    CompositionLocalProvider(LocalFocusMemory provides memory) {
        holder.SaveableStateProvider(key) {
            Box(Modifier.fillMaxSize()) {
                if (top == null) {
                    when (tab) {
                        Tab.HOME -> HomeScreen(onSearch = { select(Tab.SEARCH) }, onSettings = { select(Tab.SETTINGS) })
                        Tab.LIVE -> LiveScreen()
                        Tab.MOVIES -> VodScreen(MediaType.MOVIE)
                        Tab.SERIES -> VodScreen(MediaType.SERIES)
                        Tab.SEARCH -> SearchScreen()
                        Tab.ACTIVITY -> ActivityScreen()
                        Tab.SETTINGS -> SettingsScreen()
                    }
                } else {
                    when (top) {
                        is Screen.Detail -> DetailScreen(top.item, top.autoPlay)
                        is Screen.Person -> PersonScreen(top.id, top.name, top.photo)
                        is Screen.Collection -> CollectionScreen(top.id, top.name)
                        is Screen.Catalog -> CatalogScreen(top.entry)
                        is Screen.Category -> CategoryScreen(top.kind, top.categoryId, top.title)
                        Screen.Guide -> GuideScreen()
                        Screen.Recordings -> RecordingsScreen()
                    }
                }
            }
        }
    }
}

// MARK: TV

private val RailCollapsed = 76.dp
private val RailExpanded = 248.dp
private val railOrder = listOf(Tab.SEARCH, Tab.HOME, Tab.LIVE, Tab.MOVIES, Tab.SERIES, Tab.ACTIVITY)

/**
 * 10-foot shell: a slim icon rail on the left that widens to show labels while it has focus and
 * slides back when focus moves into the content. Back from the content goes to the rail; Back on
 * the rail goes Home, and from Home asks for a second press before leaving the app.
 * Pushed pages (details, guide, catalogs) are full screen without the rail.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun TvRoot(nav: Navigator, tab: Tab, select: (Tab) -> Unit) {
    val context = LocalContext.current
    val railVisible = nav.stack.isEmpty()
    val shell = remember { TvShellFocus() }
    val requesters = remember { Tab.entries.associateWith { FocusRequester() } }
    var exitArmed by remember { mutableStateOf(false) }
    val contentFocus = remember { FocusRequester() }
    // Safety net: a page that didn't place focus (or lost it when its focused element went away)
    // gets it on its first focusable element, so the remote always has something to move.
    val screenKey = "${tab.name}:${nav.stack.size}:${nav.stack.lastOrNull()?.hashCode()}"
    LaunchedEffect(screenKey, shell.content, shell.rail) {
        if (shell.content || shell.rail) return@LaunchedEffect
        delay(1200)
        runCatching { contentFocus.requestFocus() }
    }
    LaunchedEffect(exitArmed) {
        if (exitArmed) {
            delay(2500)
            exitArmed = false
        }
    }

    BackHandler {
        when {
            nav.stack.isNotEmpty() -> nav.pop()
            !shell.rail -> runCatching { requesters.getValue(tab).requestFocus() }
            tab != Tab.HOME -> select(Tab.HOME)
            exitArmed -> (context as? Activity)?.finish()
            else -> exitArmed = true
        }
    }

    CompositionLocalProvider(LocalTvShell provides shell) {
        Box(Modifier.fillMaxSize().background(Palette.background)) {
            Box(
                Modifier.fillMaxSize()
                    .padding(start = if (railVisible) RailCollapsed - 36.dp else 0.dp)
                    .onFocusChanged { shell.content = it.hasFocus }
                    .focusRequester(contentFocus)
                    .focusRestorer(FocusRequester.Default)
                    .focusGroup(),
            ) {
                ScreenContent(nav, tab, select)
            }
            if (railVisible) {
                // Dims the page while the rail is open.
                val dim by animateFloatAsState(if (shell.rail) 0.55f else 0f, tween(220), label = "rail-dim")
                if (dim > 0.01f) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = dim)))
                TvRail(tab, requesters, onFocusChange = { f -> shell.rail = f; if (!f) exitArmed = false }, onSelect = select)
            }
            AnimatedVisibility(exitArmed, enter = fadeIn(tween(160)), exit = fadeOut(tween(220)), modifier = Modifier.align(Alignment.BottomCenter)) {
                Text("Press Back again to exit", fontSize = 18.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(bottom = 40.dp)
                        .clip(RoundedCornerShape(percent = 50)).background(Palette.raised).padding(horizontal = 26.dp, vertical = 12.dp))
            }
        }
    }
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun TvRail(selected: Tab, requesters: Map<Tab, FocusRequester>, onFocusChange: (Boolean) -> Unit, onSelect: (Tab) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val width by animateDpAsState(if (expanded) RailExpanded else RailCollapsed, tween(240), label = "rail-width")
    val fade by animateFloatAsState(if (expanded) 0.97f else 0f, tween(240), label = "rail-fade")
    Column(
        Modifier.fillMaxHeight().width(width)
            .background(Brush.horizontalGradient(
                0f to Palette.background.copy(alpha = 0.9f),
                0.6f to Palette.background.copy(alpha = maxOf(0.55f, fade)),
                1f to Palette.background.copy(alpha = fade * 0.9f),
            ))
            .onFocusChanged { s ->
                if (s.hasFocus != expanded) {
                    expanded = s.hasFocus
                    onFocusChange(s.hasFocus)
                }
            }
            .focusRestorer(requesters.getValue(selected))
            .padding(horizontal = 14.dp, vertical = Dims.overscanY),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        RailMark(expanded)
        Spacer(Modifier.weight(1f))
        railOrder.forEach { t -> RailItem(t, t == selected, expanded, requesters.getValue(t)) { onSelect(t) } }
        Spacer(Modifier.weight(1f))
        RailItem(Tab.SETTINGS, Tab.SETTINGS == selected, expanded, requesters.getValue(Tab.SETTINGS)) { onSelect(Tab.SETTINGS) }
    }
}

@Composable
private fun RailMark(expanded: Boolean) {
    Row(Modifier.height(48.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
            Box(Modifier.size(34.dp).clip(RoundedCornerShape(10.dp)).background(Palette.gradient), contentAlignment = Alignment.Center) {
                Text("S", fontSize = 20.sp, fontWeight = FontWeight.Black, color = Color.White)
            }
        }
        AnimatedVisibility(expanded, enter = fadeIn(tween(180, delayMillis = 60)), exit = fadeOut(tween(90))) {
            Text("StreamForge", fontSize = 20.sp, fontWeight = FontWeight.Black, maxLines = 1, softWrap = false,
                modifier = Modifier.padding(start = 10.dp))
        }
    }
}

@Composable
private fun RailItem(tab: Tab, selected: Boolean, expanded: Boolean, requester: FocusRequester, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(percent = 50)
    val tint = when {
        focused -> Palette.onFocus
        selected -> Color.White
        else -> Color.White.copy(alpha = 0.62f)
    }
    Row(
        Modifier.fillMaxWidth().height(48.dp)
            .focusRequester(requester)
            .onFocusChanged { focused = it.isFocused }
            .clip(shape)
            .then(
                when {
                    focused -> Modifier.background(Color.White)
                    selected -> Modifier.background(Palette.gradient, alpha = 0.4f)
                    else -> Modifier
                },
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon(tab), tab.title, tint = tint, modifier = Modifier.size(24.dp))
        AnimatedVisibility(expanded, enter = fadeIn(tween(180, delayMillis = 60)), exit = fadeOut(tween(90))) {
            Text(tab.title, fontSize = 19.sp, fontWeight = if (selected || focused) FontWeight.Bold else FontWeight.Medium, color = tint,
                maxLines = 1, softWrap = false, modifier = Modifier.padding(start = 16.dp))
        }
    }
}
