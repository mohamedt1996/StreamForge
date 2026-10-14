import SwiftUI

@main
struct StreamForgeApp: App {
    @State private var settings = AppSettings.shared
    @State private var dispatcharr = DispatcharrStore.shared
    @State private var addons = AddonManager.shared
    @State private var library = LibraryStore.shared
    @State private var torrents = TorrentEngine.shared
    @State private var trakt = TraktService.shared
    @State private var coordinator = PlayerCoordinator.shared
    @State private var router = AppRouter.shared

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
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onOpenURL { router.handle($0) }
                .task { await startup() }
        }
    }

    @MainActor
    private func startup() async {
        await dispatcharr.refreshAll()
        await trakt.refreshWatchlist()
        // Warm up the embedded engine so the first torrent starts faster.
        if TorrentEngine.embeddedAvailable, settings.values.torrentMode == .embedded {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await torrents.startEmbeddedIfNeeded()
        }
    }
}

enum AppTab: String, Hashable, CaseIterable {
    case home, live, movies, series, search, library, settings

    var title: String {
        switch self {
        case .home: return "Home"
        case .live: return "Live TV"
        case .movies: return "Movies"
        case .series: return "Series"
        case .search: return "Search"
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
    case torrents
    case recordings
}

@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()
    var tab: AppTab = .home
    var paths: [AppTab: NavigationPath] = [:]
    var alert: String?
    var pendingAddonInstall: String?

    private init() {}

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
                        self.tab = .library
                        self.push(.torrents)
                    }
                } catch {
                    self.alert = error.localizedDescription
                }
            }
            #endif
        case "streamforge":
            // streamforge://addon?url=…  or streamforge://magnet?link=…
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let q = comps?.queryItems ?? []
            if url.host == "addon", let u = q.first(where: { $0.name == "url" })?.value { pendingAddonInstall = u }
            if url.host == "magnet", let m = q.first(where: { $0.name == "link" })?.value { PlayerCoordinator.shared.playMagnet(m) }
        default:
            break
        }
    }
}
