import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(TraktService.self) private var trakt
    @Environment(DispatcharrStore.self) private var store

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.rowSpacing) {
                HStack(spacing: 12) {
                    libraryTile("Torrents", icon: "arrow.down.circle", subtitle: "Active streams") { router.push(.torrents) }
                    if store.restClient() != nil {
                        libraryTile("Recordings", icon: "record.circle", subtitle: "DVR on your server") { router.push(.recordings) }
                    }
                }
                .padding(.horizontal, Theme.gutter)

                Shelf(title: "Continue Watching", items: library.continueWatching) { entry in
                    Button { router.push(.detail(entry.item)) } label: {
                        LandscapeCard(title: entry.item.title, subtitle: entry.episode?.code ?? entry.remainingText,
                                      image: entry.episode?.still ?? entry.item.backdrop, fallbackImage: entry.item.poster, progress: entry.fraction)
                    }
                    .cardButtonStyle()
                }
                Shelf(title: "My List · Movies", items: library.favorites.filter { $0.type == .movie }) { poster($0) }
                Shelf(title: "My List · Series", items: library.favorites.filter { $0.type == .series }) { poster($0) }
                Shelf(title: "Trakt Watchlist", items: trakt.watchlist) { poster($0) }
                if library.favorites.isEmpty && library.continueWatching.isEmpty {
                    EmptyStateView(icon: "books.vertical", title: "Your library is empty",
                                   message: "Add movies and series to My List, and what you watch shows up here automatically.")
                        .frame(height: 320)
                }
            }
            .padding(.vertical, 12)
        }
        .screenBackground()
        .navigationTitle("My Library")
    }

    private func poster(_ item: MediaItem) -> some View {
        Button { router.push(.detail(item)) } label: { PosterCard(item: item) }
            .cardButtonStyle()
            .contextMenu { MediaContextMenu(item: item) }
    }

    private func libraryTile(_ title: String, icon: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(Theme.accentGradient).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct TorrentsView: View {
    @Environment(TorrentEngine.self) private var engine
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppRouter.self) private var router
    @State private var magnet = ""
    @State private var importing = false
    @State private var error: String?
    @State private var reachable: Bool?

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Paste a magnet link", text: $magnet)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    Button("Play") {
                        player.playMagnet(magnet.trimmed)
                        magnet = ""
                    }
                    .disabled(TorrentSource.parse(magnet: magnet.trimmed) == nil)
                }
                #if os(iOS)
                Button { importing = true } label: { Label("Open .torrent file", systemImage: "doc.badge.plus") }
                #endif
            } header: {
                Text("Stream a torrent")
            } footer: {
                Text("Engine: \(engine.mode.label)\(reachable == false ? " — not reachable" : "")")
            }

            Section("Active") {
                if engine.torrents.isEmpty {
                    Text("No active torrents").foregroundStyle(Theme.secondaryText)
                }
                ForEach(engine.torrents) { t in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        HStack(spacing: 10) {
                            Label("\(t.activePeers)/\(t.totalPeers)", systemImage: "person.2")
                            Label(t.speedText, systemImage: "arrow.down")
                            if t.size > 0 { Text(t.size.byteText) }
                        }
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                        ForEach(t.videoFiles) { f in
                            Button {
                                let source = TorrentSource(infoHash: t.hash, fileIdx: f.id - 1, filename: f.name, title: t.title, poster: t.poster)
                                player.play(PlaybackRequest(
                                    item: MediaItem(id: "torrent:\(t.hash):\(f.id)", type: .other, title: f.name, poster: t.poster, origin: .tmdb(id: 0)),
                                    source: PlaybackSource(id: "tfile:\(t.hash):\(f.id)", kind: .torrent(source), title: f.name, provider: "Torrent")))
                            } label: {
                                Label("\(f.name) · \(f.length.byteText)", systemImage: "play.circle").font(.caption).lineLimit(1)
                            }
                        }
                    }
                    #if os(iOS)
                    .swipeActions {
                        Button(role: .destructive) { Task { await engine.remove(t.hash) } } label: { Label("Remove", systemImage: "trash") }
                    }
                    #endif
                    .contextMenu {
                        Button(role: .destructive) { Task { await engine.remove(t.hash) } } label: { Label("Remove", systemImage: "trash") }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Torrents")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        #if os(iOS)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data]) { result in
            if case .success(let url) = result { router.handle(url) }
        }
        #endif
        .alert("Torrent", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func refresh() async {
        if engine.mode == .embedded { await engine.startEmbeddedIfNeeded() }
        reachable = await engine.ping()
        await engine.refreshList()
    }
}

struct RecordingsView: View {
    @Environment(DispatcharrStore.self) private var store
    @Environment(PlayerCoordinator.self) private var player
    @State private var recordings: [DispatcharrRecording] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(Theme.live) }
            let upcoming = recordings.filter { $0.isUpcoming || $0.isRecording }
            let done = recordings.filter { !$0.isUpcoming && !$0.isRecording }
            if !upcoming.isEmpty {
                Section("Scheduled") { ForEach(upcoming) { row($0) } }
            }
            Section("Recorded") {
                if done.isEmpty && !loading { Text("No recordings yet").foregroundStyle(Theme.secondaryText) }
                ForEach(done) { row($0) }
            }
        }
        .overlay { if loading { ProgressView() } }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("Recordings")
        .refreshable { await load() }
        .task { await load() }
    }

    private func row(_ r: DispatcharrRecording) -> some View {
        Button { if !r.isUpcoming { player.playRecording(r) } } label: {
            HStack(spacing: 12) {
                if let id = r.channelID, let ch = store.channel(id) {
                    ChannelLogo(url: ch.icon, name: ch.name, size: 40)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(r.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        if r.isRecording { LiveBadge() }
                    }
                    Text("\(r.start.formatted(date: .abbreviated, time: .shortened)) · \(Int(r.end.timeIntervalSince(r.start) / 60)) min")
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .swipeActions {
            Button(role: .destructive) { delete(r) } label: { Label("Delete", systemImage: "trash") }
        }
        #endif
        .contextMenu {
            Button(role: .destructive) { delete(r) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func load() async {
        guard let rest = store.restClient() else {
            error = "Add your Dispatcharr web password in Settings to see recordings."
            loading = false
            return
        }
        do {
            recordings = try await rest.recordings()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func delete(_ r: DispatcharrRecording) {
        guard let rest = store.restClient() else { return }
        Task {
            try? await rest.deleteRecording(r.id)
            recordings.removeAll { $0.id == r.id }
        }
    }
}
