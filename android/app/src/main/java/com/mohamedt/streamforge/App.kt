package com.mohamedt.streamforge

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.memory.MemoryCache
import coil3.request.allowRgb565
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import com.mohamedt.streamforge.core.Store
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.dispatcharr.GuideRepo
import com.mohamedt.streamforge.stremio.Addons
import com.mohamedt.streamforge.sync.ServerSync
import com.mohamedt.streamforge.torrent.TorrServer
import com.mohamedt.streamforge.ui.Perf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class App : Application(), SingletonImageLoader.Factory {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onCreate() {
        super.onCreate()
        Store.init(this)
        Addons.init()
        GuideRepo.init()
        DispatcharrRepo.init()
        // After the stores: diffs their data against the last sync and pulls while the app is in the foreground.
        ServerSync.init()
        scope.launch {
            delay(2000)
            TorrServer.startEmbeddedIfNeeded()
        }
        // Back from another app: drop HTTP connections that died meanwhile and check the torrent engine,
        // so starting anything after returning never reuses a stale socket or a dead engine.
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                scope.launch { runCatching { TorrServer.returnedToForeground() } }
            }

            override fun onStop(owner: LifecycleOwner) {
                TorrServer.noteBackground()
            }
        })
    }

    override fun newImageLoader(context: PlatformContext): ImageLoader {
        // Low-end devices (Chromecast with Google TV, 2 GB RAM): a smaller in-memory image cache so
        // rows don't push the app into garbage-collection pauses, and opaque artwork (posters,
        // backdrops) decoded as RGB_565, half the memory. Logos keep their transparency.
        val lowEnd = Perf.lowEnd(context)
        return ImageLoader.Builder(context)
            .components { add(OkHttpNetworkFetcherFactory()) }
            .memoryCache { MemoryCache.Builder().maxSizePercent(context, if (lowEnd) 0.15 else 0.25).build() }
            .allowRgb565(lowEnd)
            .build()
    }
}
