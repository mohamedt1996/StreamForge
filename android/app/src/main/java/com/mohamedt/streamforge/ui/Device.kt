package com.mohamedt.streamforge.ui

import android.app.ActivityManager
import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import androidx.compose.runtime.staticCompositionLocalOf
import com.mohamedt.streamforge.BuildConfig
import com.mohamedt.streamforge.core.Settings

/** Settings → Interface. Stored as its [key] so an unknown value never breaks settings decoding. */
enum class InterfaceMode(val key: String, val label: String) {
    AUTO("auto", "Automatic"),
    TV("tv", "TV (remote)"),
    TOUCH("touch", "Touch");

    companion object {
        fun of(key: String?): InterfaceMode = entries.firstOrNull { it.key == key } ?: AUTO
    }
}

/**
 * Decides between the 10-foot (remote) interface and the touch interface.
 *
 * StreamForge ships as two apps (Gradle flavors, see app/build.gradle.kts):
 *  - the TV app ([BuildConfig.TV_BUILD]) always uses the TV interface, whatever the device reports
 *    and whatever a synced or old setting says, so a Google TV can never end up in the tablet layout;
 *  - the phone/tablet app always uses the touch interface (phone or tablet layout by width). Only an
 *    explicit "TV (remote)" choice in Settings → Interface switches it, e.g. for a TV box that the
 *    phone app was installed on by mistake. A stray D-pad / keyboard / gamepad press no longer flips it.
 */
object DeviceInput {
    @Volatile private var hardwareTv: Boolean? = null

    /** Kept for call sites that initialise early; nothing to load any more. */
    fun init(context: Context) = Unit

    /** True in the TV app (Android TV / Google TV build). */
    val tvBuild: Boolean get() = BuildConfig.TV_BUILD

    /** Hardware/system signals that this is a television-style device. Computed once per process. */
    fun isTvHardware(context: Context): Boolean {
        hardwareTv?.let { return it }
        val app = context.applicationContext
        val pm = app.packageManager
        val ui = app.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        val config = app.resources.configuration
        val result = runCatching {
            (ui?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) ||
                (config.uiMode and Configuration.UI_MODE_TYPE_MASK) == Configuration.UI_MODE_TYPE_TELEVISION ||
                pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
                pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK_ONLY) ||
                pm.hasSystemFeature(FEATURE_TELEVISION) ||
                pm.hasSystemFeature("amazon.hardware.fire_tv") ||
                (Build.MODEL ?: "").startsWith("AFT") ||
                !pm.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN) ||
                config.touchscreen == Configuration.TOUCHSCREEN_NOTOUCH
        }.getOrDefault(false)
        hardwareTv = result
        return result
    }

    /** The resolved choice, for code outside composition (e.g. picture-in-picture). */
    fun isTv(context: Context): Boolean = resolve(InterfaceMode.of(Settings.values.interfaceMode), isTvHardware(context))

    fun resolve(mode: InterfaceMode, hardware: Boolean): Boolean = when {
        tvBuild -> true
        mode == InterfaceMode.TV -> true
        mode == InterfaceMode.TOUCH -> false
        // Phone/tablet app on "Automatic": touch, unless it really is running on TV hardware.
        else -> hardware
    }

    /** PackageManager.FEATURE_TELEVISION (deprecated in the SDK, still reported by older TV builds). */
    private const val FEATURE_TELEVISION = "android.hardware.type.television"
}

/** Phone, tablet or TV: picks the layout family. Provided by [StreamForgeTheme]. */
enum class FormFactor { PHONE, TABLET, TV }

val LocalFormFactor = staticCompositionLocalOf { FormFactor.PHONE }

/**
 * Low-end device (Chromecast with Google TV: 2 GB RAM, 32-bit Android, small GPU; low-RAM phones).
 * Expensive eye candy (focus glows, autoplaying trailer WebViews, the heavier video renderer) is
 * switched off on these so scrolling and playback stay smooth.
 */
object Perf {
    @Volatile private var cached: Boolean? = null

    fun lowEnd(context: Context): Boolean {
        cached?.let { return it }
        val am = context.applicationContext.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val info = ActivityManager.MemoryInfo()
        runCatching { am?.getMemoryInfo(info) }
        val result = am?.isLowRamDevice == true ||
            (info.totalMem in 1 until 3_200_000_000L) ||
            Build.SUPPORTED_64_BIT_ABIS.isEmpty()
        cached = result
        return result
    }
}

val LocalLowEnd = staticCompositionLocalOf { false }

/** True when the 10-foot (remote) interface is active. Provided by [StreamForgeTheme]. */
val LocalTvMode = staticCompositionLocalOf { false }
