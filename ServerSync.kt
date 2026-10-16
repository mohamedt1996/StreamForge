package com.mohamedt.streamforge.sync

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.mohamedt.streamforge.core.AppJson
import com.mohamedt.streamforge.core.Settings
import com.mohamedt.streamforge.core.Store
import com.mohamedt.streamforge.core.bool
import com.mohamedt.streamforge.core.child
import com.mohamedt.streamforge.core.enc
import com.mohamedt.streamforge.core.long
import com.mohamedt.streamforge.core.normalizedBase
import com.mohamedt.streamforge.core.objects
import com.mohamedt.streamforge.core.str
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.stremio.Addons
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.Executors
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put

/**
 * Client for the self-hosted StreamForge sync server (server/PROTOCOL.md).
 *
 * Change detection: every store calls [RemoteSync.changed] after saving. A throttled diff turns the
 * local data into protocol records and compares each record's fingerprint with the last known one;
 * changed records go to the outbox, vanished ones become tombstones. Applying pulled records is
 * followed by a re-baseline, so remote changes (and their side effects) are never pushed back.
 *
 * All state is touched on the main thread; network calls suspend off it.
 */
object ServerSync {
    private const val STATE_FILE = "sync-state.json"
    private const val OUTBOX_FILE = "sync-outbox.json"
    private const val TOKEN_KEY = "sync.token"
    private const val MAX_RECORD_BYTES = 250 * 1024
    private const val MAX_REQUEST_BYTES = 1_800_000
    private const val MAX_BATCH = 500
    private const val LONG_POLL_SECONDS = 50
    private const val TOMBSTONE_DAYS = 180L

    private val SETTING_LABELS = mapOf(
        "metadataLanguage" to "Metadata language", "metadataSource" to "Metadata source", "maxResolution" to "Maximum quality",
        "excludeCam" to "Hide CAM releases", "streamSort" to "Stream sorting", "autoplayNext" to "Autoplay next episode",
        "resumePlayback" to "Resume playback", "seekStep" to "Skip interval", "skipIntros" to "Skip intros", "autoSkip" to "Auto-skip",
        "audioLanguage" to "Audio language", "subtitleLanguage" to "Subtitle language", "autoSubtitles" to "Automatic subtitles",
        "subtitleScale" to "Subtitle size", "hideAdult" to "Hide adult content", "trailerAutoplay" to "Autoplay trailers",
        "torrentMode" to "Torrent engine", "remoteTorrServer" to "Remote TorrServer",
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val diskWriter = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    private val mutex = Mutex()
    private val pushMutex = Mutex()
    private var started = false

    // MARK: Observable state (Compose)

    var serverUrl by mutableStateOf(""); private set
    var username by mutableStateOf(""); private set
    var userRole by mutableStateOf(""); private set
    var deviceId by mutableStateOf(""); private set
    var deviceName by mutableStateOf(""); private set
    var scopes by mutableStateOf<List<String>>(emptyList()); private set
    var serverName by mutableStateOf(""); private set
    var signedIn by mutableStateOf(false); private set
    var status by mutableStateOf("Not signed in"); private set
    var lastSyncAt by mutableStateOf(0L); private set
    var pending by mutableStateOf(0); private set
    var devices by mutableStateOf<List<SyncDevice>>(emptyList()); private set
    var pairing by mutableStateOf<Pairing?>(null); private set
    var pairMessage by mutableStateOf<String?>(null); private set
    var signOutReason by mutableStateOf<String?>(null); private set
    /** Managed items removed on this device that sync brought back: "Restore from sync" / "Continue without it". */
    var restorePrompt by mutableStateOf<List<ManagedItem>>(emptyList()); private set
    /** Managed settings the user just changed: "Keep it" / "Remove from this account". */
    var settingPrompt by mutableStateOf<List<ManagedItem>>(emptyList()); private set
    /** The restore prompt was closed without an answer; asked again when sync brings news. */
    var restorePromptSnoozed by mutableStateOf(false)
    /** Managed items this account continues without (restorable in Settings). */
    var dismissedItems by mutableStateOf<List<ManagedItem>>(emptyList()); private set

    /** A TV waiting for its code to be approved. */
    data class Pairing(val serverUrl: String, val code: String, val pairId: String, val expiresAt: Long, val failed: String? = null)

    val canPush: Boolean get() = signedIn && "write" in scopes
    val canReadSecrets: Boolean get() = "secrets" in scopes

    val isTvDevice: Boolean by lazy {
        val ctx = Store.context
        val ui = ctx.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        ui?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
    }

    // MARK: Engine state

    private var state = SyncState()
    private val outbox = ArrayList<OutboxEntry>()
    private var foreground = false
    private var inLongPoll = false
    private var loopJob: Job? = null
    private var diffJob: Job? = null
    private var diffRequested = false
    private var pushJob: Job? = null
    private var pushRequested = false
    private var pairJob: Job? = null
    /** Store callbacks while pulled records are written aren't user edits. */
    private var applyingRemote = false

    private val token: String get() = Store.secret(TOKEN_KEY)

    fun init() {
        if (started) return
        started = true
        val p = Store.prefs
        serverUrl = p.getString("sync.url", "") ?: ""
        username = p.getString("sync.username", "") ?: ""
        userRole = p.getString("sync.role", "") ?: ""
        deviceId = p.getString("sync.deviceId", "") ?: ""
        deviceName = p.getString("sync.deviceName", "") ?: ""
        serverName = p.getString("sync.serverName", "") ?: ""
        scopes = (p.getString("sync.scopes", "") ?: "").split(',').map { it.trim() }.filter { it.isNotEmpty() }
        lastSyncAt = p.getLong("sync.lastSync", 0L)
        signedIn = token.isNotEmpty() && serverUrl.isNotEmpty()
        state = Store.load(SyncState.serializer(), STATE_FILE) ?: SyncState()
        if (!state.managedTracked) {
            // State from before managed records were tracked: pull everything once more to learn
            // which records are managed (already-applied versions are skipped by their stamps).
            state.managedTracked = true
            state.lastRev = 0
        }
        outbox.clear()
        outbox.addAll(Store.load(ListSerializer(OutboxEntry.serializer()), OUTBOX_FILE) ?: emptyList())
        pending = outbox.size
        status = if (signedIn) "Connecting…" else "Not signed in"

        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                foreground = true
                if (signedIn) {
                    startLoop()
                    scope.launch { runCatching { refreshMe() } }
                }
            }

            override fun onStop(owner: LifecycleOwner) {
                foreground = false
                stopLoop()
                // Upload what is pending right away: the process may not live long in the background.
                if (outbox.isNotEmpty()) schedulePush(0)
            }
        })
        // Switching the active Dispatcharr server swaps the per-server channel favourites (activate() doesn't save anything).
        scope.launch { snapshotFlow { DispatcharrRepo.active?.id }.collect { noteChange() } }
        refreshManagedPrompts()
        noteChange()
    }

    // MARK: Change detection

    /** Throttled: at most one diff every 1.5 s, always after the latest change. */
    fun noteChange() {
        if (!started) return
        if (Looper.myLooper() != Looper.getMainLooper()) {
            scope.launch { noteChange() }
            return
        }
        checkManagedSettingEdits()
        diffRequested = true
        if (diffJob?.isActive == true) return
        diffJob = scope.launch {
            while (diffRequested) {
                delay(1500)
                diffRequested = false
                runDiff(full = false)
            }
        }
    }

    private suspend fun runDiff(full: Boolean) {
        val queued = mutex.withLock {
            val q = diffLocked(full)
            persistLocked()
            q
        }
        if (queued) schedulePush()
    }

    /** Compares local records with the known fingerprints; queues changes. [full] queues everything (first sign-in). */
    private fun diffLocked(full: Boolean): Boolean {
        val local = SyncMapping.collect(state)
        val now = System.currentTimeMillis()
        val first = !state.baselined
        var queued = false
        for ((k, r) in local) {
            val fp = fingerprint(r.data)
            val changed = state.known[k] != fp
            // A changed managed setting waits for the user's answer (settingPrompt); the server would refuse it anyway.
            if (changed && !first && !full && r.collection == "settings" && k in state.known && isManagedForUser(k)) continue
            if (changed) state.locallyRemoved.remove(k)
            if (changed) {
                state.known[k] = fp
                // Data that existed before sync was set up counts as old, so it never beats real edits elsewhere.
                // A local edit must beat the version it replaces even if that one came from a device
                // whose clock runs ahead (records without their own time only).
                state.stamps[k] = if (first) (r.natural ?: 1L) else (r.natural ?: maxOf(now, (state.stamps[k] ?: 0L) + 1))
            }
            if ((changed && !first) || full) {
                if (enqueue(r.collection, r.id, r.data, state.stamps[k] ?: r.natural ?: 1L)) queued = true
            }
        }
        val gone = state.known.keys.filter { it !in local }
        for (k in gone) {
            state.known.remove(k)
            if (first) continue
            // Removed here without "Remove from this account": if sync brings it back, ask.
            val c = k.substringBefore('/')
            if ((c == "servers" || c == "addons") && isManagedForUser(k)) state.locallyRemoved.add(k)
            val t = maxOf(now, (state.stamps[k] ?: 0L) + 1)
            state.stamps[k] = t
            if (enqueue(k.substringBefore('/'), k.substringAfter('/'), null, t)) queued = true
        }
        state.baselined = true
        if (state.stamps.size > state.known.size + 1000) {
            val cutoff = now - TOMBSTONE_DAYS * 24 * 3600 * 1000
            state.stamps.entries.removeAll { (k, t) -> k !in state.known && t < cutoff }
        }
        return queued
    }

    /** Upserts an outbox entry (data null = tombstone). */
    private fun enqueue(collection: String, id: String, data: JsonObject?, updatedAt: Long): Boolean {
        if (!canPush) return false
        if (collection == "secrets" && !canReadSecrets) return false
        if (data != null && data.toString().length > MAX_RECORD_BYTES) return false
        outbox.removeAll { it.collection == collection && it.id == id }
        outbox.add(OutboxEntry(collection, id, data, data == null, updatedAt))
        pending = outbox.size
        return true
    }

    private fun fingerprint(o: JsonObject): String {
        val digest = MessageDigest.getInstance("MD5").digest(o.toString().toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(32)
        for (b in digest) sb.append(String.format("%02x", b.toInt() and 0xff))
        return sb.toString()
    }

    private fun persistLocked() {
        val s = AppJson.encodeToString(SyncState.serializer(), state)
        val o = AppJson.encodeToString(ListSerializer(OutboxEntry.serializer()), outbox.toList())
        scope.launch(diskWriter) {
            writeFile(STATE_FILE, s)
            writeFile(OUTBOX_FILE, o)
        }
    }

    private fun writeFile(name: String, text: String) {
        try {
            val f = Store.file(name)
            val tmp = File(f.parentFile, "$name.tmp")
            tmp.writeText(text)
            tmp.renameTo(f)
        } catch (_: Exception) {
        }
    }

    // MARK: Push

    private fun schedulePush(delayMs: Long = 3000) {
        if (!canPush) return
        pushRequested = true
        if (pushJob?.isActive == true) return
        pushJob = scope.launch {
            while (pushRequested) {
                delay(delayMs)
                pushRequested = false
                pushAll()
            }
        }
    }

    private fun wire(e: OutboxEntry): JsonObject = buildJsonObject {
        put("collection", e.collection)
        put("id", e.id)
        put("data", e.data ?: JsonNull)
        put("deleted", e.deleted)
        put("updatedAt", e.updatedAt)
    }

    /** Pushes the whole outbox in ≤ 500-record / ≤ 1.8 MB requests. Never throws (except cancellation). */
    private suspend fun pushAll(): Boolean = pushMutex.withLock {
        while (signedIn && canPush) {
            val batch = ArrayList<OutboxEntry>()
            val bodies = ArrayList<JsonObject>()
            mutex.withLock {
                var bytes = 0
                for (e in outbox) {
                    val w = wire(e)
                    val size = w.toString().length
                    if (batch.size >= MAX_BATCH || (batch.isNotEmpty() && bytes + size > MAX_REQUEST_BYTES)) break
                    batch.add(e); bodies.add(w); bytes += size
                }
            }
            if (batch.isEmpty()) {
                refreshStatus()
                return@withLock true
            }
            status = "Uploading ${outbox.size} change${if (outbox.size == 1) "" else "s"}…"
            val response = try {
                api("POST", "/api/sync", buildJsonObject { put("records", JsonArray(bodies)) })
            } catch (e: CancellationException) {
                throw e
            } catch (e: SyncApiException) {
                when (e.status) {
                    401 -> Unit
                    403 -> status = "This device can't upload changes (read-only access)"
                    429 -> { status = "Server busy, retrying…"; retryPushLater((e.retryAfterSeconds ?: 30) * 1000) }
                    else -> { status = e.message ?: "Upload failed"; retryPushLater(30_000) }
                }
                return@withLock false
            } catch (e: Exception) {
                status = "Offline · changes will upload later"
                retryPushLater(30_000)
                return@withLock false
            }
            val results = response.obj?.objects("results") ?: emptyList()
            val sent = batch.associateBy { it.key }
            var progressMade = false
            var staleRev: Long? = null
            mutex.withLock {
                val done = HashSet<String>()
                for (r in results) {
                    val c = raw(r, "collection") ?: continue
                    val id = raw(r, "id") ?: continue
                    done.add(rk(c, id))
                    // rev 0 = nothing to re-pull (e.g. a secret refused for lack of the secrets scope);
                    // treating it as a rev would restart the pull from scratch.
                    if (r.str("status") == "stale") r.long("rev")?.takeIf { it > 0 }?.let { rev -> staleRev = minOf(staleRev ?: rev, rev) }
                }
                if (results.isEmpty()) done.addAll(sent.keys)
                val before = outbox.size
                outbox.removeAll { e -> e.key in done && sent[e.key]?.let { s -> s.updatedAt == e.updatedAt && s.deleted == e.deleted } == true }
                progressMade = outbox.size < before
                // "stale": the server has a newer copy. Pull again from just before it so it gets applied here.
                staleRev?.let { rev -> if (rev - 1 < state.lastRev) state.lastRev = maxOf(0L, rev - 1) }
                pending = outbox.size
                persistLocked()
            }
            markSynced()
            if (staleRev != null) kickPull()
            if (!progressMade) break
        }
        refreshStatus()
        true
    }

    private fun retryPushLater(ms: Long) {
        scope.launch {
            delay(ms)
            if (outbox.isNotEmpty()) schedulePush(0)
        }
    }

    // MARK: Pull

    private fun startLoop() {
        if (!signedIn || !foreground || loopJob?.isActive == true) return
        loopJob = scope.launch { pullLoop() }
    }

    private fun stopLoop() {
        loopJob?.cancel()
        loopJob = null
        inLongPoll = false
    }

    /** Ends a long poll early so the next pull happens now. */
    private fun kickPull() {
        if (inLongPoll) {
            stopLoop()
            startLoop()
        }
    }

    private suspend fun pullLoop() {
        var backoff = 5_000L
        var wait = 0
        if (outbox.isNotEmpty()) pushAll()
        while (signedIn && foreground) {
            try {
                val more = pullOnce(wait)
                backoff = 5_000L
                wait = if (more) 0 else LONG_POLL_SECONDS
            } catch (e: CancellationException) {
                throw e
            } catch (e: SyncApiException) {
                if (e.status == 401) return
                val pause = if (e.status == 429) (e.retryAfterSeconds ?: 30) * 1000 else backoff
                status = if (e.status == 403) "This device can't download (no read access)" else (e.message ?: "Sync error")
                wait = 0
                delay(pause)
                backoff = minOf(backoff * 2, 60_000L)
            } catch (e: Exception) {
                status = "Offline · retrying in ${backoff / 1000}s"
                wait = 0
                delay(backoff)
                backoff = minOf(backoff * 2, 60_000L)
            }
        }
    }

    /** One GET /api/sync. Returns true when more records are waiting. */
    private suspend fun pullOnce(wait: Int): Boolean {
        val since = state.lastRev
        if (wait == 0 && outbox.isEmpty()) status = "Syncing…"
        inLongPoll = wait > 0
        val response = try {
            api("GET", "/api/sync?since=$since&limit=1000&wait=$wait", longPoll = wait > 0)
        } finally {
            inLongPoll = false
        }
        val o = response.obj ?: throw IOException("Unexpected response from the sync server")
        val rev = o.long("rev") ?: since
        val more = o.bool("more")
        val records = o.objects("records")
        var queued = false
        var reset = false
        mutex.withLock {
            if (rev < since) {
                // The server lost its data (restored / reset): start over and upload everything again.
                state.lastRev = 0
                queued = diffLocked(full = true)
                reset = true
            } else {
                queued = applyLocked(records)
                if (state.lastRev == since) state.lastRev = rev
            }
            persistLocked()
        }
        if (queued) schedulePush(if (reset) 0 else 3000)
        markSynced()
        refreshStatus()
        return more || reset
    }

    /** Applies pulled records (LWW by updatedAt), then re-baselines so nothing applied is pushed back. */
    private suspend fun applyLocked(records: List<JsonObject>): Boolean {
        // Local edits made before this batch go to the outbox first.
        val queued = diffLocked(false)
        val accepted = ArrayList<JsonObject>()
        for (r in records) {
            val c = raw(r, "collection") ?: continue
            val id = raw(r, "id") ?: continue
            val ts = r.long("updatedAt") ?: 0L
            trackManaged(c, id, r)
            if (ts <= (state.stamps[rk(c, id)] ?: 0L)) continue
            accepted.add(r)
        }
        if (accepted.isEmpty()) {
            refreshManagedPrompts()
            return queued
        }
        val ordered = accepted.sortedBy {
            when (raw(it, "collection")) {
                "secrets" -> 0
                "servers" -> 1
                else -> 2
            }
        }
        val ctx = SyncMapping.ApplyContext(state, ordered)
        applyingRemote = true
        try {
            for (r in ordered) {
                val c = raw(r, "collection") ?: continue
                val id = raw(r, "id") ?: continue
                val ts = r.long("updatedAt") ?: 0L
                // A managed item the user removed here comes back: ask first (restore prompt).
                if (holdIfLocallyRemoved(c, id, r, ts)) {
                    state.stamps[rk(c, id)] = ts
                    continue
                }
                try {
                    SyncMapping.apply(c, id, r.bool("deleted"), r["data"] as? JsonObject, ts, ctx, state)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                }
                state.stamps[rk(c, id)] = ts
            }
        } finally {
            applyingRemote = false
        }
        try {
            SyncMapping.applyAddons(ctx)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
        }
        SyncMapping.afterSecrets(ctx)
        val local = SyncMapping.collect(state)
        state.known.clear()
        for ((k, r) in local) state.known[k] = fingerprint(r.data)
        refreshManagedPrompts()
        return queued
    }

    // MARK: Admin-managed configuration (PROTOCOL.md §5)

    private fun dismissalId(key: String): String = key.substringBefore('/') + "|" + key.substringAfter('/', "")

    /** Managed by the server admin and not dismissed by this account. */
    private fun isManagedForUser(key: String): Boolean = key in state.managed && dismissalId(key) !in state.dismissed

    /** Whether removing/changing this item needs the "Set up by your server" confirmation. */
    fun isManaged(collection: String, id: String): Boolean = signedIn && isManagedForUser(rk(collection, id))

    /** A confirmation for removing [id] when it is managed, else null (remove right away). */
    fun managedRemoval(collection: String, id: String, name: String, perform: () -> Unit): ManagedRemoval? =
        if (isManaged(collection, id)) ManagedRemoval(ManagedItem(rk(collection, id), collection, id, name), perform) else null

    /** Tracks the managed flag of a pulled record (any version: the newest rev wins). */
    private fun trackManaged(c: String, id: String, r: JsonObject) {
        if (c != "servers" && c != "addons" && c != "settings" && c != "secrets") return
        val k = rk(c, id)
        val deleted = r.bool("deleted")
        val data = r["data"] as? JsonObject
        if (r.bool("managed") && !deleted) {
            state.managed.add(k)
            if (c == "settings") data?.get("value")?.let { state.managedSettings[id] = it }
            if (c != "secrets") state.managedNames[k] = managedName(c, id, data)
        } else {
            state.managed.remove(k)
            if (c == "settings") state.managedSettings.remove(id)
        }
        if (deleted) {
            state.locallyRemoved.remove(k)
            state.held.remove(k)
        }
    }

    /** Holds a managed server/addon (or its credentials) the user removed on this device. Returns true when held. */
    private fun holdIfLocallyRemoved(c: String, id: String, r: JsonObject, ts: Long): Boolean {
        if (r.bool("deleted") || !r.bool("managed")) return false
        val k = rk(c, id)
        when (c) {
            "servers", "addons" -> {
                if (k !in state.locallyRemoved || dismissalId(k) in state.dismissed) return false
                val present = if (c == "servers") DispatcharrRepo.servers.any { it.id.equals(id, ignoreCase = true) }
                else Addons.addons.any { Addons.manifestUrl(it) == id }
                if (present) {
                    state.locallyRemoved.remove(k)
                    return false
                }
            }
            "secrets" -> {
                if (!id.startsWith("server:")) return false
                val serverKey = rk("servers", id.removePrefix("server:").lowercase())
                if (serverKey !in state.locallyRemoved && serverKey !in state.held) return false
            }
            else -> return false
        }
        state.held[k] = HeldRecord(c, id, r["data"] as? JsonObject, ts)
        outbox.removeAll { it.key == k }
        pending = outbox.size
        return true
    }

    private fun managedName(c: String, id: String, data: JsonObject?): String = when (c) {
        "settings" -> SETTING_LABELS[id] ?: id
        "addons" -> data?.str("name") ?: id.substringAfter("://").substringBefore('/')
        "servers" -> data?.str("name") ?: "Dispatcharr server"
        else -> id
    }

    private fun itemName(key: String): String =
        state.managedNames[key] ?: managedName(key.substringBefore('/'), key.substringAfter('/', ""), null)

    /** Recomputes the observable prompt lists from the persisted state. */
    private fun refreshManagedPrompts() {
        // Credentials whose server isn't held (or locally removed) any more have nothing to wait for.
        state.held.entries.removeAll { (_, h) ->
            if (h.collection != "secrets") return@removeAll false
            val serverKey = rk("servers", h.id.removePrefix("server:").lowercase())
            serverKey !in state.held && serverKey !in state.locallyRemoved
        }
        val restore = state.held.values.filter { it.collection != "secrets" }
            .map { ManagedItem(rk(it.collection, it.id), it.collection, it.id, managedName(it.collection, it.id, it.data)) }
            .sortedBy { it.name.lowercase() }
        if (restore != restorePrompt) {
            restorePrompt = restore
            restorePromptSnoozed = false
        }
        val dismissed = state.dismissed.keys.map { did ->
            val c = did.substringBefore('|')
            val id = did.substringAfter('|', "")
            val k = rk(c, id)
            ManagedItem(k, c, id, itemName(k))
        }.sortedBy { it.name.lowercase() }
        if (dismissed != dismissedItems) dismissedItems = dismissed
        if (settingPrompt.isNotEmpty()) {
            val values = SyncMapping.settingValues()
            val still = settingPrompt.filter { item ->
                val managed = state.managedSettings[item.itemId]
                isManagedForUser(item.key) && managed != null && values[item.itemId]?.let { it.toString() != managed.toString() } == true
            }
            if (still != settingPrompt) settingPrompt = still
        }
    }

    /** Notices edits of managed settings right away (called on every local change). */
    private fun checkManagedSettingEdits() {
        if (!signedIn || applyingRemote || state.managedSettings.isEmpty()) return
        val prompt = settingPrompt.toMutableList()
        for ((key, value) in SyncMapping.settingValues()) {
            val k = rk("settings", key)
            if (!isManagedForUser(k)) continue
            val known = state.known[k] ?: continue
            if (known == fingerprint(buildJsonObject { put("value", value) }) || prompt.any { it.key == k }) continue
            prompt.add(ManagedItem(k, "settings", key, itemName(k)))
        }
        if (prompt != settingPrompt) settingPrompt = prompt
    }

    /** "Remove from this account" for an addon or server: call before removing it locally. */
    fun dismiss(collection: String, id: String) {
        if (!signedIn) return
        val k = rk(collection, id)
        val at = System.currentTimeMillis()
        // Main.immediate: runs before the caller removes the item unless a sync is applying records,
        // and always before the (delayed) diff that turns the removal into a tombstone.
        scope.launch {
            mutex.withLock {
                state.dismissed[dismissalId(k)] = at
                state.locallyRemoved.remove(k)
                refreshManagedPrompts()
                persistLocked()
            }
            noteChange()
        }
    }

    /** Ends a dismissal ("Restore"): the server sends the item again. */
    fun restoreDismissed(item: ManagedItem) {
        if (!signedIn) return
        scope.launch {
            mutex.withLock {
                state.dismissed.remove(dismissalId(item.key))
                refreshManagedPrompts()
                diffLocked(false)
                persistLocked()
            }
            schedulePush(0)
        }
    }

    /** "Restore from sync": applies the held records. */
    fun restoreHeld() {
        scope.launch {
            mutex.withLock {
                val held = state.held.values.toList()
                if (held.isEmpty()) return@withLock
                state.held.clear()
                val records = held.map { h ->
                    val k = rk(h.collection, h.id)
                    state.locallyRemoved.remove(k)
                    if (h.collection == "secrets") state.locallyRemoved.remove(rk("servers", h.id.removePrefix("server:").lowercase()))
                    state.stamps.remove(k)
                    buildJsonObject {
                        put("collection", h.collection)
                        put("id", h.id)
                        put("data", h.data ?: JsonNull)
                        put("deleted", false)
                        put("updatedAt", h.updatedAt)
                        put("managed", true)
                    }
                }
                if (applyLocked(records)) schedulePush()
                persistLocked()
            }
        }
    }

    /** "Continue without it": dismisses the held items for this account. */
    fun continueWithoutHeld() {
        scope.launch {
            mutex.withLock {
                val held = state.held.values.toList()
                if (held.isEmpty()) return@withLock
                state.held.clear()
                val now = System.currentTimeMillis()
                for (h in held) {
                    val k = rk(h.collection, h.id)
                    state.locallyRemoved.remove(k)
                    if (h.collection != "secrets") state.dismissed[dismissalId(k)] = now
                    // The removal itself (the server tombstones it anyway once it has the dismissal).
                    val t = maxOf(now, h.updatedAt + 1)
                    state.stamps[k] = t
                    enqueue(h.collection, h.id, null, t)
                }
                diffLocked(false)
                refreshManagedPrompts()
                persistLocked()
            }
            schedulePush(0)
        }
    }

    /** "Keep it": puts the managed setting values back. */
    fun keepManagedSettings() {
        val items = settingPrompt
        settingPrompt = emptyList()
        if (items.isEmpty()) return
        var values = Settings.values
        for (item in items) {
            val v = state.managedSettings[item.itemId] ?: continue
            SyncMapping.settingWith(values, item.itemId, v)?.let { values = it }
        }
        applyingRemote = true
        try {
            if (values != Settings.values) Settings.update { values }
        } finally {
            applyingRemote = false
        }
        scope.launch {
            mutex.withLock {
                // Adopt the restored values as what this device has.
                val local = SyncMapping.collect(state)
                for (item in items) local[item.key]?.let { state.known[item.key] = fingerprint(it.data) }
                persistLocked()
            }
        }
    }

    /** "Remove from this account": the user's own values replace the managed ones on all devices. */
    fun releaseManagedSettings() {
        val items = settingPrompt
        settingPrompt = emptyList()
        if (items.isEmpty()) return
        scope.launch {
            mutex.withLock {
                val now = System.currentTimeMillis()
                val values = SyncMapping.settingValues()
                for (item in items) {
                    state.dismissed[dismissalId(item.key)] = now
                    val v = values[item.itemId] ?: continue
                    val data = buildJsonObject { put("value", v) }
                    val t = maxOf(now, (state.stamps[item.key] ?: 0L) + 1)
                    state.known[item.key] = fingerprint(data)
                    state.stamps[item.key] = t
                    enqueue("settings", item.itemId, data, t)
                }
                diffLocked(false)
                refreshManagedPrompts()
                persistLocked()
            }
            schedulePush(0)
        }
    }

    private fun markSynced() {
        lastSyncAt = System.currentTimeMillis()
        Store.prefs.edit().putLong("sync.lastSync", lastSyncAt).apply()
    }

    private fun refreshStatus() {
        if (!signedIn) return
        status = when {
            outbox.isNotEmpty() && !canPush -> "Read-only device"
            outbox.isNotEmpty() -> "${outbox.size} change${if (outbox.size == 1) "" else "s"} waiting to upload"
            else -> "Up to date"
        }
    }

    // MARK: HTTP

    private fun raw(o: JsonObject?, key: String): String? = (o?.get(key) as? JsonPrimitive)?.takeIf { it !is JsonNull }?.contentOrNull

    private suspend fun api(
        method: String,
        path: String,
        body: JsonElement? = null,
        longPoll: Boolean = false,
        base: String = serverUrl,
        auth: Boolean = true,
    ): SyncResponse {
        try {
            return SyncApi.request(base, method, path, if (auth) token else null, body, longPoll)
        } catch (e: SyncApiException) {
            if (e.status == 401 && auth && signedIn) {
                withContext(Dispatchers.Main) { signOutLocally("The server signed this device out. Your library stays on this device.") }
            }
            throw e
        }
    }

    // MARK: Account

    private fun platform(): String = if (isTvDevice) "androidtv" else "android"

    private fun defaultDeviceName(): String {
        val maker = (Build.MANUFACTURER ?: "").replaceFirstChar { it.uppercase() }
        val model = Build.MODEL ?: ""
        val name = (if (model.startsWith(maker, ignoreCase = true)) model else "$maker $model").trim().ifEmpty { "Android" }
        return if (isTvDevice && !name.contains("TV", ignoreCase = true)) "$name TV" else name
    }

    private fun deviceJson(): JsonObject = buildJsonObject {
        put("name", defaultDeviceName())
        put("platform", platform())
    }

    private fun decodeUser(o: JsonObject?): SyncUser? = o?.let { runCatching { AppJson.decodeFromJsonElement(SyncUser.serializer(), it) }.getOrNull() }
    private fun decodeDevice(o: JsonObject?): SyncDevice? = o?.let { runCatching { AppJson.decodeFromJsonElement(SyncDevice.serializer(), it) }.getOrNull() }

    private fun saveIdentity(base: String?, user: SyncUser?, device: SyncDevice?, server: String? = null) {
        val e = Store.prefs.edit()
        base?.let { serverUrl = it; e.putString("sync.url", it) }
        user?.let {
            username = it.username; userRole = it.role
            e.putString("sync.username", it.username).putString("sync.role", it.role)
        }
        device?.let {
            deviceId = it.id; deviceName = it.name; scopes = it.scopes
            e.putString("sync.deviceId", it.id).putString("sync.deviceName", it.name).putString("sync.scopes", it.scopes.joinToString(","))
        }
        server?.let { serverName = it; e.putString("sync.serverName", it) }
        e.apply()
    }

    /** Password sign-in. Throws with a readable message on failure. */
    suspend fun signIn(rawUrl: String, user: String, password: String) {
        val base = normalizedBase(rawUrl) ?: throw IllegalArgumentException("Enter the server address")
        if (user.isBlank() || password.isEmpty()) throw IllegalArgumentException("Enter your username and password")
        val body = buildJsonObject {
            put("username", user.trim())
            put("password", password)
            put("device", deviceJson())
        }
        val o = api("POST", "/api/auth/login", body, base = base, auth = false).obj ?: throw IOException("Unexpected response from the server")
        completeSignIn(base, o)
    }

    private suspend fun completeSignIn(base: String, o: JsonObject) {
        val newToken = raw(o, "token") ?: throw IOException("The server didn't return a device token")
        Store.setSecret(TOKEN_KEY, newToken)
        saveIdentity(base, decodeUser(o.child("user")), decodeDevice(o.child("device")))
        signOutReason = null
        pairing = null
        pairMessage = null
        signedIn = true
        if (scopes.isEmpty()) runCatching { refreshMe() }
        status = "Uploading this device's library…"
        // First sign-in on this device: queue every local record, then pull everything (LWW decides).
        mutex.withLock {
            outbox.clear()
            state.lastRev = 0
            diffLocked(full = true)
            pending = outbox.size
            persistLocked()
        }
        scope.launch { runCatching { refreshMe() } }
        stopLoop()
        if (foreground) startLoop() else schedulePush(0)
    }

    /** Refreshes user, device (scopes) and server name. */
    suspend fun refreshMe() {
        if (!signedIn) return
        val o = api("GET", "/api/me").obj ?: return
        saveIdentity(null, decodeUser(o.child("user")), decodeDevice(o.child("device")), o.child("server")?.str("name"))
    }

    /** TV pairing: get a code, show it, poll every 2 s until another device approves it. */
    fun startPairing(rawUrl: String) {
        val base = normalizedBase(rawUrl)
        if (base == null) {
            pairMessage = "Enter the server address"
            return
        }
        pairJob?.cancel()
        pairMessage = null
        pairing = null
        pairJob = scope.launch {
            try {
                val o = api("POST", "/api/auth/pair/start", buildJsonObject { put("device", deviceJson()) }, base = base, auth = false).obj
                    ?: throw IOException("Unexpected response from the server")
                val pairId = raw(o, "pairId") ?: throw IOException("The server didn't return a pairing id")
                val code = raw(o, "code") ?: throw IOException("The server didn't return a code")
                val expiresAt = System.currentTimeMillis() + (o.long("expiresIn") ?: 600L) * 1000
                pairing = Pairing(base, code, pairId, expiresAt)
                while (true) {
                    delay(2000)
                    if (System.currentTimeMillis() > expiresAt) {
                        pairing = pairing?.copy(failed = "This code expired. Get a new one.")
                        return@launch
                    }
                    val r = try {
                        api("GET", "/api/auth/pair/${enc(pairId)}", base = base, auth = false)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: SyncApiException) {
                        if (e.status == 410 || e.status == 404) {
                            pairing = pairing?.copy(failed = "This code expired or was denied. Get a new one.")
                            return@launch
                        }
                        continue
                    } catch (e: Exception) {
                        continue // network blip: keep polling
                    }
                    val body = r.obj
                    if (r.status == 200 && body != null && raw(body, "status") == "approved") {
                        completeSignIn(base, body)
                        return@launch
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                pairing = null
                pairMessage = e.message ?: "Couldn't reach the server"
            }
        }
    }

    fun cancelPairing() {
        pairJob?.cancel()
        pairJob = null
        pairing = null
    }

    /** Approves a code shown on a TV; the new device joins this account. */
    suspend fun approvePairing(code: String, allowSecrets: Boolean): String {
        var c = code.trim().uppercase().replace(" ", "")
        if (c.length == 6 && '-' !in c) c = c.substring(0, 3) + "-" + c.substring(3)
        if (c.isEmpty()) throw IllegalArgumentException("Enter the code shown on the TV")
        val body = buildJsonObject {
            put("code", c)
            put("scopes", buildJsonArray {
                add("read")
                add("write")
                if (allowSecrets) add("secrets")
            })
        }
        val o = api("POST", "/api/pair/approve", body).obj
        val name = o?.child("device")?.str("name")
        return if (name != null) "Approved “$name”" else "Approved"
    }

    suspend fun loadDevices() {
        val o = api("GET", "/api/devices").obj
        devices = o?.objects("devices")?.mapNotNull { decodeDevice(it) } ?: emptyList()
    }

    suspend fun renameDevice(id: String, name: String) {
        val clean = name.trim()
        if (clean.isEmpty()) throw IllegalArgumentException("Enter a name")
        api("PATCH", "/api/devices/${enc(id)}", buildJsonObject { put("name", clean) })
        if (id == deviceId) {
            deviceName = clean
            Store.prefs.edit().putString("sync.deviceName", clean).apply()
        }
        loadDevices()
    }

    suspend fun revokeDevice(id: String) {
        api("DELETE", "/api/devices/${enc(id)}")
        if (id == deviceId) signOutLocally(null) else loadDevices()
    }

    suspend fun changePassword(current: String, new: String) {
        if (new.length < 4) throw IllegalArgumentException("Choose a longer password")
        api("POST", "/api/me/password", buildJsonObject {
            put("current", current)
            put("new", new)
        })
    }

    /** Pushes pending changes and pulls now. */
    fun syncNow() {
        if (!signedIn) return
        scope.launch {
            runDiff(full = false)
            pushAll()
            stopLoop()
            startLoop()
            if (!foreground) {
                runCatching { pullOnce(0) }
            }
        }
    }

    /** Revokes this device on the server (best effort) and signs out. Local data is kept. */
    suspend fun signOut() {
        if (signedIn) {
            try {
                withTimeoutOrNull(5000) { api("POST", "/api/auth/logout") }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }
        signOutLocally(null)
    }

    private fun signOutLocally(reason: String?) {
        Store.setSecret(TOKEN_KEY, "")
        signedIn = false
        stopLoop()
        pushJob?.cancel()
        pushJob = null
        devices = emptyList()
        restorePrompt = emptyList()
        settingPrompt = emptyList()
        dismissedItems = emptyList()
        signOutReason = reason
        status = reason ?: "Not signed in"
        // Pending uploads are dropped: the next sign-in uploads everything anyway.
        scope.launch {
            mutex.withLock {
                outbox.clear()
                pending = 0
                persistLocked()
            }
        }
    }
}
