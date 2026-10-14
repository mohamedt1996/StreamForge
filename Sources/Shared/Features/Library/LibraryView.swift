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
                    libraryTile("Activity", icon: "arrow.down.circle", subtitle: activitySubtitle) { router.push(.torrents) }
                    if store.restClient() != nil {
                        libraryTile("Recordings", icon: "record.circle", subtitle: "DVR on your server") { router.push(.recordings) }
                    }
                    libraryTile(ProfileStore.shared.activeProfile.name, icon: "person.crop.circle", subtitle: "Switch profile") {
                        ProfileStore.shared.needsSelection = true
                    }
                }
                .padding(.horizontal, Theme.gutter)

                remindersSection

                Shelf(title: "Up Next", subtitle: "From Trakt", items: trakt.upNext) { entry in
                    Button { router.push(.detail(entry.item)) } label: {
                        LandscapeCard(title: entry.item.title, subtitle: "\(entry.episode.code) · \(entry.episode.title)",
                                      image: entry.item.backdrop, fallbackImage: entry.item.poster,
                                      badge: entry.isNew ? "NEW" : nil)
                    }
                    .cardButtonStyle()
                }

                let downloaded = DownloadManager.shared.records.filter { $0.state == .completed }
                Shelf(title: "Downloaded", items: downloaded) { rec in
                    Button { DownloadManager.shared.play(rec) } label: {
                        LandscapeCard(title: rec.displayTitle, subtitle: rec.bytesWritten.byteText,
                                      image: rec.episode?.still ?? rec.item.backdrop, fallbackImage: DownloadManager.shared.posterURL(rec),
                                      badge: "OFFLINE")
                    }
                    .cardButtonStyle()
                }

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

    private var activitySubtitle: String {
        let torrents = TorrentEngine.shared.activeCount
        let downloads = DownloadManager.shared.activeCount
        if torrents + downloads == 0 { return "Torrents & downloads" }
        var parts: [String] = []
        if torrents > 0 { parts.append("\(torrents) torrent\(torrents == 1 ? "" : "s")") }
        if downloads > 0 { parts.append("\(downloads) downloading") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var remindersSection: some View {
        let reminders = ReminderCenter.shared.reminders
        if !reminders.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Reminders", subtitle: "Programmes you asked to be reminded about")
                VStack(spacing: 8) {
                    ForEach(reminders) { r in
                        HStack(spacing: 12) {
                            if let ch = store.channel(r.channelID) {
                                ChannelLogo(url: ch.icon, name: ch.name, size: 40)
                            } else {
                                Image(systemName: "bell.fill").frame(width: 40)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("\(r.channelName) · \(r.start.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            Button { ReminderCenter.shared.remove(r.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.bordered)
                        }
                        .padding(10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }
        }
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
        .hiddenListBackground()
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
