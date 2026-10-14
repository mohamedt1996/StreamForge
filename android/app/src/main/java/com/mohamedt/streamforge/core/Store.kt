package com.mohamedt.streamforge.core

import android.content.Context
import android.content.SharedPreferences
import java.io.File
import kotlinx.serialization.KSerializer

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

    fun secret(key: String): String = prefs.getString("secret.$key", "") ?: ""
    fun setSecret(key: String, value: String) = prefs.edit().putString("secret.$key", value).apply()
}
