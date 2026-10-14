package com.mohamedt.streamforge.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.mohamedt.streamforge.core.Settings
import com.mohamedt.streamforge.core.byteText
import com.mohamedt.streamforge.core.SettingsValues
import com.mohamedt.streamforge.dispatcharr.AuthMode
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.dispatcharr.GuideRepo
import com.mohamedt.streamforge.dispatcharr.Server
import com.mohamedt.streamforge.stremio.Addons
import com.mohamedt.streamforge.sync.ServerSync
import com.mohamedt.streamforge.sync.SyncDevice
import com.mohamedt.streamforge.torrent.TorrServer
import com.mohamedt.streamforge.ui.Chip
import com.mohamedt.streamforge.ui.Dims
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.card
import com.mohamedt.streamforge.ui.isTv
import kotlinx.coroutines.launch

@Composable
private fun Section(title: String, footer: String? = null, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().widthIn(max = 900.dp).padding(vertical = 8.dp)) {
        Text(title.uppercase(), fontSize = 12.sp, fontWeight = FontWeight.Bold, color = Palette.secondary, modifier = Modifier.padding(bottom = 6.dp))
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Palette.surface).padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            content()
        }
        footer?.let { Text(it, fontSize = 12.sp, color = Palette.secondary, modifier = Modifier.padding(top = 6.dp)) }
    }
}

@Composable
private fun Toggle(label: String, value: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().card({ onChange(!value) }).padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Switch(checked = value, onCheckedChange = onChange)
    }
}

@Composable
private fun <T> Choice(label: String, options: List<Pair<T, String>>, value: T, onChange: (T) -> Unit) {
    Column {
        Text(label)
        Row(Modifier.horizontalScroll(rememberScrollState()).padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            options.forEach { (v, name) -> Chip(name, v == value) { onChange(v) } }
        }
    }
}

@Composable
private fun Field(label: String, value: String, secret: Boolean = false, onChange: (String) -> Unit) {
    OutlinedTextField(value, onChange, Modifier.fillMaxWidth(), label = { Text(label) }, singleLine = true,
        visualTransformation = if (secret) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        keyboardOptions = if (secret) KeyboardOptions(keyboardType = KeyboardType.Password) else KeyboardOptions.Default)
}

private fun upd(f: (SettingsValues) -> SettingsValues) = Settings.update(f)

@Composable
fun SettingsScreen() {
    val s = Settings.values
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(Dims.gutter())) {
        item { Text("Settings", fontSize = 26.sp, fontWeight = FontWeight.Bold) }
        item { SyncServerSection() }
        item { DispatcharrSection() }
        item { AddonsSection() }
        item {
            Section("Torrent streaming", if (TorrServer.embeddedAvailable) "“On this device” runs TorrServer inside the app. “Remote” uses a TorrServer on your network or seedbox." else "This build has no on-device engine; use a TorrServer on your network.") {
                if (TorrServer.embeddedAvailable) Toggle("Use the on-device engine", s.torrentEmbedded) { v -> upd { it.copy(torrentEmbedded = v) } }
                if (!TorrServer.embedded) {
                    var url by remember { mutableStateOf(s.remoteTorrServer) }
                    var user by remember { mutableStateOf(s.torrServerUser) }
                    var pass by remember { mutableStateOf(Settings.torrServerPassword) }
                    Field("TorrServer address, e.g. http://192.168.1.10:8090", url) { url = it; upd { v -> v.copy(remoteTorrServer = it) } }
                    Field("Username (optional)", user) { user = it; upd { v -> v.copy(torrServerUser = it) } }
                    Field("Password (optional)", pass, secret = true) { pass = it; Settings.torrServerPassword = it }
                } else {
                    Choice("RAM cache", listOf(128 to "128 MB", 256 to "256 MB", 512 to "512 MB", 1024 to "1 GB"), s.torrCacheMb) { v -> upd { it.copy(torrCacheMb = v) } }
                }
            }
        }
        item {
            Section("Metadata", "A free TMDB key (themoviedb.org) adds artwork, cast, trailers, trending, collections and person pages.") {
                var key by remember { mutableStateOf(Settings.tmdbKey) }
                Field("TMDB API key or read token", key, secret = true) { key = it; Settings.tmdbKey = it }
                Field("Language (ISO code)", s.metadataLanguage) { v -> upd { it.copy(metadataLanguage = v) } }
                Toggle("Hide adult content", s.hideAdult) { v -> upd { it.copy(hideAdult = v) } }
            }
        }
        item {
            Section("Player") {
                Choice("Decoding", listOf("mediacodec" to "Hardware", "mediacodec-copy" to "Hardware (compatible)", "no" to "Software"), s.hwdec) { v -> upd { it.copy(hwdec = v) } }
                Choice("Skip interval", listOf(5 to "5s", 10 to "10s", 15 to "15s", 30 to "30s"), s.seekStep) { v -> upd { it.copy(seekStep = v) } }
                Toggle("Autoplay next episode", s.autoplayNext) { v -> upd { it.copy(autoplayNext = v) } }
                Toggle("Show “Skip Intro” (TheIntroDB, chapters, your markers)", s.skipIntros) { v -> upd { it.copy(skipIntros = v) } }
                Toggle("Skip intros automatically", s.autoSkip) { v -> upd { it.copy(autoSkip = v) } }
                Toggle("Night mode (compress loud scenes)", s.nightMode) { v -> upd { it.copy(nightMode = v) } }
                Choice("Live rewind buffer", listOf(0 to "Off", 15 to "15 min", 30 to "30 min", 60 to "60 min"), s.timeshiftMinutes) { v -> upd { it.copy(timeshiftMinutes = v) } }
                Choice("Maximum quality", listOf(2160 to "4K", 1080 to "1080p", 720 to "720p"), s.maxResolution) { v -> upd { it.copy(maxResolution = v) } }
                Toggle("Hide CAM / telesync releases", s.excludeCam) { v -> upd { it.copy(excludeCam = v) } }
                Toggle("Play trailers on detail pages (never on mobile data)", s.trailerAutoplay) { v -> upd { it.copy(trailerAutoplay = v) } }
                Field("Preferred audio language", s.audioLanguage) { v -> upd { it.copy(audioLanguage = v) } }
                Field("Preferred subtitle language", s.subtitleLanguage) { v -> upd { it.copy(subtitleLanguage = v) } }
                Toggle("Turn on subtitles automatically", s.autoSubtitles) { v -> upd { it.copy(autoSubtitles = v) } }
                Field("Custom User-Agent (optional)", s.userAgent) { v -> upd { it.copy(userAgent = v) } }
            }
        }
        item { SpeedSection() }
        item {
            Section("Subtitle style") {
                Choice("Size", listOf(0.8f to "Small", 1.0f to "Normal", 1.25f to "Large", 1.5f to "Huge"), s.subtitleScale) { v -> upd { it.copy(subtitleScale = v) } }
                Choice("Colour", listOf("#FFFFFFFF" to "White", "#FFFFE45C" to "Yellow", "#FF7CF0FF" to "Cyan", "#FFB7FF8A" to "Green"), s.subtitleColor) { v -> upd { it.copy(subtitleColor = v) } }
                Toggle("Background box", s.subtitleBackground) { v -> upd { it.copy(subtitleBackground = v) } }
                Toggle("Bold", s.subtitleBold) { v -> upd { it.copy(subtitleBold = v) } }
                Choice("Position", listOf(100 to "Bottom", 92 to "Raised", 80 to "Higher"), s.subtitlePosition) { v -> upd { it.copy(subtitlePosition = v) } }
            }
        }
        item {
            Section("Live TV") {
                Toggle("Show channel numbers", s.showChannelNumbers) { v -> upd { it.copy(showChannelNumbers = v) } }
                Choice("Guide days", listOf(1 to "1 day", 3 to "3 days", 7 to "7 days"), s.guideDays) { v -> upd { it.copy(guideDays = v) } }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(if (GuideRepo.updatedAt > 0) "Guide: ${GuideRepo.programmeCount} programmes, updated ${timeText(GuideRepo.updatedAt)}" else "Guide not downloaded yet",
                        Modifier.weight(1f), fontSize = 13.sp, color = Palette.secondary)
                    TextButton(onClick = { GuideRepo.refresh() }) { Text(if (GuideRepo.refreshing) "Updating…" else "Refresh guide") }
                }
                GuideRepo.lastError?.let { Text(it, color = Palette.live, fontSize = 12.sp) }
            }
        }
        item {
            Section("About") {
                Text("StreamForge for Android · ${com.mohamedt.streamforge.BuildConfig.VERSION_NAME}")
                Text("Player: libmpv · Torrents: TorrServer", color = Palette.secondary, fontSize = 13.sp)
                Text("StreamForge plays content from servers and addons you configure. It doesn't host or provide any content.", color = Palette.secondary, fontSize = 12.sp)
            }
        }
        item { Spacer(Modifier.height(40.dp)) }
    }
}

@Composable
private fun DispatcharrSection() {
    val scope = rememberCoroutineScope()
    var adding by remember { mutableStateOf(DispatcharrRepo.servers.isEmpty()) }
    var mode by remember { mutableStateOf(AuthMode.ACCOUNT) }
    var url by remember { mutableStateOf("") }
    var user by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var apiKey by remember { mutableStateOf("") }
    var xc by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }

    Section("Dispatcharr", "Account login uses your Dispatcharr username and password (or an API key); no XC password is needed. If your user has one, the app reads it automatically (admins get one created) and uses Xtream Codes, including catch-up. Without one, live TV, the guide, movies, series and DVR come through Dispatcharr's own API.") {
        DispatcharrRepo.servers.forEach { server ->
            Row(Modifier.fillMaxWidth().card({ DispatcharrRepo.activate(server.id) }).padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(server.name + if (server.id == DispatcharrRepo.active?.id) "  ✓" else "", fontWeight = FontWeight.Bold)
                    Text("${server.username} @ ${server.baseUrl} · ${server.authMode.name.lowercase().replace('_', ' ')}" +
                        if (server.usesRestStreaming) " · API streaming (no catch-up)" else "", fontSize = 12.sp, color = Palette.secondary)
                }
                TextButton(onClick = { DispatcharrRepo.remove(server) }) { Text("Remove", color = Palette.live) }
            }
        }
        if (DispatcharrRepo.isConfigured) {
            Text("${DispatcharrRepo.channels.size} channels · ${DispatcharrRepo.movieItems.size} movies · ${DispatcharrRepo.seriesItems.size} series",
                fontSize = 13.sp, color = Palette.secondary)
            Row {
                TextButton(onClick = { DispatcharrRepo.refreshAll(true) }) { Text("Refresh library") }
                TextButton(onClick = { adding = !adding }) { Text(if (adding) "Cancel" else "Add server") }
            }
        }
        if (adding) {
            Choice("Sign in with", listOf(AuthMode.ACCOUNT to "Account", AuthMode.API_KEY to "API key", AuthMode.XC to "XC credentials"), mode) { mode = it }
            Field("Address, e.g. http://192.168.1.10:9191", url) { url = it }
            if (mode != AuthMode.API_KEY) Field("Username", user) { user = it }
            when (mode) {
                AuthMode.ACCOUNT -> Field("Password", password, secret = true) { password = it }
                AuthMode.API_KEY -> Field("API key", apiKey, secret = true) { apiKey = it }
                AuthMode.XC -> {
                    Field("XC password", xc, secret = true) { xc = it }
                    Field("Web password (optional, for DVR)", password, secret = true) { password = it }
                }
            }
            Button(enabled = !busy && url.isNotBlank(), colors = ButtonDefaults.buttonColors(containerColor = Palette.accent), onClick = {
                busy = true
                message = null
                scope.launch {
                    val draft = Server(name = com.mohamedt.streamforge.core.normalizedBase(url)?.substringAfter("://")?.substringBefore(":") ?: "Dispatcharr",
                        baseUrl = url.trim(), username = user.trim(), authMode = mode)
                    message = runCatching { DispatcharrRepo.connect(draft, xc, password, apiKey) }.fold({ adding = false; it }, { it.message ?: "Couldn't connect" })
                    busy = false
                }
            }) { Text(if (busy) "Connecting…" else "Connect") }
        }
        message?.let { Text(it, color = Palette.accent, fontSize = 13.sp) }
    }
}

@Composable
private fun AddonsSection() {
    val scope = rememberCoroutineScope()
    var url by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    Section("Stremio addons", "Paste any addon manifest link (https://…/manifest.json or stremio://…). Configure addons on their website first, then paste the configured link. Addons higher in the list are asked first.") {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(url, { url = it }, Modifier.weight(1f), placeholder = { Text("Addon URL") }, singleLine = true)
            TextButton(onClick = {
                scope.launch { message = runCatching { Addons.install(url) }.fold({ url = ""; "Installed ${it.name}" }, { it.message ?: "Couldn't install" }) }
            }) { Text("Install") }
        }
        message?.let { Text(it, color = Palette.accent, fontSize = 13.sp) }
        Addons.addons.forEach { a ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(a.name, fontWeight = FontWeight.Bold)
                    Text(listOfNotNull(if (a.catalogs.isNotEmpty()) "Catalogs" else null, if (a.hasStreams) "Streams" else null,
                        if (a.hasSubtitles) "Subtitles" else null).joinToString(" · ") + (a.version?.let { "  v$it" } ?: ""), fontSize = 12.sp, color = Palette.secondary)
                }
                TextButton(onClick = { Addons.move(a, true) }) { Text("↑") }
                TextButton(onClick = { Addons.move(a, false) }) { Text("↓") }
                Switch(checked = a.enabled, onCheckedChange = { Addons.setEnabled(a, it) })
                TextButton(onClick = { Addons.remove(a) }) { Text("✕", color = Palette.live) }
            }
        }
    }
}

@Composable
fun RecordingsScreen() {
    val context = androidx.compose.ui.platform.LocalContext.current
    var list by remember { mutableStateOf<List<com.mohamedt.streamforge.dispatcharr.DispatcharrRest.Recording>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        val rest = DispatcharrRepo.restClient()
        if (rest == null) error = "Sign in with your Dispatcharr account to see recordings."
        else runCatching { rest.recordings() }.onSuccess { list = it }.onFailure { error = it.message }
    }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(Dims.gutter()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Text("Recordings", fontSize = 26.sp, fontWeight = FontWeight.Bold) }
        error?.let { item { Text(it, color = Palette.live) } }
        items(list, key = { it.id }) { r ->
            val upcoming = r.start > System.currentTimeMillis()
            Row(Modifier.fillMaxWidth().card({
                if (!upcoming) com.mohamedt.streamforge.player.Player.play(context, com.mohamedt.streamforge.player.PlaybackRequest(
                    com.mohamedt.streamforge.core.MediaItem("recording:${r.id}", com.mohamedt.streamforge.core.MediaType.OTHER, r.title,
                        origin = com.mohamedt.streamforge.core.Origin("recording", r.id)),
                    source = com.mohamedt.streamforge.player.PlaybackSource("rec:${r.id}", com.mohamedt.streamforge.player.SourceKind.Recording(r.id), r.title, provider = "DVR")))
            }).background(Palette.surface).padding(12.dp)) {
                Column(Modifier.weight(1f)) {
                    Text(r.title, fontWeight = FontWeight.SemiBold)
                    Text((if (upcoming) "Scheduled · " else "") + java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.MEDIUM, java.text.DateFormat.SHORT).format(java.util.Date(r.start)),
                        fontSize = 12.sp, color = Palette.secondary)
                }
            }
        }
    }
}


/** What the source start-time estimates are based on, with a manual speed test. */
@Composable
private fun SpeedSection() {
    val est = com.mohamedt.streamforge.torrent.StartEstimator
    @Suppress("UNUSED_VARIABLE") val v = est.version
    val scope = rememberCoroutineScope()
    var testing by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    val key = est.profileKey(false)
    val tKey = est.profileKey(true)
    Section("Start-time estimates", "Sources show how fast they should start and warn when they may buffer, using seeders, file size, your connection and speeds learned from what you play on each network. The test downloads about 27 MB.") {
        Text("Network: ${key.replaceFirstChar { it.uppercase() }}", color = Palette.secondary)
        Text("Connection speed: " + (est.capacity(key)?.let { "${Math.round(it * 8 / 1e6)} Mbps (${it.toLong().byteText()}/s)" } ?: "Not measured yet"),
            color = Palette.secondary)
        if (est.sessions(tKey) > 0) Text("Torrent sessions learned: ${est.sessions(tKey)}", color = Palette.secondary)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 6.dp)) {
            Button(onClick = {
                testing = true; failed = false
                scope.launch { failed = est.runSpeedTest() == null; testing = false }
            }, enabled = !testing) { Text(if (testing) "Testing…" else "Test connection speed") }
            TextButton(onClick = { est.reset() }) { Text("Reset learned speeds") }
        }
        if (failed) Text("Speed test failed. Check your connection.", color = androidx.compose.ui.graphics.Color(0xFFF87171), fontSize = 12.sp)
    }
}

// MARK: Sync server

private enum class SyncPanel { DEVICES, APPROVE, PASSWORD }

private fun dateTimeText(ms: Long): String =
    java.text.DateFormat.getDateTimeInstance(java.text.DateFormat.MEDIUM, java.text.DateFormat.SHORT).format(java.util.Date(ms))

private fun platformLabel(platform: String): String = when (platform) {
    "ios" -> "iPhone"
    "ipados" -> "iPad"
    "tvos" -> "Apple TV"
    "android" -> "Android"
    "androidtv" -> "Android TV"
    "web" -> "Web"
    else -> platform
}

private const val SYNC_FOOTER = "Keeps Continue Watching, watched marks, favourites, addons, Dispatcharr servers and settings in step " +
    "across your devices through your own StreamForge sync server. Everything also stays on this device, and signing out keeps it."

@Composable
private fun SyncServerSection() {
    if (ServerSync.signedIn) SyncSignedIn() else SyncSignIn()
}

@Composable
private fun SyncSignIn() {
    val tv = isTv()
    val scope = rememberCoroutineScope()
    var url by remember { mutableStateOf(ServerSync.serverUrl) }
    // TVs default to the pairing code (no typing a password with a remote).
    var pairMode by remember { mutableStateOf(tv) }
    var user by remember { mutableStateOf(ServerSync.username) }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val pairing = ServerSync.pairing

    Section("Sync server", SYNC_FOOTER) {
        ServerSync.signOutReason?.let { Text(it, color = Palette.live, fontSize = 13.sp) }
        if (pairing != null) {
            Text("Pairing code", color = Palette.secondary)
            Text(pairing.code, fontSize = if (tv) 64.sp else 44.sp, fontWeight = FontWeight.Black, letterSpacing = 6.sp)
            Text("On your phone open StreamForge → Settings → Sync server → Approve a TV code, or open ${pairing.serverUrl} in a browser, sign in and approve the code there.",
                fontSize = 13.sp, color = Palette.secondary)
            Text(pairing.failed ?: "Waiting for approval…", color = if (pairing.failed != null) Palette.live else Palette.accent, fontSize = 13.sp)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (pairing.failed != null) {
                    Button(onClick = { ServerSync.startPairing(pairing.serverUrl) }, colors = ButtonDefaults.buttonColors(containerColor = Palette.accent)) {
                        Text("Get a new code")
                    }
                }
                TextButton(onClick = { ServerSync.cancelPairing() }) { Text("Cancel") }
            }
        } else {
            Field("Server address, e.g. http://192.168.1.10:8484", url) { url = it }
            if (pairMode) {
                Button(enabled = url.isNotBlank(), colors = ButtonDefaults.buttonColors(containerColor = Palette.accent),
                    onClick = { message = null; ServerSync.startPairing(url) }) { Text("Get a pairing code") }
            } else {
                Field("Username", user) { user = it }
                Field("Password", password, secret = true) { password = it }
                Button(enabled = !busy && url.isNotBlank() && user.isNotBlank() && password.isNotEmpty(),
                    colors = ButtonDefaults.buttonColors(containerColor = Palette.accent), onClick = {
                        busy = true
                        message = null
                        scope.launch {
                            message = runCatching { ServerSync.signIn(url, user, password) }
                                .fold({ password = ""; null }, { it.message ?: "Couldn't sign in" })
                            busy = false
                        }
                    }) { Text(if (busy) "Signing in…" else "Sign in") }
            }
            TextButton(onClick = { pairMode = !pairMode; message = null }) {
                Text(if (pairMode) "Sign in with username and password instead" else "Use a pairing code instead (approve it from another device)")
            }
        }
        (message ?: ServerSync.pairMessage)?.let { Text(it, color = Palette.live, fontSize = 13.sp) }
    }
}

@Composable
private fun SyncSignedIn() {
    val scope = rememberCoroutineScope()
    var panel by remember { mutableStateOf<SyncPanel?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    fun toggle(p: SyncPanel) {
        panel = if (panel == p) null else p
        message = null
    }

    Section("Sync server", SYNC_FOOTER) {
        Text("Signed in as ${ServerSync.username}" + if (ServerSync.userRole == "admin") " (admin)" else "", fontWeight = FontWeight.Bold)
        Text("${ServerSync.serverName.ifEmpty { ServerSync.serverUrl }} · this device: ${ServerSync.deviceName}", fontSize = 12.sp, color = Palette.secondary)
        Text("Status: ${ServerSync.status}", fontSize = 13.sp)
        Text("Last sync: " + if (ServerSync.lastSyncAt > 0) dateTimeText(ServerSync.lastSyncAt) else "never", fontSize = 13.sp, color = Palette.secondary)
        if (!ServerSync.canReadSecrets) {
            Text("This device doesn't send or receive passwords and API keys (no secrets access).", fontSize = 12.sp, color = Palette.secondary)
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Button(onClick = { ServerSync.syncNow() }, colors = ButtonDefaults.buttonColors(containerColor = Palette.accent)) { Text("Sync now") }
            TextButton(onClick = { toggle(SyncPanel.DEVICES) }) { Text("Devices") }
            TextButton(onClick = { toggle(SyncPanel.APPROVE) }) { Text("Approve a TV code") }
            TextButton(onClick = { toggle(SyncPanel.PASSWORD) }) { Text("Change password") }
            TextButton(onClick = { scope.launch { ServerSync.signOut() } }) { Text("Sign out", color = Palette.live) }
        }
        when (panel) {
            SyncPanel.DEVICES -> SyncDevicesPanel()
            SyncPanel.APPROVE -> SyncApprovePanel()
            SyncPanel.PASSWORD -> SyncPasswordPanel { done -> panel = null; message = done }
            null -> Unit
        }
        message?.let { Text(it, color = Palette.accent, fontSize = 13.sp) }
    }
}

@Composable
private fun SyncDevicesPanel() {
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<String?>(null) }
    var newName by remember { mutableStateOf("") }
    var confirmRevoke by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        error = runCatching { ServerSync.loadDevices() }.exceptionOrNull()?.message
        loaded = true
    }
    if (!loaded) Text("Loading devices…", color = Palette.secondary, fontSize = 13.sp)
    ServerSync.devices.forEach { d: SyncDevice ->
        val isThis = d.current || d.id == ServerSync.deviceId
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(Palette.surface).padding(10.dp)) {
            Text(d.name + if (isThis) "  (this device)" else "", fontWeight = FontWeight.Bold)
            Text(listOfNotNull(platformLabel(d.platform), d.scopes.joinToString(" / ").ifEmpty { null },
                d.lastSeenAt.takeIf { it > 0 }?.let { "seen ${dateTimeText(it)}" }, d.lastIp).joinToString(" · "),
                fontSize = 12.sp, color = Palette.secondary)
            if (editing == d.id) {
                Field("Device name", newName) { newName = it }
                Row {
                    TextButton(onClick = {
                        scope.launch { error = runCatching { ServerSync.renameDevice(d.id, newName) }.fold({ editing = null; null }, { it.message }) }
                    }) { Text("Save") }
                    TextButton(onClick = { editing = null }) { Text("Cancel") }
                }
            } else {
                Row {
                    TextButton(onClick = { editing = d.id; newName = d.name; confirmRevoke = null }) { Text("Rename") }
                    TextButton(onClick = {
                        if (confirmRevoke != d.id) {
                            confirmRevoke = d.id
                        } else {
                            confirmRevoke = null
                            scope.launch { error = runCatching { ServerSync.revokeDevice(d.id) }.exceptionOrNull()?.message }
                        }
                    }) {
                        Text(if (confirmRevoke == d.id) "Press again to revoke" else if (isThis) "Revoke & sign out" else "Revoke", color = Palette.live)
                    }
                }
            }
        }
    }
    if (loaded && ServerSync.devices.isEmpty() && error == null) Text("No devices.", color = Palette.secondary, fontSize = 13.sp)
    error?.let { Text(it, color = Palette.live, fontSize = 13.sp) }
}

@Composable
private fun SyncApprovePanel() {
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf("") }
    var secrets by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<String?>(null) }
    Text("Enter the code your TV shows. The TV joins your account.", fontSize = 13.sp, color = Palette.secondary)
    Field("Code, e.g. K7Q-4MX", code) { code = it }
    Toggle("Also share passwords and API keys with it", secrets) { secrets = it }
    Button(enabled = !busy && code.isNotBlank(), colors = ButtonDefaults.buttonColors(containerColor = Palette.accent), onClick = {
        busy = true
        result = null
        scope.launch {
            result = runCatching { ServerSync.approvePairing(code, secrets) }.fold({ code = ""; it }, { it.message ?: "Couldn't approve the code" })
            busy = false
        }
    }) { Text(if (busy) "Approving…" else "Approve") }
    result?.let { Text(it, color = Palette.accent, fontSize = 13.sp) }
}

@Composable
private fun SyncPasswordPanel(onDone: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var current by remember { mutableStateOf("") }
    var new by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    Field("Current password", current, secret = true) { current = it }
    Field("New password", new, secret = true) { new = it }
    Field("Repeat new password", confirm, secret = true) { confirm = it }
    Button(enabled = !busy && current.isNotEmpty() && new.isNotEmpty(), colors = ButtonDefaults.buttonColors(containerColor = Palette.accent), onClick = {
        if (new != confirm) {
            error = "The new passwords don't match"
        } else {
            busy = true
            error = null
            scope.launch {
                runCatching { ServerSync.changePassword(current, new) }
                    .onSuccess { onDone("Password changed") }
                    .onFailure { error = it.message ?: "Couldn't change the password" }
                busy = false
            }
        }
    }) { Text(if (busy) "Saving…" else "Change password") }
    error?.let { Text(it, color = Palette.live, fontSize = 13.sp) }
}
