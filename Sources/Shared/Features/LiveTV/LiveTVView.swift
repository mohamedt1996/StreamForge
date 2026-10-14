import SwiftUI

private enum LiveFilter: Hashable {
    case favorites, recents, sports, all, category(String)
}

struct LiveTVView: View {
    @Environment(DispatcharrStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @State private var filter: LiveFilter = .all
    @State private var query = ""
    @State private var programmeChannel: XCChannel?

    var body: some View {
        Group {
            if !store.isConfigured {
                EmptyStateView(icon: "dot.radiowaves.left.and.right", title: "No Dispatcharr server",
                               message: "Add your Dispatcharr server to watch live channels with the full TV guide.",
                               actionTitle: "Add Server") { router.push(.settings) }
            } else if case .failed(let msg) = store.liveState, store.channels.isEmpty {
                EmptyStateView(icon: "wifi.exclamationmark", title: "Couldn't load channels", message: msg, actionTitle: "Retry") {
                    Task { await store.refreshAll(force: true) }
                }
            } else if store.channels.isEmpty {
                LoadingView(text: "Loading channels…")
            } else {
                content
            }
        }
        .screenBackground()
        .navigationTitle("Live TV")
        .refreshable {
            await store.refreshAll(force: true)
            await GuideStore.shared.refresh(force: true)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { router.push(.guide) } label: { Label("Guide", systemImage: "calendar.day.timeline.left") }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { openMultiview() } label: { Label("Multiview", systemImage: "rectangle.split.2x2") }
                    .disabled(store.channels.isEmpty)
            }
        }
        .sheet(item: $programmeChannel) { ChannelProgrammeSheet(channel: $0) }
        .onAppear {
            if filter == .all, !library.favoriteChannelIDs.isEmpty { filter = .favorites }
        }
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        HStack(alignment: .top, spacing: 40) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) { filterButtons(vertical: true) }
                    .padding(.vertical, 20)
            }
            .frame(width: 420)
            channelList
        }
        .padding(.horizontal, 60)
        #else
        if UIDevice.current.userInterfaceIdiom == .pad {
            HStack(spacing: 0) {
                List {
                    filterButtons(vertical: true)
                }
                .listStyle(.sidebar)
                .hiddenListBackground()
                .frame(width: 290)
                Divider()
                channelList
            }
            .searchable(text: $query, prompt: "Filter channels")
        } else {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { filterButtons(vertical: false) }
                        .padding(.horizontal, Theme.gutter)
                        .padding(.vertical, 8)
                }
                channelList
            }
            .searchable(text: $query, prompt: "Filter channels")
        }
        #endif
    }

    @ViewBuilder
    private func filterButtons(vertical: Bool) -> some View {
        filterButton(.favorites, title: "Favorites", icon: "star.fill", count: library.favoriteChannelIDs.count, vertical: vertical)
        filterButton(.recents, title: "Recent", icon: "clock", count: library.recentChannelIDs.count, vertical: vertical)
        filterButton(.sports, title: "Sports", icon: "sportscourt", count: sportsChannels.count, vertical: vertical)
        filterButton(.all, title: "All Channels", icon: "square.grid.2x2", count: store.channels.count, vertical: vertical)
        ForEach(store.liveCategories.filter { !library.isHidden(category: "live:\($0.id)") }) { cat in
            filterButton(.category(cat.id), title: cat.name, icon: nil, count: store.channelsByCategory[cat.id]?.count ?? 0, vertical: vertical)
        }
    }

    private func filterButton(_ f: LiveFilter, title: String, icon: String?, count: Int, vertical: Bool) -> some View {
        let selected = filter == f
        return Button { filter = f } label: {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).frame(width: 20) }
                Text(title).lineLimit(1)
                if vertical {
                    Spacer()
                    Text("\(count)").font(.caption).foregroundStyle(Theme.secondaryText)
                }
            }
            .font(.subheadline.weight(selected ? .bold : .medium))
            .padding(.horizontal, vertical ? 12 : 14)
            .padding(.vertical, vertical ? 10 : 7)
            .frame(maxWidth: vertical ? .infinity : nil, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: vertical ? 10 : 20, style: .continuous)
                    .fill(selected
                          ? (vertical ? AnyShapeStyle(Theme.surfaceHigh) : AnyShapeStyle(Theme.accentGradient))
                          : (vertical ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Theme.surface)))
            }
            .clipShape(RoundedRectangle(cornerRadius: vertical ? 10 : 20, style: .continuous))
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        #endif
        .contextMenu {
            if case .category(let id) = f {
                Button { library.toggleHidden(category: "live:\(id)") } label: { Label("Hide Category", systemImage: "eye.slash") }
            }
        }
    }

    private var filtered: [XCChannel] {
        var list: [XCChannel]
        switch filter {
        case .favorites: list = library.favoriteChannelIDs.compactMap { store.channel($0) }
        case .recents: list = library.recentChannelIDs.compactMap { store.channel($0) }
        case .sports: list = sportsChannels
        case .all: list = store.channels.filter { !library.isHidden(category: "live:\($0.categoryID)") }
        case .category(let id): list = store.channelsByCategory[id] ?? []
        }
        let q = query.trimmed.lowercased()
        if !q.isEmpty { list = list.filter { $0.name.lowercased().contains(q) || String($0.number ?? -1) == q } }
        return list
    }

    /// Channels airing sport right now (bulk guide), then channels in sports groups.
    private var sportsChannels: [XCChannel] {
        let live = GuideStore.shared.liveSportsNow(channels: store.channels, limit: 200).map(\.channel)
        let liveIDs = Set(live.map(\.id))
        let sportsCats = Set(store.liveCategories.filter { SportsDetector.isSportsCategory($0.name) }.map(\.id))
        let byCategory = store.channels.filter { sportsCats.contains($0.categoryID) && !liveIDs.contains($0.id) }
        return live + byCategory
    }

    /// Up to 4 favorites, else the first channels of the current filter.
    private func openMultiview() {
        let favorites = library.favoriteChannelIDs.compactMap { store.channel($0) }
        let pick = favorites.count >= 2 ? favorites : filtered
        PlayerCoordinator.shared.openMultiview(Array(pick.prefix(4)))
    }

    private var channelList: some View {
        let list = filtered
        return Group {
            if list.isEmpty {
                EmptyStateView(icon: filter == .favorites ? "star" : (filter == .sports ? "sportscourt" : "tv"),
                               title: filter == .favorites ? "No favorites yet" : (filter == .sports ? "No sports on right now" : "Nothing here"),
                               message: filter == .favorites ? "Long-press a channel and choose Add to Favorites."
                                   : (filter == .sports ? "Sports are detected from the TV guide. Download it in Settings → Dispatcharr." : "No channels match."))
            } else {
                ScrollView {
                    LazyVStack(spacing: rowSpacing) {
                        ForEach(list) { channel in
                            ChannelRow(channel: channel, list: list) { programmeChannel = channel }
                        }
                    }
                    .padding(.horizontal, rowPadding)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var rowSpacing: CGFloat {
        #if os(tvOS)
        return 16
        #else
        return 6
        #endif
    }
    private var rowPadding: CGFloat {
        #if os(tvOS)
        return 20
        #else
        return 12
        #endif
    }
}

struct ChannelRow: View {
    var channel: XCChannel
    var list: [XCChannel]
    var onShowGuide: () -> Void
    @Environment(DispatcharrStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let now = store.nowPlaying(channel.id)
        let next = store.nextUp(channel.id)
        Button { player.playChannel(channel, in: list) } label: {
            HStack(spacing: 14) {
                if settings.values.showChannelNumbers, let n = channel.number {
                    Text("\(n)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.secondaryText).frame(width: 34)
                }
                ChannelLogo(url: channel.icon, name: channel.name, size: logoSize)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(channel.name).font(.headline).lineLimit(1)
                        if library.isFavoriteChannel(channel.id) {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.gold)
                        }
                        if channel.hasArchive {
                            Image(systemName: "clock.arrow.circlepath").font(.caption2).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if let now {
                        HStack(spacing: 6) {
                            if now.isSports { SportBadge() }
                            Text(now.title).font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        }
                        HStack(spacing: 8) {
                            ProgressLine(fraction: now.progress).frame(width: 90)
                            Text(now.timeRangeText).font(.caption2).foregroundStyle(Theme.secondaryText)
                        }
                    } else {
                        Text("No programme information").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    if let next {
                        Text("Next: \(next.title)").font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                #if os(iOS)
                Button(action: onShowGuide) {
                    Image(systemName: "list.bullet.rectangle").font(.title3).foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                #endif
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { library.toggleFavoriteChannel(channel.id) } label: {
                Label(library.isFavoriteChannel(channel.id) ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: library.isFavoriteChannel(channel.id) ? "star.slash" : "star")
            }
            Button(action: onShowGuide) { Label("Programme Guide", systemImage: "list.bullet.rectangle") }
        }
        .task(id: channel.id) { await store.loadEPG(channel.id) }
    }

    private var logoSize: CGFloat {
        #if os(tvOS)
        return 80
        #else
        return 48
        #endif
    }
}

/// Channels of one category (used from search / routes).
struct ChannelListScreen: View {
    var categoryID: String
    var title: String
    @Environment(DispatcharrStore.self) private var store
    @State private var programmeChannel: XCChannel?

    var body: some View {
        let list = store.channelsByCategory[categoryID] ?? []
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(list) { ch in ChannelRow(channel: ch, list: list) { programmeChannel = ch } }
            }
            .padding(12)
        }
        .screenBackground()
        .navigationTitle(title)
        .sheet(item: $programmeChannel) { ChannelProgrammeSheet(channel: $0) }
    }
}

/// Full schedule for one channel with catch-up and recording.
struct ChannelProgrammeSheet: View {
    var channel: XCChannel
    @Environment(DispatcharrStore.self) private var store
    @Environment(PlayerCoordinator.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var programmes: [XCEPGListing] = []
    @State private var loading = true
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(programmes) { p in
                        programmeRow(p).id(p.id)
                    }
                }
                .overlay { if loading { ProgressView() } else if programmes.isEmpty { Text("No guide data").foregroundStyle(Theme.secondaryText) } }
                .onChange(of: programmes.count) {
                    if let live = programmes.first(where: \.isLive) { proxy.scrollTo(live.id, anchor: .top) }
                }
            }
            .navigationTitle(channel.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { library.toggleFavoriteChannel(channel.id) } label: {
                        Image(systemName: library.isFavoriteChannel(channel.id) ? "star.fill" : "star")
                    }
                }
            }
            .alert("Recording", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(message ?? "") }
        }
        .task {
            programmes = await store.loadEPG(channel.id, full: true)
            loading = false
        }
    }

    @ViewBuilder
    private func programmeRow(_ p: XCEPGListing) -> some View {
        let past = p.end < Date()
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.start, style: .time).font(.subheadline.monospacedDigit().weight(.semibold))
                Text(p.start, format: .dateTime.weekday(.abbreviated)).font(.caption2).foregroundStyle(Theme.secondaryText)
            }
            .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(p.title).font(.headline).foregroundStyle(past && !p.hasArchive ? Theme.secondaryText : .white)
                    if p.isLive { LiveBadge() }
                    if p.isSports { SportBadge() }
                    if p.isNew { Pill(text: "NEW", color: Theme.accent.opacity(0.5)) }
                }
                if let sub = p.subtitle ?? p.episodeNumber {
                    Text([p.episodeNumber, p.subtitle].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? sub)
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                }
                if !p.description.isEmpty {
                    Text(p.description).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(3)
                }
                if p.isLive { ProgressLine(fraction: p.progress).frame(maxWidth: 200) }
                HStack(spacing: 10) {
                    if p.isLive {
                        Button { dismiss(); player.playChannel(channel, in: []) } label: { Label("Watch", systemImage: "play.fill") }
                    }
                    if past && (p.hasArchive || channel.hasArchive) {
                        Button { dismiss(); player.playCatchup(channel, programme: p) } label: { Label("Catch-up", systemImage: "gobackward") }
                    }
                    if p.start > Date() {
                        let on = ReminderCenter.shared.has(channelID: channel.id, programme: p)
                        Button { ReminderCenter.shared.toggle(channel: channel, programme: p) } label: {
                            Label(on ? "Reminder Set" : "Remind Me", systemImage: on ? "bell.fill" : "bell")
                        }
                    }
                    if !past, store.restClient() != nil {
                        Button { record(p) } label: { Label("Record", systemImage: "record.circle") }
                            .tint(Theme.live)
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
    }

    private func record(_ p: XCEPGListing) {
        guard let rest = store.restClient() else { return }
        Task {
            do {
                try await rest.scheduleRecording(channelID: channel.id, programme: p)
                message = "“\(p.title)” is scheduled to record on your server."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
