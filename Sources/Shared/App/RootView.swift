import SwiftUI

struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PlayerCoordinator.self) private var coordinator
    @Environment(AddonManager.self) private var addons
    @Environment(DispatcharrStore.self) private var dispatcharr
    @State private var installing = false

    private var profiles: ProfileStore { .shared }
    private var reminders: ReminderCenter { .shared }

    var body: some View {
        @Bindable var router = router

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
        .playerPresentation()
        .overlay(alignment: .top) {
            if let alert = reminders.activeAlert {
                ReminderBanner(reminder: alert)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: reminders.activeAlert)
        .overlay {
            if profiles.needsSelection {
                ProfilePickerView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: profiles.needsSelection)
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
        .task {
            // Keeps the Activity badge current without waking the embedded engine.
            while !Task.isCancelled {
                await TorrentEngine.shared.refreshListIfRunning()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
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
        case .activity: ActivityView()
        case .library: LibraryView()
        case .settings: SettingsGate { SettingsView() }
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
        case .settings: SettingsGate { SettingsView() }
        case .torrents: ActivityView()
        case .recordings: RecordingsView()
        case .person(let id, let name): PersonView(personID: id, name: name)
        case .collection(let id, let name): CollectionView(collectionID: id, name: name)
        case .upNext: UpNextListView()
        }
    }
}

/// In-app reminder banner (tvOS, or iOS with notifications off).
struct ReminderBanner: View {
    var reminder: ProgrammeReminder
    private var center: ReminderCenter { .shared }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "bell.badge.fill").font(.title2).foregroundStyle(Theme.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title).font(.headline).lineLimit(1)
                Text("Starting on \(reminder.channelName)").font(.subheadline).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 12)
            Button { center.watch(reminder) } label: { Label("Watch", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            Button { center.activeAlert = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: 900)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 12)
        .task(id: reminder.id) {
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            if center.activeAlert?.id == reminder.id { center.activeAlert = nil }
        }
    }
}
