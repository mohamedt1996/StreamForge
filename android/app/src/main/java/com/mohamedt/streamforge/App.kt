package com.mohamedt.streamforge

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import com.mohamedt.streamforge.core.Store
import com.mohamedt.streamforge.dispatcharr.DispatcharrRepo
import com.mohamedt.streamforge.dispatcharr.GuideRepo
import com.mohamedt.streamforge.stremio.Addons
import com.mohamedt.streamforge.sync.ServerSync
import com.mohamedt.streamforge.torrent.TorrServer
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

    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context)
            .components { add(OkHttpNetworkFetcherFactory()) }
            .build()
}
