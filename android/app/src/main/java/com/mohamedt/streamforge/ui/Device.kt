package com.mohamedt.streamforge.ui

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
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
 * Hardware detection alone isn't enough: plenty of Android TV boxes, projectors and Google TV /
 * Fire TV variants don't report UI_MODE_TYPE_TELEVISION (and some even claim a touchscreen). So:
 *  1. the hardware signals below are checked once,
 *  2. in Automatic mode a D-pad press from a remote switches to the TV interface (and a real touch
 *     switches back); the last one is remembered across launches,
 *  3. Settings → Interface can force either one.
 */
object DeviceInput {
    private const val PREFS = "device_input"
    private const val KEY_REMOTE = "remote_seen"

    @Volatile private var hardwareTv: Boolean? = null
    private var prefs: android.content.SharedPreferences? = null

    /** Automatic mode: true after remote (D-pad) input, false after a touch, null before either. */
    var remoteSeen by mutableStateOf<Boolean?>(null)
        private set

    fun init(context: Context) {
        if (prefs != null) return
        val p = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs = p
        if (p.contains(KEY_REMOTE)) remoteSeen = p.getBoolean(KEY_REMOTE, false)
    }

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
                config.touchscreen == Configuration.TOUCHSCREEN_NOTOUCH ||
                (config.navigation == Configuration.NAVIGATION_DPAD && config.touchscreen != Configuration.TOUCHSCREEN_FINGER)
        }.getOrDefault(false)
        hardwareTv = result
        return result
    }

    /** The resolved choice, for code outside composition (e.g. picture-in-picture). */
    fun isTv(context: Context): Boolean {
        init(context)
        return resolve(InterfaceMode.of(Settings.values.interfaceMode), isTvHardware(context))
    }

    fun resolve(mode: InterfaceMode, hardware: Boolean): Boolean = when (mode) {
        InterfaceMode.TV -> true
        InterfaceMode.TOUCH -> false
        InterfaceMode.AUTO -> hardware || remoteSeen == true
    }

    /** Call for every key event: a D-pad press from a remote / gamepad switches Automatic mode to TV. */
    fun onKey(event: KeyEvent) {
        if (event.action != KeyEvent.ACTION_DOWN || remoteSeen == true) return
        val dpad = when (event.keyCode) {
            KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_DPAD_LEFT,
            KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_DPAD_CENTER -> true
            else -> false
        }
        if (!dpad) return
        // Arrow keys of a real (alphabetic) keyboard on a tablet don't count.
        val device = event.device
        if (device != null && device.keyboardType == InputDevice.KEYBOARD_TYPE_ALPHABETIC && event.keyCode != KeyEvent.KEYCODE_DPAD_CENTER) return
        store(true)
    }

    /** Call for touch events: a finger on a touchscreen switches Automatic mode back to touch. */
    fun onTouch(event: MotionEvent) {
        if (event.actionMasked != MotionEvent.ACTION_DOWN || remoteSeen != true) return
        if (!event.isFromSource(InputDevice.SOURCE_TOUCHSCREEN)) return
        if (event.getToolType(0) != MotionEvent.TOOL_TYPE_FINGER) return
        store(false)
    }

    private fun store(remote: Boolean) {
        remoteSeen = remote
        prefs?.edit()?.putBoolean(KEY_REMOTE, remote)?.apply()
    }

    /** PackageManager.FEATURE_TELEVISION (deprecated in the SDK, still reported by older TV builds). */
    private const val FEATURE_TELEVISION = "android.hardware.type.television"
}

/** True when the 10-foot (remote) interface is active. Provided by [StreamForgeTheme]. */
val LocalTvMode = staticCompositionLocalOf { false }
