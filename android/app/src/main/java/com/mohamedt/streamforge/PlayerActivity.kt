package com.mohamedt.streamforge

import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.view.KeyEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.mohamedt.streamforge.core.Settings
import com.mohamedt.streamforge.player.Player
import com.mohamedt.streamforge.player.PlayerController
import com.mohamedt.streamforge.player.PlayerScreen
import com.mohamedt.streamforge.ui.StreamForgeTheme

class PlayerActivity : ComponentActivity() {
    private var controller: PlayerController? = null
    private var inPip by mutableStateOf(false)
    /** Bumped on remote/keyboard input so the overlay shows its controls. */
    var interaction by mutableStateOf(0L)
        private set

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val request = Player.pending
        if (request == null) { finish(); return }
        Player.pending = null
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        val c = PlayerController(this, request)
        controller = c
        val surface = SurfaceView(this)
        surface.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) = c.mpv.attach(holder.surface)
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = c.mpv.setSurfaceSize(width, height)
            override fun surfaceDestroyed(holder: SurfaceHolder) = c.mpv.detach()
        })
        setContent {
            StreamForgeTheme {
                PlayerScreen(c, surface, inPip, interaction, onClose = { finish() }, onPip = { enterPip() })
            }
        }
    }

    private val supportsPip: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE) &&
            (resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK) != Configuration.UI_MODE_TYPE_TELEVISION

    fun enterPip() {
        if (!supportsPip) return
        runCatching { enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9)).build()) }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        val c = controller ?: return
        if (c.started && !c.paused) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        inPip = isInPictureInPictureMode
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val c = controller ?: return super.onKeyDown(keyCode, event)
        interaction = System.currentTimeMillis()
        val step = Settings.values.seekStep * 1000L
        when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_PLAY, KeyEvent.KEYCODE_MEDIA_PAUSE -> { c.togglePause(); return true }
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> { c.seekBy(step); return true }
            KeyEvent.KEYCODE_MEDIA_REWIND -> { c.seekBy(-step); return true }
            KeyEvent.KEYCODE_CHANNEL_UP -> { c.zap(-1); return true }
            KeyEvent.KEYCODE_CHANNEL_DOWN -> { c.zap(1); return true }
            KeyEvent.KEYCODE_LAST_CHANNEL -> { c.lastChannel(); return true }
            KeyEvent.KEYCODE_MEDIA_NEXT -> { if (c.isLive) c.zap(1) else c.playNextEpisode(); return true }
            KeyEvent.KEYCODE_MEDIA_PREVIOUS -> { if (c.isLive) c.zap(-1) else c.seekTo(0); return true }
            in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 -> { c.typeDigit(keyCode - KeyEvent.KEYCODE_0); return true }
            in KeyEvent.KEYCODE_NUMPAD_0..KeyEvent.KEYCODE_NUMPAD_9 -> { c.typeDigit(keyCode - KeyEvent.KEYCODE_NUMPAD_0); return true }
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onStop() {
        super.onStop()
        controller?.saveProgress(force = true)
    }

    override fun onDestroy() {
        controller?.release()
        controller = null
        super.onDestroy()
    }
}
