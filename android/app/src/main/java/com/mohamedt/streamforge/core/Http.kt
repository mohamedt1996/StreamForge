package com.mohamedt.streamforge.core

import java.io.File
import java.io.IOException
import java.net.URLEncoder
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

class HttpException(val code: Int, message: String) : IOException(message)

object Http {
    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .followRedirects(true)
        .retryOnConnectionFailure(true)
        .build()

    private val jsonType = "application/json; charset=utf-8".toMediaType()

    suspend fun text(
        url: String,
        headers: Map<String, String> = emptyMap(),
        method: String = "GET",
        body: String? = null,
        timeoutSeconds: Long? = null,
    ): String = withContext(Dispatchers.IO) {
        val builder = Request.Builder().url(url).header("User-Agent", "StreamForge/1.0 (Android)")
        headers.forEach { (k, v) -> builder.header(k, v) }
        if (body != null) builder.method(method, body.toRequestBody(jsonType)) else if (method != "GET") builder.method(method, null)
        val call = if (timeoutSeconds != null) {
            client.newBuilder().readTimeout(timeoutSeconds, TimeUnit.SECONDS).build().newCall(builder.build())
        } else {
            client.newCall(builder.build())
        }
        call.execute().use { response ->
            val text = response.body?.string() ?: ""
            if (response.code == 401 || response.code == 403) throw HttpException(response.code, "Wrong username or password")
            if (!response.isSuccessful) throw HttpException(response.code, "Server returned ${response.code}: ${text.take(200)}")
            text
        }
    }

    suspend fun json(
        url: String,
        headers: Map<String, String> = emptyMap(),
        method: String = "GET",
        body: String? = null,
        timeoutSeconds: Long? = null,
    ): JsonElement {
        val text = text(url, headers, method, body, timeoutSeconds)
        return parseJson(text) ?: throw IOException("Unexpected response from ${url.substringBefore('?')}")
    }

    /** Streams a (possibly huge) response to a file. */
    suspend fun download(url: String, target: File, headers: Map<String, String> = emptyMap()) = withContext(Dispatchers.IO) {
        val builder = Request.Builder().url(url).header("User-Agent", "StreamForge/1.0 (Android)")
        headers.forEach { (k, v) -> builder.header(k, v) }
        client.newBuilder().readTimeout(300, TimeUnit.SECONDS).build().newCall(builder.build()).execute().use { response ->
            if (!response.isSuccessful) throw HttpException(response.code, "Download failed (${response.code})")
            val tmp = File(target.parentFile, target.name + ".part")
            (response.body?.byteStream() ?: throw IOException("Empty response")).use { input -> tmp.outputStream().use { input.copyTo(it, 64 * 1024) } }
            tmp.renameTo(target)
        }
    }
}

fun normalizedBase(raw: String): String? {
    var s = raw.trim()
    if (s.isEmpty()) return null
    if (!s.contains("://")) s = "http://$s"
    return s.trimEnd('/')
}

fun enc(s: String): String = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

fun buildUrl(base: String, path: String, query: Map<String, String?> = emptyMap()): String {
    val p = if (path.startsWith("/")) path else "/$path"
    val q = query.filterValues { it != null }.entries.joinToString("&") { (k, v) -> "${enc(k)}=${enc(v!!)}" }
    return base.trimEnd('/') + p + if (q.isEmpty()) "" else "?$q"
}
