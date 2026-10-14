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
import com.mohamedt.streamforge.core.Store
import com.mohamedt.streamforge.core.bool
import com.mohamedt.streamforge.core.child
import com.mohamedt.streamforge.core.enc
import com.mohamedt.streamforge.core.long
import com.mohamedt.streamforge.core.normalizedBase
import com.mohamedt.streamforge.core.objects
import com.mohamedt.streamforge.core.str
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
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
            if (ts <= (state.stamps[rk(c, id)] ?: 0L)) continue
            accepted.add(r)
        }
        if (accepted.isEmpty()) return queued
        val ordered = accepted.sortedBy {
            when (raw(it, "collection")) {
                "secrets" -> 0
                "servers" -> 1
                else -> 2
            }
        }
        val ctx = SyncMapping.ApplyContext(state, ordered)
        for (r in ordered) {
            val c = raw(r, "collection") ?: continue
            val id = raw(r, "id") ?: continue
            val ts = r.long("updatedAt") ?: 0L
            try {
                SyncMapping.apply(c, id, r.bool("deleted"), r["data"] as? JsonObject, ts, ctx, state)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
            state.stamps[rk(c, id)] = ts
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
        return queued
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
