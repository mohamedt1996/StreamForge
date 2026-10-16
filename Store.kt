package com.mohamedt.streamforge.core

import android.content.Context
import android.content.SharedPreferences
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.decodeFromStream
import kotlinx.serialization.json.encodeToStream

/** Small JSON documents in the app's files dir, plus SharedPreferences for secrets and flags. */
object Store {
    lateinit var context: Context
        private set
    lateinit var prefs: SharedPreferences
        private set

    fun init(ctx: Context) {
        context = ctx.applicationContext
        prefs = context.getSharedPreferences("streamforge", Context.MODE_PRIVATE)
    }

    fun file(name: String): File = File(context.filesDir, name)
    fun cacheFile(name: String): File = File(context.cacheDir, name)

    fun <T> load(serializer: KSerializer<T>, name: String): T? = try {
        val f = file(name)
        if (f.exists()) AppJson.decodeFromString(serializer, f.readText()) else null
    } catch (_: Exception) {
        null
    }

    fun <T> save(serializer: KSerializer<T>, value: T, name: String) {
        try {
            val f = file(name)
            val tmp = File(f.parentFile, "$name.tmp")
            tmp.writeText(AppJson.encodeToString(serializer, value))
            tmp.renameTo(f)
        } catch (_: Exception) {
        }
    }

    /**
     * Big documents (the VOD library cache): gzip-compressed and streamed, so no giant String is built.
     * Blocking: call from Dispatchers.IO. Reads plain JSON written by older versions too.
     */
    @OptIn(ExperimentalSerializationApi::class)
    fun <T> loadLarge(serializer: KSerializer<T>, name: String): T? {
        val f = file(name)
        if (!f.exists()) return null
        return try {
            BufferedInputStream(FileInputStream(f), 64 * 1024).use { raw ->
                raw.mark(4)
                val b1 = raw.read()
                val b2 = raw.read()
                raw.reset()
                if (b1 == 0x1f && b2 == 0x8b) {
                    GZIPInputStream(raw, 64 * 1024).use { AppJson.decodeFromStream(serializer, it) }
                } else {
                    AppJson.decodeFromStream(serializer, raw)
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    /** Writes [loadLarge] documents (gzip, streamed, atomic rename). Blocking: call from Dispatchers.IO. */
    @OptIn(ExperimentalSerializationApi::class)
    fun <T> saveLarge(serializer: KSerializer<T>, value: T, name: String) {
        val f = file(name)
        // Unique temp name: two overlapping saves must not write into the same file.
        val tmp = File(f.parentFile, "$name.${System.nanoTime()}.tmp")
        try {
            GZIPOutputStream(BufferedOutputStream(FileOutputStream(tmp), 64 * 1024), 64 * 1024).use {
                AppJson.encodeToStream(serializer, value, it)
            }
            if (!tmp.renameTo(f)) tmp.delete()
        } catch (_: Exception) {
            tmp.delete()
        }
    }

    fun secret(key: String): String = prefs.getString("secret.$key", "") ?: ""
    fun setSecret(key: String, value: String) = prefs.edit().putString("secret.$key", value).apply()
}
