package com.mohamedt.streamforge.sync

import com.mohamedt.streamforge.core.AppJson
import com.mohamedt.streamforge.core.Http
import com.mohamedt.streamforge.core.obj
import com.mohamedt.streamforge.core.parseJson
import com.mohamedt.streamforge.core.str
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

/** A 4xx/5xx from the sync server: `{"error": "...", "code": "..."}`. */
class SyncApiException(val status: Int, message: String, val code: String? = null, val retryAfterSeconds: Long? = null) : IOException(message)

@Serializable
data class SyncUser(
    val id: String = "",
    val username: String = "",
    val role: String = "member",
    val disabled: Boolean = false,
    val createdAt: Long = 0,
)

@Serializable
data class SyncDevice(
    val id: String = "",
    val name: String = "",
    val platform: String = "",
    val scopes: List<String> = emptyList(),
    val createdAt: Long = 0,
    val lastSeenAt: Long = 0,
    val lastIp: String? = null,
    val current: Boolean = false,
)

class SyncResponse(val status: Int, val body: JsonElement?) {
    val obj: JsonObject? get() = body.obj()
}

internal object SyncApi {
    private val jsonType = "application/json; charset=utf-8".toMediaType()

    private val shortClient: OkHttpClient by lazy {
        Http.client.newBuilder().readTimeout(30, TimeUnit.SECONDS).callTimeout(45, TimeUnit.SECONDS).build()
    }

    /** Long polls hold the request up to `wait` seconds (≤ 55). */
    private val longClient: OkHttpClient by lazy {
        Http.client.newBuilder().readTimeout(80, TimeUnit.SECONDS).callTimeout(90, TimeUnit.SECONDS).build()
    }

    suspend fun request(
        base: String,
        method: String,
        path: String,
        token: String?,
        body: JsonElement? = null,
        longPoll: Boolean = false,
    ): SyncResponse {
        val builder = Request.Builder()
            .url(base.trimEnd('/') + path)
            .header("User-Agent", "StreamForge/1.0 (Android)")
            .header("Accept", "application/json")
        if (!token.isNullOrEmpty()) builder.header("Authorization", "Bearer $token")
        val payload = body?.let { AppJson.encodeToString(JsonElement.serializer(), it) }
        when {
            method == "GET" -> builder.get()
            method == "DELETE" && payload == null -> builder.delete()
            else -> builder.method(method, (payload ?: "{}").toRequestBody(jsonType))
        }
        val client = if (longPoll) longClient else shortClient
        val response = client.newCall(builder.build()).await()
        return withContext(Dispatchers.IO) {
            response.use { r ->
                val text = r.body?.string() ?: ""
                val parsed = if (text.isBlank()) null else parseJson(text)
                if (!r.isSuccessful) {
                    val o = parsed.obj()
                    val message = o?.str("error") ?: when (r.code) {
                        401 -> "Not signed in"
                        403 -> "This device isn't allowed to do that"
                        404 -> "Not found. Is this a StreamForge sync server?"
                        429 -> "Too many requests, try again shortly"
                        else -> "Server returned ${r.code}"
                    }
                    throw SyncApiException(r.code, message, o?.str("code"), r.header("Retry-After")?.trim()?.toLongOrNull())
                }
                SyncResponse(r.code, parsed)
            }
        }
    }
}

/** Cancellable okhttp call: cancelling the coroutine aborts the (long-poll) request. */
private suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            if (cont.isActive) cont.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            if (cont.isActive) cont.resume(response) else response.close()
        }
    })
    cont.invokeOnCancellation { runCatching { cancel() } }
}
