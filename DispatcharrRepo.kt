package com.mohamedt.streamforge.dispatcharr

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.mohamedt.streamforge.core.HttpException
import com.mohamedt.streamforge.core.MediaItem
import com.mohamedt.streamforge.core.Settings
import com.mohamedt.streamforge.core.Store
import com.mohamedt.streamforge.core.TitleCleaner
import com.mohamedt.streamforge.sync.RemoteSync
import java.security.SecureRandom
import java.text.Normalizer
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

/** O(1) lookups behind matchMovie / matchSeries (detail pages, sources, person and collection screens). */
private class MatchIndex<T>(
    val byTmdb: Map<Int, T> = emptyMap(),
    val byImdb: Map<String, T> = emptyMap(),
    /** normalizedTitle(cleaned title) → (year, item), in library order. */
    val byTitle: Map<String, List<Pair<Int?, T>>> = emptyMap(),
)

/** Lower-case letters and digits only, accents folded: "Amélie" / "amelie", "Spider-Man" / "Spiderman". */
internal fun normalizedTitle(raw: String): String {
    val decomposed = Normalizer.normalize(raw.lowercase(), Normalizer.Form.NFD)
    val sb = StringBuilder(decomposed.length)
    for (ch in decomposed) if (ch.isLetterOrDigit()) sb.append(ch)
    return sb.toString()
}

/** The live lineup, ready to publish (built on Dispatchers.Default). */
private class LiveBuild(
    val channels: List<Channel>,
    val byCategory: Map<String, List<Channel>>,
    val categories: List<Category>,
    val index: Map<Long, Channel>,
)

/** The VOD library and everything derived from it, ready to publish (built on Dispatchers.Default). */
private class VodBuild(
    val movies: List<Movie>,
    val series: List<Series>,
    val movieItems: List<MediaItem>,
    val seriesItems: List<MediaItem>,
    val moviesByCategory: Map<String, List<MediaItem>>,
    val seriesByCategory: Map<String, List<MediaItem>>,
    val recentMovies: List<MediaItem>,
    val recentSeries: List<MediaItem>,
    val topMovies: List<MediaItem>,
    val topSeries: List<MediaItem>,
    val movieCategories: List<Category>,
    val seriesCategories: List<Category>,
    val movieSections: List<CategorySection>,
    val seriesSections: List<CategorySection>,
    val movieGenres: List<String>,
    val seriesGenres: List<String>,
    val movieIndex: MatchIndex<Movie>,
    val seriesIndex: MatchIndex<Series>,
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
    /** Newest 30 movies / series (by added / last update), for Home and the VOD shelves. */
    var recentMovies by mutableStateOf<List<MediaItem>>(emptyList()); private set
    var recentSeries by mutableStateOf<List<MediaItem>>(emptyList()); private set
    /** Best rated (7+) 30 movies / series. */
    var topMovies by mutableStateOf<List<MediaItem>>(emptyList()); private set
    var topSeries by mutableStateOf<List<MediaItem>>(emptyList()); private set

    // Derived lookups, published together with the lists above (state, so composition readers recompose).
    private var moviesByCategory by mutableStateOf<Map<String, List<MediaItem>>>(emptyMap())
    private var seriesByCategory by mutableStateOf<Map<String, List<MediaItem>>>(emptyMap())
    private var channelIndex by mutableStateOf<Map<Long, Channel>>(emptyMap())
    private var movieCategoryNames by mutableStateOf<Map<String, String>>(emptyMap())
    private var seriesCategoryNames by mutableStateOf<Map<String, String>>(emptyMap())
    private var liveCategoryNames by mutableStateOf<Map<String, String>>(emptyMap())
    private var movieIndex by mutableStateOf(MatchIndex<Movie>())
    private var seriesIndex by mutableStateOf(MatchIndex<Series>())

    private var rawMovies: List<Movie> = emptyList()
    private var rawSeries: List<Series> = emptyList()
    // Generations: a build that finishes after a newer load (or a server switch) is dropped. Cached data
    // never replaces data that already came from the network.
    private var liveGen = 0
    private var liveFromNetwork = false
    private var vodGen = 0
    private var vodFromNetwork = false
    private var rest: DispatcharrRest? = null
    private var credentialsSyncedFor: String? = null

    val active: Server? get() = servers.firstOrNull { it.id == activeId } ?: servers.firstOrNull()
    val client: XtreamClient? get() = active?.let { XtreamClient(it, if (it.usesRestStreaming) restClient() else null) }
    val isConfigured: Boolean get() = active != null

    /** Resolve retained/synced items against their origin, not the current browsing server. */
    fun playbackClient(item: MediaItem): XtreamClient? {
        if (!item.origin.kind.startsWith("xc-")) return client
        val server = item.origin.serverId?.let { id -> servers.firstOrNull { it.id == id } }
            ?: if (item.origin.serverId == null) {
                // Older records stored only the first eight UUID characters in the item ID.
                val prefix = item.id.split(":").getOrNull(1)
                servers.filter { prefix != null && it.id.take(8) == prefix }.singleOrNull()
            } else null
        return server?.let { XtreamClient(it, if (it.usesRestStreaming && it.hasRest) DispatcharrRest(it) else null) }
    }

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
     * /api/accounts/users/me/. Without one, admins get a generated XC password (only admins may set
     * it); everyone else streams through the REST API and Dispatcharr's proxy (REST streaming mode).
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
            var xc = me.xcPassword.orEmpty()
            if (xc.isEmpty()) {
                val created = createXcPasswordIfAllowed(rest, me)
                if (created != null) {
                    xc = created
                    note = "Connected · created an XC password for streaming"
                }
            }
            server.xcPassword = xc
            if (xc.isEmpty()) {
                // No XC password and not allowed to set one: check the REST API lets this user browse.
                try {
                    rest.get("api/channels/groups/")
                } catch (e: HttpException) {
                    if (e.code == 401 || e.code == 403) {
                        throw IllegalStateException("Signed in, but Dispatcharr doesn't let this user browse channels through its API. " +
                            "Streamer-level users need an XC password: ask the admin to set one (Users → edit → XC Password).")
                    }
                    throw e
                }
                note = "Connected · streaming through Dispatcharr's API (no XC password needed; catch-up unavailable)"
            }
        } else {
            server.xcPassword = xcPassword
        }
        if (server.xcPassword.isNotEmpty()) XtreamClient(server).authenticate()
        withContext(Dispatchers.Main) { upsert(server) }
        return note
    }

    /** Admins may set their own XC password: generate one, save it, and read it back. Null otherwise. */
    private suspend fun createXcPasswordIfAllowed(rest: DispatcharrRest, me: DispatcharrRest.Me): String? {
        if (me.userLevel < 10 || me.id == null) return null
        val password = generatePassword()
        return runCatching {
            rest.setXcPassword(me.id, password)
            password.takeIf { rest.me().xcPassword == it }
        }.getOrNull()
    }

    /** From Dispatcharr's allowed XC password characters (^[A-Za-z0-9._@-]+$). */
    private fun generatePassword(): String {
        val chars = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        val r = SecureRandom()
        return (1..20).map { chars[r.nextInt(chars.length)] }.joinToString("")
    }

    /**
     * Account / API-key servers: re-reads the XC password from /me (once per activation), so one the
     * admin sets, changes or removes is picked up. Blank switches the server to REST streaming mode.
     */
    private suspend fun syncCredentials(server: Server) {
        if (server.authMode == AuthMode.XC || !server.hasRest || credentialsSyncedFor == server.id) return
        val me = runCatching { (restClient() ?: return).me() }.getOrNull() ?: return
        credentialsSyncedFor = server.id
        val xc = me.xcPassword.orEmpty()
        if (xc != server.xcPassword && (xc.isNotEmpty() || me.hasCustomProperties)) server.xcPassword = xc
    }

    private fun upsert(server: Server) {
        servers = servers.filter { it.id != server.id } + server
        Store.save(ListSerializer(Server.serializer()), servers, "servers.json")
        RemoteSync.changed()
        activate(server.id)
    }

    /**
     * Saves a server pulled from the sync server (secrets are set by the caller). Keeps its place in
     * the list, activates it when nothing is active, and reloads when the active server's connection changed.
     */
    internal fun upsertFromSync(server: Server) {
        val old = servers.firstOrNull { it.id == server.id }
        servers = if (old != null) servers.map { if (it.id == server.id) server else it } else servers + server
        Store.save(ListSerializer(Server.serializer()), servers, "servers.json")
        RemoteSync.changed()
        val isActive = active?.id == server.id
        if (activeId == null && servers.size == 1) activate(server.id)
        else if (isActive && (old == null || old.baseUrl != server.baseUrl || old.username != server.username || old.authMode != server.authMode)) activate(server.id)
        else if (isActive) rest = null
    }

    fun remove(server: Server) {
        servers = servers.filter { it.id != server.id }
        Store.save(ListSerializer(Server.serializer()), servers, "servers.json")
        RemoteSync.changed()
        Store.file(cacheName(server.id)).delete()
        DispatcharrUuids.remove(server.id)
        if (activeId == server.id) activate(servers.firstOrNull()?.id)
    }

    fun activate(id: String?) {
        activeId = id
        Store.prefs.edit().putString("active.server", id).apply()
        rest = null
        credentialsSyncedFor = null
        clear()
        loadDiskCache()
        refreshAll(force = true)
    }

    private fun clear() {
        liveCategories = emptyList(); channels = emptyList(); channelsByCategory = emptyMap()
        movieCategories = emptyList(); seriesCategories = emptyList(); movieItems = emptyList(); seriesItems = emptyList()
        movieSections = emptyList(); seriesSections = emptyList(); movieGenres = emptyList(); seriesGenres = emptyList()
        rawMovies = emptyList(); rawSeries = emptyList()
        recentMovies = emptyList(); recentSeries = emptyList(); topMovies = emptyList(); topSeries = emptyList()
        moviesByCategory = emptyMap(); seriesByCategory = emptyMap(); channelIndex = emptyMap()
        movieCategoryNames = emptyMap(); seriesCategoryNames = emptyMap(); liveCategoryNames = emptyMap()
        movieIndex = MatchIndex(); seriesIndex = MatchIndex()
        liveGen++; vodGen++
        liveFromNetwork = false; vodFromNetwork = false
        liveState = LoadState.Idle; vodState = LoadState.Idle
    }

    // MARK: Loading

    fun refreshAll(force: Boolean = false) {
        val server = active ?: return
        if (!force && System.currentTimeMillis() - lastRefresh < 15 * 60_000 && channels.isNotEmpty()) return
        scope.launch {
            syncCredentials(server)
            val c = client ?: return@launch
            if (channels.isEmpty()) liveState = LoadState.Loading
            if (movieItems.isEmpty() && seriesItems.isEmpty()) vodState = LoadState.Loading
            val live = async(Dispatchers.IO) { runCatching { c.liveCategories() to c.channels() } }
            val vod = async(Dispatchers.IO) {
                runCatching { listOf(c.vodCategories(), c.seriesCategories()) to (c.movies() to c.series()) }
            }
            val liveResult = live.await()
            if (active?.id != server.id) return@launch
            liveResult.onSuccess { (cats, ch) -> if (applyLive(cats, ch)) liveState = LoadState.Loaded }
                .onFailure { if (channels.isEmpty()) liveState = LoadState.Failed(loadError(it, c, "Couldn't load channels")) }
            val vodResult = vod.await()
            if (active?.id != server.id) return@launch
            vodResult.onSuccess { (cats, data) -> if (applyVod(cats[0], data.first, cats[1], data.second)) vodState = LoadState.Loaded }
                .onFailure { if (movieItems.isEmpty() && seriesItems.isEmpty()) vodState = LoadState.Failed(loadError(it, c, "Couldn't load the library")) }
            if (active?.id != server.id) return@launch
            lastRefresh = System.currentTimeMillis()
            saveDiskCache()
            GuideRepo.refreshIfStale()
        }
    }

    /** Streamer-level users can't use the REST API, only Xtream Codes. */
    private fun loadError(e: Throwable, c: XtreamClient, fallback: String): String =
        if (c.server.usesRestStreaming && e is HttpException && (e.code == 401 || e.code == 403)) {
            "Dispatcharr didn't let this account browse channels through its API. Streamer-level users can only use Xtream Codes: " +
                "ask the admin to set an XC password for your user (Users → edit → XC Password)."
        } else {
            e.message ?: fallback
        }

    /**
     * Filters, sorts and groups the lineup on Dispatchers.Default and publishes it on Main. False when
     * the result was dropped (a newer load or a server switch superseded it).
     */
    private suspend fun applyLive(cats: List<Category>, list: List<Channel>, fromCache: Boolean = false): Boolean {
        val gen = if (fromCache) liveGen else ++liveGen
        val hideAdult = Settings.values.hideAdult
        val built = withContext(Dispatchers.Default) { buildLive(cats, list, hideAdult) }
        if (gen != liveGen || (fromCache && liveFromNetwork)) return false
        channels = built.channels
        channelsByCategory = built.byCategory
        liveCategories = built.categories
        channelIndex = built.index
        liveCategoryNames = built.categories.associate { it.id to it.name }
        if (!fromCache) liveFromNetwork = true
        return true
    }

    private fun buildLive(cats: List<Category>, list: List<Channel>, hideAdult: Boolean): LiveBuild {
        // Channel ids are used as LazyColumn keys everywhere: a duplicate would crash the list.
        val visible = list.distinctBy { it.id }.filter { !(hideAdult && it.isAdult) }
            .sortedWith(compareBy<Channel> { it.number ?: Int.MAX_VALUE }.thenBy { it.name })
        val grouped = visible.groupBy { it.categoryId }.toMutableMap()
        val known = cats.filter { grouped[it.id]?.isNotEmpty() == true }.toMutableList()
        val knownIds = known.map { it.id }.toSet()
        val orphans = visible.filter { it.categoryId !in knownIds }
        if (orphans.isNotEmpty()) {
            grouped["__other"] = orphans
            known.add(Category("__other", "Other"))
        }
        val index = HashMap<Long, Channel>(visible.size * 2)
        for (ch in visible) index[ch.id] = ch
        return LiveBuild(visible, grouped, known, index)
    }

    /** Builds the library (dedupe, items, per-category slices, shelves, match indexes) off the main thread. */
    private suspend fun applyVod(mc: List<Category>, movies: List<Movie>, sc: List<Category>, series: List<Series>, fromCache: Boolean = false): Boolean {
        val sid = active?.id ?: return false
        val gen = if (fromCache) vodGen else ++vodGen
        val hideAdult = Settings.values.hideAdult
        val b = withContext(Dispatchers.Default) { buildVod(sid, mc, movies, sc, series, hideAdult) }
        if (gen != vodGen || (fromCache && vodFromNetwork) || active?.id != sid) return false
        rawMovies = b.movies
        rawSeries = b.series
        movieIndex = b.movieIndex
        seriesIndex = b.seriesIndex
        moviesByCategory = b.moviesByCategory
        seriesByCategory = b.seriesByCategory
        recentMovies = b.recentMovies
        recentSeries = b.recentSeries
        topMovies = b.topMovies
        topSeries = b.topSeries
        movieCategories = b.movieCategories
        seriesCategories = b.seriesCategories
        movieCategoryNames = b.movieCategories.associate { it.id to it.name }
        seriesCategoryNames = b.seriesCategories.associate { it.id to it.name }
        movieSections = b.movieSections
        seriesSections = b.seriesSections
        movieGenres = b.movieGenres
        seriesGenres = b.seriesGenres
        movieItems = b.movieItems
        seriesItems = b.seriesItems
        if (!fromCache) vodFromNetwork = true
        return true
    }

    /** Pure: runs on Dispatchers.Default. Every title is cleaned (regex) exactly once. */
    private fun buildVod(sid: String, mc: List<Category>, movies: List<Movie>, sc: List<Category>, series: List<Series>, hideAdult: Boolean): VodBuild {
        // Same stream id can be listed under several categories; item ids must stay unique (lazy keys).
        // Providers also list the same film in several categories: keep one per id or title+year.
        val mVisible = movies.distinctBy { it.id }.filter { !(hideAdult && it.isAdult) }
        val m = ArrayList<Movie>(mVisible.size)
        val mClean = ArrayList<Pair<String, Int?>>(mVisible.size)
        val seenM = HashSet<String>()
        for (mv in mVisible) {
            val c = TitleCleaner.clean(mv.name)
            val key = mv.tmdbId?.let { "tmdb$it" } ?: mv.imdbId?.takeIf { it.isNotEmpty() }
                ?: "${c.first.lowercase()}|${c.second ?: mv.year ?: 0}"
            if (seenM.add(key)) { m += mv; mClean += c }
        }
        val sVisible = series.distinctBy { it.id }
        val s = ArrayList<Series>(sVisible.size)
        val sClean = ArrayList<Pair<String, Int?>>(sVisible.size)
        val seenS = HashSet<String>()
        for (sv in sVisible) {
            val c = TitleCleaner.clean(sv.name)
            if (seenS.add(sv.tmdbId?.let { "tmdb$it" } ?: "${c.first.lowercase()}|${sv.year ?: 0}")) { s += sv; sClean += c }
        }
        val mItems = m.mapIndexed { i, mv -> mv.toItem(sid, mClean[i]) }
        val sItems = s.mapIndexed { i, sv -> sv.toItem(sid, sClean[i]) }

        val mCats = m.mapTo(HashSet()) { it.categoryId }
        val sCats = s.mapTo(HashSet()) { it.categoryId }
        val movieCats = mc.filter { it.id in mCats }
        val seriesCats = sc.filter { it.id in sCats }

        val byAdded = compareByDescending<MediaItem> { it.added ?: 0L }
        val byRating = compareByDescending<MediaItem> { it.rating ?: 0.0 }
        return VodBuild(
            movies = m,
            series = s,
            movieItems = mItems,
            seriesItems = sItems,
            // Pre-sorted newest first: shelves just take a prefix.
            moviesByCategory = mItems.groupBy { it.categoryId ?: "0" }.mapValues { (_, v) -> v.sortedWith(byAdded) },
            seriesByCategory = sItems.groupBy { it.categoryId ?: "0" }.mapValues { (_, v) -> v.sortedWith(byAdded) },
            recentMovies = mItems.sortedWith(byAdded).take(30),
            recentSeries = sItems.sortedWith(byAdded).take(30),
            topMovies = mItems.filter { (it.rating ?: 0.0) >= 7.0 }.sortedWith(byRating).take(30),
            topSeries = sItems.filter { (it.rating ?: 0.0) >= 7.0 }.sortedWith(byRating).take(30),
            movieCategories = movieCats,
            seriesCategories = seriesCats,
            movieSections = sections(movieCats),
            seriesSections = sections(seriesCats),
            movieGenres = genres(m.mapNotNull { it.genre }),
            seriesGenres = genres(s.mapNotNull { it.genre }),
            movieIndex = matchIndex(m, mClean, { it.tmdbId }, { it.imdbId }, { mv, c -> c.second ?: mv.year }),
            seriesIndex = matchIndex(s, sClean, { it.tmdbId }, { it.imdbId }, { sv, c -> c.second ?: sv.year }),
        )
    }

    private fun <T> matchIndex(
        list: List<T>,
        cleaned: List<Pair<String, Int?>>,
        tmdb: (T) -> Int?,
        imdb: (T) -> String?,
        year: (T, Pair<String, Int?>) -> Int?,
    ): MatchIndex<T> {
        val byTmdb = HashMap<Int, T>()
        val byImdb = HashMap<String, T>()
        val byTitle = HashMap<String, MutableList<Pair<Int?, T>>>()
        for (i in list.indices) {
            val item = list[i]
            // First one wins, like the linear search this replaces.
            tmdb(item)?.let { if (it !in byTmdb) byTmdb[it] = item }
            imdb(item)?.takeIf { it.isNotEmpty() }?.let { if (it !in byImdb) byImdb[it] = item }
            val key = normalizedTitle(cleaned[i].first)
            if (key.isNotEmpty()) byTitle.getOrPut(key) { ArrayList(1) }.add(year(item, cleaned[i]) to item)
        }
        return MatchIndex(byTmdb, byImdb, byTitle)
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

    // MARK: Lookups (all O(1): they run per row and per composition)

    fun channel(id: Long): Channel? = channelIndex[id]
    /** A category's items, newest first. */
    fun movies(categoryId: String): List<MediaItem> = moviesByCategory[categoryId] ?: emptyList()
    fun series(categoryId: String): List<MediaItem> = seriesByCategory[categoryId] ?: emptyList()

    fun matchMovie(tmdbId: Int?, imdbId: String?, title: String, year: Int?): Movie? {
        val idx = movieIndex
        tmdbId?.let { id -> idx.byTmdb[id]?.let { return it } }
        imdbId?.takeIf { it.isNotEmpty() }?.let { id -> idx.byImdb[id]?.let { return it } }
        val key = normalizedTitle(title)
        if (key.isEmpty()) return null
        return idx.byTitle[key]?.firstOrNull { (y, _) -> year == null || y == null || y == year }?.second
    }

    fun matchSeries(tmdbId: Int?, imdbId: String?, title: String): Series? {
        val idx = seriesIndex
        tmdbId?.let { id -> idx.byTmdb[id]?.let { return it } }
        imdbId?.takeIf { it.isNotEmpty() }?.let { id -> idx.byImdb[id]?.let { return it } }
        val key = normalizedTitle(title)
        if (key.isEmpty()) return null
        return idx.byTitle[key]?.firstOrNull()?.second
    }

    fun categoryName(id: String?): String {
        if (id == null) return ""
        val raw = movieCategoryNames[id] ?: seriesCategoryNames[id] ?: liveCategoryNames[id] ?: ""
        return TitleCleaner.splitCategory(raw).second
    }

    // MARK: Disk cache

    private fun cacheName(id: String) = "dispatcharr-cache-$id.json"

    private fun loadDiskCache() {
        val id = active?.id ?: return
        // The cache holds the whole VOD library (can be tens of MB): streamed + decoded off the main thread.
        scope.launch {
            val cache = withContext(Dispatchers.IO) { Store.loadLarge(DiskCache.serializer(), cacheName(id)) } ?: return@launch
            if (active?.id != id) return@launch
            // A network refresh that finished first wins (applyLive / applyVod also re-check after building).
            if (channels.isEmpty() && applyLive(cache.liveCategories, cache.channels, fromCache = true)) {
                liveState = LoadState.Loaded
            }
            if (movieItems.isEmpty() && seriesItems.isEmpty() &&
                applyVod(cache.movieCategories, cache.movies, cache.seriesCategories, cache.series, fromCache = true)
            ) {
                vodState = LoadState.Loaded
            }
        }
    }

    private fun saveDiskCache() {
        val id = active?.id ?: return
        if (channels.isEmpty() && rawMovies.isEmpty() && rawSeries.isEmpty()) return
        val cache = DiskCache(liveCategories.filter { it.id != "__other" }, channels, movieCategories, rawMovies,
            seriesCategories, rawSeries, System.currentTimeMillis())
        scope.launch(Dispatchers.IO) { Store.saveLarge(DiskCache.serializer(), cache, cacheName(id)) }
    }
}
