package com.mohamedt.streamforge.core

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.mohamedt.streamforge.sync.RemoteSync
import kotlinx.serialization.Serializable

@Serializable
data class SettingsValues(
    // Torrents
    val torrentEmbedded: Boolean = true,
    val remoteTorrServer: String = "",
    val torrServerUser: String = "",
    val torrCacheMb: Int = 256,
    // Metadata
    val metadataLanguage: String = java.util.Locale.getDefault().language.ifEmpty { "en" },
    val hideAdult: Boolean = true,
    // Player
    val hwdec: String = "mediacodec",
    val audioLanguage: String = java.util.Locale.getDefault().language.ifEmpty { "en" },
    val subtitleLanguage: String = java.util.Locale.getDefault().language.ifEmpty { "en" },
    val autoSubtitles: Boolean = false,
    val subtitleScale: Float = 1.0f,
    val subtitleColor: String = "#FFFFFFFF",
    val subtitleBackground: Boolean = false,
    val subtitleBold: Boolean = false,
    val subtitlePosition: Int = 100,
    val seekStep: Int = 10,
    val autoplayNext: Boolean = true,
    val skipIntros: Boolean = true,
    val autoSkip: Boolean = false,
    val nightMode: Boolean = false,
    val cacheMb: Int = 150,
    val liveBufferSeconds: Int = 4,
    val timeshiftMinutes: Int = 30,
    val userAgent: String = "",
    // Streams
    val maxResolution: Int = 2160,
    val excludeCam: Boolean = true,
    // Live TV
    val showChannelNumbers: Boolean = true,
    val guideDays: Int = 3,
    // Detail pages
    val trailerAutoplay: Boolean = true,
)

object Settings {
    var values by mutableStateOf(Store.load(SettingsValues.serializer(), "settings.json") ?: SettingsValues())
        private set

    fun update(transform: (SettingsValues) -> SettingsValues) {
        values = transform(values)
        Store.save(SettingsValues.serializer(), values, "settings.json")
        RemoteSync.changed()
    }

    var tmdbKey: String
        get() = Store.secret("tmdb")
        set(v) {
            Store.setSecret("tmdb", v.trim())
            RemoteSync.changed()
        }

    var torrServerPassword: String
        get() = Store.secret("torrserver.password")
        set(v) = Store.setSecret("torrserver.password", v)
}
