package com.mohamedt.streamforge.dispatcharr

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.Settings
import com.mohamedt.streamforge.core.Store
import com.mohamedt.streamforge.core.TitleCleaner
import java.security.SecureRandom
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

data class CategorySection(val name: String, val categories: List<Category>)

sealed interface LoadState {
    data object Idle : LoadState
    data object Loading : LoadState
    data object Loaded : LoadState
    data class Failed(val message: String) : LoadState
}

@Serializable
private data class DiskCache(
    val liveCategories: List<Category>,
    val channels: List<Channel>,
    val movieCategories: List<Category>,
    val movies: List<Movie>,
    val seriesCategories: List<Category>,
    val series: List<Series>,
    val savedAt: Long,
)

/** Everything loaded from the active Dispatcharr server, cached on disk for an instant start. */
object DispatcharrRepo {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    var servers by mutableStateOf(Store.load(ListSerializer(Server.serializer()), "servers.json") ?: emptyList())
        private set
    var activeId by mutableStateOf(Store.prefs.getString("active.server", null))
        private set

    var liveCategories by mutableStateOf<List<Category>>(emptyList()); private set
    var channels by mutableStateOf<List<Channel>>(emptyList()); private set
    var channelsByCategory by mutableStateOf<Map<String, List<Channel>>>(emptyMap()); private set
    var movieCategories by mutableStateOf<List<Category>>(emptyList()); private set
    var seriesCategories by mutableStateOf<List<Category>>(emptyList()); private set
    var movieItems by mutableStateOf<List<MediaItem>>(emptyList()); private set
    var seriesItems by mutableStateOf<List<MediaItem>>(emptyList()); private set
    var movieSections by mutableStateOf<List<CategorySection>>(emptyList()); private set
    var seriesSections by mutableStateOf<List<CategorySection>>(emptyList()); private set
    var movieGenres by mutableStateOf<List<String>>(emptyList()); private set
    var seriesGenres by mutableStateOf<List<String>>(emptyList()); private set
    var liveState by mutableStateOf<LoadState>(LoadState.Idle); private set
    var vodState by mutableStateOf<LoadState>(LoadState.Idle); private set
    var lastRefresh by mutableStateOf(0L); private set

    private var rawMovies: List<Movie> = emptyList()
    private var rawSeries: List<Series> = emptyList()
    private var rest: DispatcharrRest? = null

    val active: Server? get() = servers.firstOrNull { it.id == activeId } ?: servers.firstOrNull()
    val client: XtreamClient? get() = active?.let { XtreamClient(it) }
    val isConfigured: Boolean get() = active != null

    fun restClient(): DispatcharrRest? {
        val s = active ?: return null
        if (!s.hasRest) return null
        return rest ?: DispatcharrRest(s).also { rest = it }
    }

    fun init() {
        loadDiskCache()
        refreshAll()
    }

    // MARK: Servers

    /**
     * Signs in and saves the server. Account / API-key logins read the XC password from
     * /api/accounts/users/me/; admins without one get a generated XC password.
     */
    suspend fun connect(draft: Server, xcPassword: String, webPassword: String, apiKey: String): String {
        draft.webPassword = webPassword
        draft.apiKey = apiKey
        var server = draft
        var note = "Connected"
        if (draft.authMode != AuthMode.XC) {
            val rest = DispatcharrRest(draft)
            rest.login()
            val me = rest.me()
            if (draft.authMode == AuthMode.API_KEY && draft.username.isEmpty()) server = draft.copy(username = me.username)
            var xc = me.xcPassword
            if (xc.isNullOrEmpty()) {
                if (me.userLevel >= 10 && me.id != null) {
                    xc = generatePassword()
                    rest.setXcPassword(me.id, xc)
                    note = "Connected · created an XC password for streaming"
                } else {
                    throw IllegalStateException("Your Dispatcharr user has no XC password. Ask an admin to set one (Users → edit → XC Password).")
                }
            }
            server.xcPassword = xc
        } else {
            server.xcPassword = xcPassword
        }
        XtreamClient(server).authenticate()
        withContext(Dispatchers.Main) { upsert(server) }
        return note
    }

    private fun generatePassword(): String {
        val chars = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        val r = SecureRandom()
        return (1..16).map { chars[r.nextInt(chars.length)] }.joinToString("")
    }

    private fun upsert(server: Server) {
        servers = servers.filter { it.id != server.id } + server
        Store.save(ListSerializer(Server.serializer()), servers, "servers.json")
        activate(server.id)
    }

    fun remove(server: Server) {
        servers = servers.filter { it.id != server.id }
        Store.save(ListSerializer(Server.serializer()), servers, "servers.json")
        Store.file(cacheName(server.id)).delete()
        if (activeId == server.id) activate(servers.firstOrNull()?.id)
    }

    fun activate(id: String?) {
        activeId = id
        Store.prefs.edit().putString("active.server", id).apply()
        rest = null
        clear()
        loadDiskCache()
        refreshAll(force = true)
    }

    private fun clear() {
        liveCategories = emptyList(); channels = emptyList(); channelsByCategory = emptyMap()
        movieCategories = emptyList(); seriesCategories = emptyList(); movieItems = emptyList(); seriesItems = emptyList()
        movieSections = emptyList(); seriesSections = emptyList(); movieGenres = emptyList(); seriesGenres = emptyList()
        rawMovies = emptyList(); rawSeries = emptyList()
        liveState = LoadState.Idle; vodState = LoadState.Idle
    }

    // MARK: Loading

    fun refreshAll(force: Boolean = false) {
        val c = client ?: return
        if (!force && System.currentTimeMillis() - lastRefresh < 15 * 60_000 && channels.isNotEmpty()) return
        scope.launch {
            if (channels.isEmpty()) liveState = LoadState.Loading
            if (movieItems.isEmpty() && seriesItems.isEmpty()) vodState = LoadState.Loading
            val live = async(Dispatchers.IO) { runCatching { c.liveCategories() to c.channels() } }
            val vod = async(Dispatchers.IO) {
                runCatching { listOf(c.vodCategories(), c.seriesCategories()) to (c.movies() to c.series()) }
            }
            live.await().onSuccess { (cats, ch) -> applyLive(cats, ch); liveState = LoadState.Loaded }
                .onFailure { if (channels.isEmpty()) liveState = LoadState.Failed(it.message ?: "Couldn't load channels") }
            vod.await().onSuccess { (cats, data) -> applyVod(cats[0], data.first, cats[1], data.second); vodState = LoadState.Loaded }
                .onFailure { if (movieItems.isEmpty()) vodState = LoadState.Failed(it.message ?: "Couldn't load the library") }
            lastRefresh = System.currentTimeMillis()
            saveDiskCache()
            GuideRepo.refreshIfStale()
        }
    }

    private fun applyLive(cats: List<Category>, list: List<Channel>) {
        val hideAdult = Settings.values.hideAdult
        val visible = list.filter { !(hideAdult && it.isAdult) }
            .sortedWith(compareBy<Channel> { it.number ?: Int.MAX_VALUE }.thenBy { it.name })
        channels = visible
        val grouped = visible.groupBy { it.categoryId }.toMutableMap()
        val known = cats.filter { grouped[it.id]?.isNotEmpty() == true }.toMutableList()
        val knownIds = known.map { it.id }.toSet()
        val orphans = visible.filter { it.categoryId !in knownIds }
        if (orphans.isNotEmpty()) {
            grouped["__other"] = orphans
            known.add(Category("__other", "Other"))
        }
        channelsByCategory = grouped
        liveCategories = known
    }

    private suspend fun applyVod(mc: List<Category>, movies: List<Movie>, sc: List<Category>, series: List<Series>) {
        val sid = active?.id ?: return
        val hideAdult = Settings.values.hideAdult
        val result = withContext(Dispatchers.Default) {
            val m = dedupeMovies(movies.filter { !(hideAdult && it.isAdult) })
            val s = dedupeSeries(series)
            val mItems = m.map { it.toItem(sid) }
            val sItems = s.map { it.toItem(sid) }
            val mCats = m.map { it.categoryId }.toSet()
            val sCats = s.map { it.categoryId }.toSet()
            Triple(m to s, mItems to sItems, mc.filter { it.id in mCats } to sc.filter { it.id in sCats })
        }
        rawMovies = result.first.first
        rawSeries = result.first.second
        movieItems = result.second.first
        seriesItems = result.second.second
        movieCategories = result.third.first
        seriesCategories = result.third.second
        movieSections = sections(movieCategories)
        seriesSections = sections(seriesCategories)
        movieGenres = genres(rawMovies.mapNotNull { it.genre })
        seriesGenres = genres(rawSeries.mapNotNull { it.genre })
    }

    /** Providers list the same film in several categories; keep one per id or title+year. */
    private fun dedupeMovies(list: List<Movie>): List<Movie> {
        val seen = HashSet<String>()
        return list.filter { m ->
            val key = m.tmdbId?.let { "tmdb$it" } ?: m.imdbId?.takeIf { it.isNotEmpty() }
                ?: TitleCleaner.clean(m.name).let { (t, y) -> "${t.lowercase()}|${y ?: m.year ?: 0}" }
            seen.add(key)
        }
    }

    private fun dedupeSeries(list: List<Series>): List<Series> {
        val seen = HashSet<String>()
        return list.filter { s ->
            seen.add(s.tmdbId?.let { "tmdb$it" } ?: "${TitleCleaner.clean(s.name).first.lowercase()}|${s.year ?: 0}")
        }
    }

    private fun genres(raw: List<String>): List<String> {
        val counts = HashMap<String, Int>()
        for (g in raw) for (part in g.split(',', '/', '|', '&')) {
            val name = part.trim().replaceFirstChar { it.uppercase() }
            if (name.length in 2..23) counts[name] = (counts[name] ?: 0) + 1
        }
        return counts.filter { it.value >= 3 }.entries.sortedByDescending { it.value }.map { it.key }
    }

    /** Groups "EN | Action", "FR | Action" into sections EN and FR. */
    private fun sections(cats: List<Category>): List<CategorySection> {
        val order = mutableListOf<String>()
        val groups = mutableMapOf<String, MutableList<Category>>()
        for (c in cats) {
            val g = TitleCleaner.splitCategory(c.name).first ?: "All"
            if (g !in groups) order.add(g)
            groups.getOrPut(g) { mutableListOf() }.add(c)
        }
        if (order.size <= 1 || order.size > 40) return listOf(CategorySection("All", cats))
        return order.map { CategorySection(it, groups[it] ?: emptyList()) }
    }

    // MARK: Lookups

    fun channel(id: Long): Channel? = channels.firstOrNull { it.id == id }
    fun movies(categoryId: String) = movieItems.filter { it.categoryId == categoryId }
    fun series(categoryId: String) = seriesItems.filter { it.categoryId == categoryId }

    fun matchMovie(tmdbId: Int?, imdbId: String?, title: String, year: Int?): Movie? {
        tmdbId?.let { id -> rawMovies.firstOrNull { it.tmdbId == id }?.let { return it } }
        imdbId?.let { id -> rawMovies.firstOrNull { it.imdbId == id }?.let { return it } }
        val wanted = title.lowercase()
        return rawMovies.firstOrNull { m ->
            val (t, y) = TitleCleaner.clean(m.name)
            t.lowercase() == wanted && (year == null || (y ?: m.year) == null || (y ?: m.year) == year)
        }
    }

    fun matchSeries(tmdbId: Int?, imdbId: String?, title: String): Series? {
        tmdbId?.let { id -> rawSeries.firstOrNull { it.tmdbId == id }?.let { return it } }
        imdbId?.let { id -> rawSeries.firstOrNull { it.imdbId == id }?.let { return it } }
        val wanted = title.lowercase()
        return rawSeries.firstOrNull { TitleCleaner.clean(it.name).first.lowercase() == wanted }
    }

    fun categoryName(id: String?): String {
        val all = movieCategories + seriesCategories + liveCategories
        return TitleCleaner.splitCategory(all.firstOrNull { it.id == id }?.name ?: "").second
    }

    // MARK: Disk cache

    private fun cacheName(id: String) = "dispatcharr-cache-$id.json"

    private fun loadDiskCache() {
        val id = active?.id ?: return
        val cache = Store.load(DiskCache.serializer(), cacheName(id)) ?: return
        applyLive(cache.liveCategories, cache.channels)
        scope.launch {
            applyVod(cache.movieCategories, cache.movies, cache.seriesCategories, cache.series)
            vodState = LoadState.Loaded
        }
        liveState = LoadState.Loaded
    }

    private fun saveDiskCache() {
        val id = active?.id ?: return
        val cache = DiskCache(liveCategories.filter { it.id != "__other" }, channels, movieCategories, rawMovies,
            seriesCategories, rawSeries, System.currentTimeMillis())
        scope.launch(Dispatchers.IO) { Store.save(DiskCache.serializer(), cache, cacheName(id)) }
    }
}
