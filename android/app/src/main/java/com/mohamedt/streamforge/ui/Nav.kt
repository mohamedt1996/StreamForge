package com.mohamedt.streamforge.ui

import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.mutableStateListOf
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.MediaType
import com.mohamedt.streamforge.stremio.Addons

enum class Tab(val title: String) { HOME("Home"), LIVE("Live TV"), MOVIES("Movies"), SERIES("Series"), SEARCH("Search"), ACTIVITY("Activity"), SETTINGS("Settings") }

sealed interface Screen {
    data class Detail(val item: MediaItem) : Screen
    data class Person(val id: Int?, val name: String) : Screen
    data class Collection(val id: Int, val name: String) : Screen
    data class Catalog(val entry: Addons.CatalogEntry) : Screen
    data class Category(val kind: MediaType, val categoryId: String, val title: String) : Screen
    data object Guide : Screen
    data object Recordings : Screen
}

/** A tiny back stack: tabs at the root, pushed screens on top. */
class Navigator {
    val stack = mutableStateListOf<Screen>()
    fun push(s: Screen) { stack.add(s) }
    fun pop(): Boolean = if (stack.isNotEmpty()) { stack.removeAt(stack.lastIndex); true } else false
    fun clear() = stack.clear()
}

val LocalNav = compositionLocalOf { Navigator() }
