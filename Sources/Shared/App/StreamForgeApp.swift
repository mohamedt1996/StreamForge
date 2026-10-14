import SwiftUI
#if os(iOS)
import UserNotifications
#endif

#if os(iOS)
/// Receives background download events and sets up notification routing.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            DownloadManager.shared.backgroundCompletionHandler = completionHandler
            _ = DownloadManager.shared.records.count
        }
    }
}
#endif

@main
struct StreamForgeApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = AppSettings.shared
    @State private var dispatcharr = DispatcharrStore.shared
    @State private var addons = AddonManager.shared
    @State private var library = LibraryStore.shared
    @State private var torrents = TorrentEngine.shared
    @State private var trakt = TraktService.shared
    @State private var coordinator = PlayerCoordinator.shared
    @State private var router = AppRouter.shared
    @State private var profiles = ProfileStore.shared
    @State private var guide = GuideStore.shared
    @State private var reminders = ReminderCenter.shared
    @State private var downloads = DownloadManager.shared

    init() {
        ImagePipelineSetup.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(dispatcharr)
                .environment(addons)
                .environment(library)
                .environment(torrents)
                .environment(trakt)
                .environment(coordinator)
                .environment(router)
                .environment(profiles)
                .environment(guide)
                .environment(reminders)
                .environment(downloads)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onOpenURL { router.handle($0) }
                .task { await startup() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task {
                            await guide.refreshIfStale()
                            await trakt.refreshUpNext()
                        }
                    case .background:
                        library.flush()
                        SnapshotPublisher.publish()
                        CloudSync.shared.push()
                    default:
                        break
                    }
                }
        }
    }

    @MainActor
    private func startup() async {
        await guide.loadCacheIfNeeded()
        // Channels and the library come from the disk cache at launch, so deep links can run now.
        router.appDidLoad()
        CloudSync.shared.start()
        await dispatcharr.refreshAll()
        StreamForgeShortcuts.updateAppShortcutParameters()
        async let watchlist: Void = trakt.refreshWatchlist()
        async let upNext: Void = trakt.refreshUpNext()
        async let guideRefresh: Void = guide.refreshIfStale()
        _ = await (watchlist, upNext)
        if trakt.isSignedIn { await trakt.syncPlayback() }
        SnapshotPublisher.publish()
        // Warm up the embedded engine so the first torrent starts faster.
        if TorrentEngine.embeddedAvailable, settings.values.torrentMode == .embedded {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await torrents.startEmbeddedIfNeeded()
        }
        await guideRefresh
    }
}

enum AppTab: String, Hashable, CaseIterable {
    case home, live, movies, series, search, activity, library, settings

    var title: String {
        switch self {
        case .home: return "Home"
        case .live: return "Live TV"
        case .movies: return "Movies"
        case .series: return "Series"
        case .search: return "Search"
        case .activity: return "Activity"
        case .library: return "My Library"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .live: return "dot.radiowaves.left.and.right"
        case .movies: return "film.stack"
        case .series: return "tv"
        case .search: return "magnifyingglass"
        case .activity: return "arrow.down.circle"
        case .library: return "books.vertical"
        case .settings: return "gearshape"
        }
    }

    static var visible: [AppTab] {
        #if os(tvOS)
        return allCases
        #else
        return [.home, .live, .movies, .series, .search]
        #endif
    }
}

/// Navigation destinations shared by every tab.
enum Route: Hashable {
    case detail(MediaItem)
    case movies(categoryID: String?, title: String)
    case series(categoryID: String?, title: String)
    case channels(categoryID: String, title: String)
    case guide
    case addonCatalog(addonID: String, type: String, catalogID: String, title: String)
    case tmdbList(path: String, type: MediaType, title: String)
    case library
    case settings
    /// Torrent + download activity.
    case torrents
    case recordings
    case person(id: Int, name: String)
    case collection(id: Int, name: String)
    case upNext
}

@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()
    var tab: AppTab = .home
    var paths: [AppTab: NavigationPath] = [:]
    var alert: String?
    var pendingAddonInstall: String?
    /// Set by Siri / deep links; SearchView picks it up.
    var pendingSearch: String?
    @ObservationIgnored private var pendingURLs: [URL] = []
    @ObservationIgnored private var loaded = false

    private init() {}

    /// Deep links that arrive before the library is loaded are replayed afterwards.
    func appDidLoad() {
        loaded = true
        let urls = pendingURLs
        pendingURLs = []
        for url in urls { handle(url) }
    }

    /// Opens the Activity screen (a tab on tvOS, pushed elsewhere).
    func showActivity() {
        #if os(tvOS)
        tab = .activity
        #else
        if tab == .search || tab == .live { tab = .home }
        push(.torrents)
        #endif
    }

    func openSearch(_ query: String) {
        tab = .search
        pendingSearch = query
    }

    /// Tunes a live channel by Dispatcharr/XC stream id.
    func tuneChannel(id: Int) {
        let store = DispatcharrStore.shared
        if let channel = store.channel(id) {
            PlayerCoordinator.shared.playChannel(channel, in: [])
        } else {
            alert = store.isConfigured ? "That channel isn't available on this server or profile." : "Add your Dispatcharr server first."
        }
    }

    /// Resumes a continue-watching entry: offline copy, server copy, else the detail page.
    func resume(_ entry: WatchProgress) {
        let store = DispatcharrStore.shared
        let start = max(0, entry.position - 5)
        if let rec = DownloadManager.shared.record(for: entry.item, episode: entry.episode), rec.state == .completed,
           let url = DownloadManager.shared.localURL(rec) {
            PlayerCoordinator.shared.play(PlaybackRequest(item: entry.item, episode: entry.episode,
                                                          source: PlaybackSource(id: "offline:\(rec.id)", kind: .direct(url, headers: [:]),
                                                                                 title: entry.item.title, provider: "Downloaded"),
                                                          startPosition: start))
        } else if case .dispatcharrMovie(_, let id, let ext) = entry.item.origin, let url = store.client?.movieURL(id, ext: ext) {
            PlayerCoordinator.shared.play(PlaybackRequest(item: entry.item, episode: nil,
                                                          source: PlaybackSource(id: "resume", kind: .direct(url, headers: [:]), title: entry.item.title, provider: "Server"),
                                                          startPosition: start))
        } else if let ep = entry.episode, let eid = ep.dispatcharrEpisodeID, let url = store.client?.episodeURL(eid, ext: ep.ext ?? "mp4") {
            PlayerCoordinator.shared.play(PlaybackRequest(item: entry.item, episode: ep,
                                                          source: PlaybackSource(id: "resume", kind: .direct(url, headers: [:]), title: entry.item.title, provider: "Server"),
                                                          startPosition: start))
        } else {
            if tab == .search || tab == .live { tab = .home }
            push(.detail(entry.item))
        }
    }

    func resumeLatest() {
        if let entry = LibraryStore.shared.continueWatching.first {
            resume(entry)
        } else {
            alert = "Nothing to resume yet."
        }
    }

    private func entry(forKey key: String) -> WatchProgress? {
        let library = LibraryStore.shared
        if let p = library.progress[key] { return p }
        // The key's item may have finished since the snapshot was written.
        let itemID = key.components(separatedBy: "#").first ?? key
        return library.continueWatching.first { $0.item.id == itemID }
    }

    private func item(forKey key: String) -> MediaItem? {
        if let e = entry(forKey: key) { return e.item }
        let itemID = key.components(separatedBy: "#").first ?? key
        return LibraryStore.shared.favorites.first { $0.id == itemID }
            ?? VODIndex.shared.movies.first { $0.id == itemID }
            ?? VODIndex.shared.series.first { $0.id == itemID }
    }

    func path(_ tab: AppTab) -> Binding<NavigationPath> {
        Binding(get: { self.paths[tab] ?? NavigationPath() }, set: { self.paths[tab] = $0 })
    }

    func push(_ route: Route) {
        paths[tab, default: NavigationPath()].append(route)
    }

    func handle(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "stremio":
            pendingAddonInstall = url.absoluteString
        case "magnet":
            PlayerCoordinator.shared.playMagnet(url.absoluteString)
        case "file":
            guard url.isFileURL else { return }
            #if os(iOS)
            guard url.pathExtension.lowercased() == "torrent" else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            let name = url.deletingPathExtension().lastPathComponent
            Task {
                do {
                    let status = try await TorrentEngine.shared.addTorrentFile(data, title: name)
                    if let file = status.videoFiles.max(by: { $0.length < $1.length }) {
                        let source = TorrentSource(infoHash: status.hash, fileIdx: file.id - 1, filename: file.name, title: name)
                        PlayerCoordinator.shared.play(PlaybackRequest(
                            item: MediaItem(id: "torrent:\(status.hash)", type: .other, title: name, origin: .tmdb(id: 0)),
                            source: PlaybackSource(id: "torrentfile:\(status.hash)", kind: .torrent(source), title: name, provider: "Torrent")))
                    } else {
                        self.showActivity()
                    }
                } catch {
                    self.alert = error.localizedDescription
                }
            }
            #endif
        case "streamforge":
            // streamforge://addon?url=…, magnet?link=…, channel?id=…, resume?key=…, detail?key=…,
            // search?q=…, activity
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let q = comps?.queryItems ?? []
            func value(_ name: String) -> String? { q.first { $0.name == name }?.value }
            if !loaded, ["channel", "resume", "detail"].contains(url.host ?? "") {
                pendingURLs.append(url)
                return
            }
            switch url.host {
            case "addon":
                if let u = value("url") { pendingAddonInstall = u }
            case "magnet":
                if let m = value("link") { PlayerCoordinator.shared.playMagnet(m) }
            case "channel":
                if let id = value("id").flatMap(Int.init) { tuneChannel(id: id) }
            case "resume":
                if let key = value("key"), let e = entry(forKey: key) { resume(e) } else { resumeLatest() }
            case "detail":
                if let key = value("key"), let item = item(forKey: key) {
                    if tab == .search || tab == .live { tab = .home }
                    push(.detail(item))
                }
            case "search":
                openSearch(value("q") ?? "")
            case "activity", "downloads":
                showActivity()
            default:
                break
            }
        default:
            break
        }
    }
}
