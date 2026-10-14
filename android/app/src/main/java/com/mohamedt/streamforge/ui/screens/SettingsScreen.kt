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
import com.mohamedt.streamforge.torrent.TorrServer
import com.mohamedt.streamforge.ui.Chip
import com.mohamedt.streamforge.ui.Dims
import com.mohamedt.streamforge.ui.Palette
import com.mohamedt.streamforge.ui.card
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

    Section("Dispatcharr", "Account login uses your Dispatcharr username and password: the app reads your XC password automatically (admins get one created). Live TV, the full guide, catch-up, movies, series and DVR all come from your server.") {
        DispatcharrRepo.servers.forEach { server ->
            Row(Modifier.fillMaxWidth().card({ DispatcharrRepo.activate(server.id) }).padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(server.name + if (server.id == DispatcharrRepo.active?.id) "  ✓" else "", fontWeight = FontWeight.Bold)
                    Text("${server.username} @ ${server.baseUrl} · ${server.authMode.name.lowercase().replace('_', ' ')}", fontSize = 12.sp, color = Palette.secondary)
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
