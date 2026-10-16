package com.mohamedt.streamforge.ui

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.widget.FrameLayout
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

// Netflix-style hero trailers: the hero shows its backdrop first; after a short delay (only while
// the hero is on screen, the app is in front and nothing covers it, on an unmetered network
// without Data Saver) a muted trailer fades in over it, edge to edge, with no player chrome.
// It pauses whenever the host says it isn't active and resumes when it is again. At the end it
// fades back to the artwork and offers replay (phones/tablets). Unmuting lasts for the session.
//
// Playback uses YouTube's iframe player in a chrome-less, non-interactive WebView (the app has
// no YouTube-capable native player). Each trailer id is tried in turn; any failure is silent.

object TrailerPolicy {
    const val START_DELAY_MS = 2500L
    const val FADE_MS = 800
    /** Give up when nothing has played after this much on-screen time. */
    const val LOAD_TIMEOUT_MS = 15_000L

    /** Unmuting sticks for the rest of the session (never persisted: a relaunch starts silent). */
    @Volatile
    var sessionPrefersSound = false

    /** No trailers on metered networks (mobile data, hotspots) or with Data Saver on. */
    fun allowsAutoplay(context: Context): Boolean {
        if (!com.mohamedt.streamforge.core.Settings.values.trailerAutoplay) return false
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return false
        return runCatching {
            cm.activeNetwork != null && !cm.isActiveNetworkMetered &&
                cm.restrictBackgroundStatus != ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED
        }.getOrDefault(false)
    }
}

/** A WebView that never takes touches or focus, so the list still scrolls and TV focus is untouched. */
private class TrailerWebView(context: Context) : WebView(context) {
    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean = false
    override fun dispatchTouchEvent(event: MotionEvent): Boolean = false
}

class TrailerController(private val context: Context) {
    enum class Phase { IDLE, LOADING, PLAYING, ENDED, UNAVAILABLE }

    var phase by mutableStateOf(Phase.IDLE)
        private set
    var muted by mutableStateOf(true)
        private set
    var webView by mutableStateOf<WebView?>(null)
        private set

    /** True while the video covers the artwork. */
    val revealed: Boolean get() = phase == Phase.PLAYING

    private val main = Handler(Looper.getMainLooper())
    private var keys: List<String> = emptyList()
    private var isActive = false
    private var generation = 0
    private var startToken = 0
    private var loadingMs = 0L
    private var playingSince = 0L

    /** Trailer ids for the current title, best first. New ids reset everything. */
    fun updateKeys(newKeys: List<String>, delayMs: Long = TrailerPolicy.START_DELAY_MS) {
        val cleaned = newKeys.filter { it.isNotEmpty() }.distinct()
        if (cleaned == keys) return
        reset()
        keys = cleaned
        scheduleStart(delayMs)
    }

    /** Whether the hero is on screen and uncovered. Pauses / resumes. */
    fun updateActive(value: Boolean) {
        if (value == isActive) return
        isActive = value
        if (value) {
            when (phase) {
                Phase.IDLE -> scheduleStart(TrailerPolicy.START_DELAY_MS)
                Phase.LOADING, Phase.PLAYING -> js("sfPlay()")
                Phase.ENDED, Phase.UNAVAILABLE -> Unit
            }
        } else {
            startToken++
            js("sfPause()")
        }
    }

    fun toggleMute() {
        muted = !muted
        TrailerPolicy.sessionPrefersSound = !muted
        js("sfMute($muted)")
    }

    fun replay() {
        if (phase != Phase.ENDED || webView == null) return
        muted = !TrailerPolicy.sessionPrefersSound
        js("sfMute($muted)")
        loadingMs = 0L
        playingSince = 0L
        phase = Phase.LOADING
        js("sfReplay()")
        if (!isActive) js("sfPause()")
        startMonitor()
    }

    fun release() = reset()

    private fun reset() {
        generation++
        startToken++
        main.removeCallbacksAndMessages(null)
        destroyWeb()
        keys = emptyList()
        loadingMs = 0L
        playingSince = 0L
        phase = Phase.IDLE
    }

    private fun scheduleStart(delayMs: Long) {
        if (!isActive || phase != Phase.IDLE || keys.isEmpty()) return
        val token = ++startToken
        main.postDelayed({
            if (token == startToken && isActive && phase == Phase.IDLE && TrailerPolicy.allowsAutoplay(context)) begin()
        }, delayMs.coerceAtLeast(0L))
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun begin() {
        phase = Phase.LOADING
        muted = !TrailerPolicy.sessionPrefersSound
        loadingMs = 0L
        playingSince = 0L
        // Some TV boxes ship without a working WebView: stay on the artwork quietly.
        val web: WebView = try {
            TrailerWebView(context)
        } catch (_: Throwable) {
            phase = Phase.UNAVAILABLE
            return
        }
        web.settings.javaScriptEnabled = true
        web.settings.domStorageEnabled = true
        web.settings.mediaPlaybackRequiresUserGesture = false
        web.setBackgroundColor(android.graphics.Color.TRANSPARENT)
        web.isVerticalScrollBarEnabled = false
        web.isHorizontalScrollBarEnabled = false
        web.isFocusable = false
        web.isFocusableInTouchMode = false
        web.descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
        web.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        web.webChromeClient = WebChromeClient()
        web.addJavascriptInterface(Bridge(generation), "SFTrailer")
        // The page must identify the app, not YouTube: a page whose origin is YouTube itself gets
        // "Video unavailable" (error 152) and one without an origin gets error 153. YouTube's
        // documented identity for an app WebView is https://<application id>, sent as the Referer.
        web.loadDataWithBaseURL("$APP_ORIGIN/", trailerHtml(keys.take(4), muted), "text/html", "utf-8", null)
        webView = web
        if (!isActive) js("sfPause()")
        startMonitor()
    }

    /** Called by the page's script on a binder thread; hops to the main thread. */
    private inner class Bridge(private val gen: Int) {
        @JavascriptInterface
        fun post(message: String) {
            main.post { if (gen == generation) onEvent(message) }
        }
    }

    private fun onEvent(message: String) {
        when (message) {
            "playing" -> {
                if (phase == Phase.LOADING && playingSince == 0L) playingSince = SystemClock.uptimeMillis()
                if (!isActive) js("sfPause()")
            }
            "ended" -> if (phase == Phase.LOADING || phase == Phase.PLAYING) finish()
            "failed" -> when (phase) {
                Phase.LOADING -> giveUp()
                Phase.PLAYING -> finish()
                else -> Unit
            }
        }
    }

    /** Reveals the video a moment after YouTube reports playing (its title overlay is gone by then) and enforces the load timeout. */
    private fun startMonitor() {
        val gen = generation
        main.postDelayed(object : Runnable {
            override fun run() {
                if (gen != generation || phase != Phase.LOADING) return
                if (isActive) loadingMs += 250
                if (playingSince > 0L && SystemClock.uptimeMillis() - playingSince > 1000) {
                    phase = Phase.PLAYING
                    return
                }
                if (loadingMs > TrailerPolicy.LOAD_TIMEOUT_MS) {
                    giveUp()
                    return
                }
                main.postDelayed(this, 250)
            }
        }, 250)
    }

    private fun finish() {
        phase = Phase.ENDED
        js("sfPause()")
    }

    private fun giveUp() {
        destroyWeb()
        phase = Phase.UNAVAILABLE
    }

    private fun js(code: String) {
        webView?.evaluateJavascript("try{$code}catch(e){}", null)
    }

    private fun destroyWeb() {
        val w = webView ?: return
        webView = null
        runCatching {
            w.evaluateJavascript("try{sfPause()}catch(e){}", null)
            w.removeJavascriptInterface("SFTrailer")
            w.stopLoading()
            (w.parent as? ViewGroup)?.removeView(w)
            w.destroy()
        }
    }
}

/** The app's identity for YouTube's embedded player (fixed, so debug builds match too). */
private const val APP_ORIGIN = "https://com.mohamedt.streamforge"

private fun trailerHtml(keys: List<String>, muted: Boolean): String {
    val safe = keys.map { k -> k.filter { it.isLetterOrDigit() && it.code < 128 || it == '-' || it == '_' } }.filter { it.isNotEmpty() }
    val list = safe.joinToString(",", "[", "]") { "\"" + it + "\"" }
    val mutedJs = if (muted) "true" else "false"
    return """
<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<meta name="referrer" content="strict-origin-when-cross-origin">
<style>
html,body{margin:0;padding:0;background:#000;overflow:hidden;width:100%;height:100%;}
#wrap{position:absolute;top:50%;left:50%;width:max(100vw,177.78vh);height:max(100vh,56.25vw);
      transform:translate(-50%,-50%) scale(1.18);pointer-events:none;}
#wrap iframe,#p{width:100%;height:100%;border:0;pointer-events:none;}
</style></head><body><div id="wrap"><div id="p"></div></div>
<script>
var keys=$list,idx=0,player=null,muted=$mutedJs,want=true,done=false,started=false;
function post(m){try{window.SFTrailer.post(m);}catch(e){}}
if(!keys.length){post('failed');}
function onYouTubeIframeAPIReady(){
  if(!keys.length)return;
  player=new YT.Player('p',{host:'https://www.youtube-nocookie.com',videoId:keys[0],
    playerVars:{autoplay:1,mute:1,controls:0,playsinline:1,modestbranding:1,rel:0,iv_load_policy:3,
                disablekb:1,fs:0,cc_load_policy:0,enablejsapi:1,origin:'$APP_ORIGIN'},
    events:{
      onReady:function(e){if(muted){e.target.mute();}else{e.target.unMute();} if(want){e.target.playVideo();}},
      onStateChange:function(e){
        if(e.data===1){ if(!want){player.pauseVideo();return;} if(!started){started=true;post('playing');} }
        else if(e.data===0){finish();}
      },
      onError:function(){next();}
    }});
}
function next(){idx++;started=false;if(idx<keys.length){player.loadVideoById(keys[idx]);}else{post('failed');}}
function finish(){if(done)return;done=true;try{player.pauseVideo();}catch(e){}post('ended');}
setInterval(function(){try{
  if(!player||!player.getDuration||done||!started)return;
  var d=player.getDuration(),t=player.getCurrentTime();
  if(d>1&&t>0&&d-t<0.9){finish();}
}catch(e){}},250);
function sfPlay(){want=true;if(player&&!done&&player.playVideo)player.playVideo();}
function sfPause(){want=false;if(player&&player.pauseVideo)player.pauseVideo();}
function sfMute(m){muted=m;if(player&&player.mute){if(m){player.mute();}else{player.unMute();}}}
function sfReplay(){if(!player||!player.seekTo)return;done=false;started=false;want=true;player.seekTo(0,true);player.playVideo();}
</script>
<script src="https://www.youtube.com/iframe_api" onerror="post('failed')"></script>
</body></html>
"""
}

@Composable
fun rememberTrailerController(): TrailerController {
    val context = LocalContext.current
    val controller = remember { TrailerController(context) }
    DisposableEffect(controller) { onDispose { controller.release() } }
    return controller
}

/** The video layer: put it over the artwork; it fades in when the trailer plays and out at the end. */
@Composable
fun TrailerSurface(controller: TrailerController, modifier: Modifier = Modifier) {
    val alpha by animateFloatAsState(if (controller.revealed) 1f else 0f, tween(TrailerPolicy.FADE_MS), label = "trailer-fade")
    val web = controller.webView ?: return
    AndroidView(
        factory = { ctx ->
            FrameLayout(ctx).apply {
                isFocusable = false
                descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                clipChildren = true
            }
        },
        update = { frame ->
            if (web.parent !== frame) {
                (web.parent as? ViewGroup)?.removeView(web)
                frame.removeAllViews()
                frame.addView(web, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            }
            frame.alpha = alpha
        },
        modifier = modifier,
    )
}

/** Round mute/unmute button while the trailer plays, replay once it ended. Phones/tablets only (TV focus stays as it was). */
@Composable
fun TrailerButton(controller: TrailerController, modifier: Modifier = Modifier) {
    if (isTv()) return
    val phase = controller.phase
    if (phase != TrailerController.Phase.PLAYING && phase != TrailerController.Phase.ENDED) return
    val playing = phase == TrailerController.Phase.PLAYING
    Box(
        modifier
            .size(38.dp)
            .clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.35f))
            .border(1.dp, Color.White.copy(alpha = 0.7f), CircleShape)
            .clickable { if (playing) controller.toggleMute() else controller.replay() },
        contentAlignment = Alignment.Center,
    ) {
        val icon = when {
            !playing -> Icons.Filled.Replay
            controller.muted -> Icons.AutoMirrored.Filled.VolumeOff
            else -> Icons.AutoMirrored.Filled.VolumeUp
        }
        val label = when {
            !playing -> "Replay trailer"
            controller.muted -> "Unmute trailer"
            else -> "Mute trailer"
        }
        Icon(icon, label, tint = Color.White, modifier = Modifier.size(18.dp))
    }
}
