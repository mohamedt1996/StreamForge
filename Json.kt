package com.mohamedt.streamforge.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

/** IPTV and addon APIs are loose with types ("1" vs 1 vs null), so everything is read tolerantly. */
val AppJson = Json {
    ignoreUnknownKeys = true
    isLenient = true
    coerceInputValues = true
    explicitNulls = false
    encodeDefaults = true
}

fun parseJson(text: String): JsonElement? = try {
    AppJson.parseToJsonElement(text)
} catch (_: Exception) {
    null
}

fun JsonElement?.obj(): JsonObject? = this as? JsonObject
fun JsonElement?.arr(): JsonArray? = this as? JsonArray

fun JsonObject.str(key: String): String? {
    val p = this[key] as? JsonPrimitive ?: return null
    if (p is JsonNull) return null
    val s = p.content.trim()
    return if (s.isEmpty() || s == "null") null else s
}

fun JsonObject.long(key: String): Long? {
    val p = this[key] as? JsonPrimitive ?: return null
    if (p is JsonNull) return null
    p.longOrNull?.let { return it }
    p.doubleOrNull?.let { return it.toLong() }
    p.booleanOrNull?.let { return if (it) 1 else 0 }
    return p.content.trim().toDoubleOrNull()?.toLong()
}

fun JsonObject.int(key: String): Int? = long(key)?.toInt()

fun JsonObject.dbl(key: String): Double? {
    val p = this[key] as? JsonPrimitive ?: return null
    if (p is JsonNull) return null
    p.doubleOrNull?.let { return it }
    return p.content.replace(",", ".").trim().toDoubleOrNull()
}

fun JsonObject.bool(key: String): Boolean {
    val p = this[key] as? JsonPrimitive ?: return false
    p.booleanOrNull?.let { return it }
    return (long(key) ?: 0L) != 0L
}

fun JsonObject.child(key: String): JsonObject? = this[key] as? JsonObject
fun JsonObject.list(key: String): List<JsonElement> = (this[key] as? JsonArray)?.toList() ?: emptyList()
fun JsonObject.objects(key: String): List<JsonObject> = list(key).mapNotNull { it as? JsonObject }

/** A string array, or a single string treated as a one-element list. */
fun JsonObject.strings(key: String): List<String> {
    val v = this[key] ?: return emptyList()
    return when (v) {
        is JsonArray -> v.mapNotNull { (it as? JsonPrimitive)?.content?.takeIf { s -> s.isNotBlank() && s != "null" } }
        is JsonPrimitive -> v.content.takeIf { it.isNotBlank() && it != "null" && v !is JsonNull }?.let { listOf(it) } ?: emptyList()
        else -> emptyList()
    }
}

fun String.base64Decoded(): String = try {
    String(android.util.Base64.decode(this, android.util.Base64.DEFAULT), Charsets.UTF_8)
} catch (_: Exception) {
    this
}
