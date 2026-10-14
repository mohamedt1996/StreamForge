import SwiftUI

struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlayerCoordinator.self) private var coordinator
    @Environment(AddonManager.self) private var addons
    @Environment(DispatcharrStore.self) private var dispatcharr
    @State private var installing = false

    var body: some View {
        @Bindable var router = router
        @Bindable var coordinator = coordinator

        TabView(selection: $router.tab) {
            ForEach(AppTab.visible, id: \.self) { tab in
                NavigationStack(path: router.path(tab)) {
                    tabRoot(tab)
                        .navigationDestination(for: Route.self) { RouteView(route: $0) }
                }
                .tabItem { Label(tab.title, systemImage: tab.icon) }
                .tag(tab)
            }
        }
        .fullScreenCover(item: $coordinator.current) { request in
            PlayerView(request: request)
        }
        .alert("StreamForge", isPresented: Binding(get: { router.alert != nil }, set: { if !$0 { router.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(router.alert ?? "")
        }
        .confirmationDialog("Install addon?", isPresented: Binding(get: { router.pendingAddonInstall != nil },
                                                                  set: { if !$0 { router.pendingAddonInstall = nil } }),
                            titleVisibility: .visible) {
            Button("Install") {
                guard let url = router.pendingAddonInstall else { return }
                Task {
                    do {
                        let a = try await addons.install(from: url)
                        router.alert = "Installed “\(a.manifest.name)”."
                    } catch {
                        router.alert = error.localizedDescription
                    }
                }
            }
        } message: {
            Text(router.pendingAddonInstall ?? "")
        }
    }

    @ViewBuilder
    private func tabRoot(_ tab: AppTab) -> some View {
        switch tab {
        case .home: HomeView()
        case .live: LiveTVView()
        case .movies: VODBrowserView(kind: .movie, categoryID: nil, title: "Movies")
        case .series: VODBrowserView(kind: .series, categoryID: nil, title: "Series")
        case .search: SearchView()
        case .library: LibraryView()
        case .settings: SettingsView()
        }
    }
}

struct RouteView: View {
    var route: Route

    var body: some View {
        switch route {
        case .detail(let item): MediaDetailView(item: item)
        case .movies(let cat, let title): VODBrowserView(kind: .movie, categoryID: cat, title: title)
        case .series(let cat, let title): VODBrowserView(kind: .series, categoryID: cat, title: title)
        case .channels(let cat, let title): ChannelListScreen(categoryID: cat, title: title)
        case .guide: GuideView()
        case .addonCatalog(let addonID, let type, let catalogID, let title):
            AddonCatalogView(addonID: addonID, type: type, catalogID: catalogID, title: title)
        case .tmdbList(let path, let type, let title): TMDBListView(path: path, type: type, title: title)
        case .library: LibraryView()
        case .settings: SettingsView()
        case .torrents: TorrentsView()
        case .recordings: RecordingsView()
        }
    }
}
