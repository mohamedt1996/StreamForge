import SwiftUI

struct SourceSheetContext: Identifiable {
    let id = UUID()
    var item: MediaItem
    var episode: EpisodeRef?
    var upcoming: [EpisodeRef]
}

struct SourcesSheet: View {
    var context: SourceSheetContext
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var model: SourcesModel?
    @State private var providerFilter: String?
    @State private var qualityFilter: Int?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    let list = filtered(model.sorted)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if list.isEmpty && !model.isLoading {
                                EmptyStateView(icon: "antenna.radiowaves.left.and.right.slash", title: "No sources",
                                               message: "None of your addons returned a stream for this title. Install more stream addons in Settings → Addons.")
                            }
                            ForEach(list) { s in
                                SourceRow(source: s) { start(s) }
                            }
                            if model.isLoading {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Waiting for \(model.loadingAddons.count) addon\(model.loadingAddons.count == 1 ? "" : "s")…")
                                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                                }
                                .padding()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.gutter)
                    }
                    // Quality / provider chips stay pinned while the list scrolls.
                    .safeAreaInset(edge: .top, spacing: 0) {
                        filters(model)
                            .padding(.horizontal, Theme.gutter)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.background.opacity(0.96))
                    }
                } else {
                    LoadingView(text: "Finding sources…")
                }
            }
            .screenBackground()
            .navigationTitle(context.episode.map { "\(context.item.title) · \($0.code)" } ?? context.item.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort", selection: Binding(get: { settings.values.streamSort }, set: { settings.values.streamSort = $0 })) {
                            ForEach(StreamSort.allCases) { Text($0.label).tag($0) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                }
            }
        }
        .task {
            let m = SourcesModel(item: context.item, episode: context.episode)
            model = m
            await m.load()
        }
    }

    private func filtered(_ list: [PlaybackSource]) -> [PlaybackSource] {
        list.filter { s in
            (providerFilter == nil || s.provider == providerFilter) && (qualityFilter == nil || s.resolution == qualityFilter)
        }
    }

    @ViewBuilder
    private func filters(_ model: SourcesModel) -> some View {
        let providers = Array(Set(model.sources.map(\.provider))).sorted()
        let qualities = Array(Set(model.sources.map(\.resolution).filter { $0 > 0 })).sorted(by: >)
        if providers.count > 1 || qualities.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip("All", active: providerFilter == nil && qualityFilter == nil) { providerFilter = nil; qualityFilter = nil }
                    ForEach(qualities, id: \.self) { q in
                        filterChip(PlaybackSource(id: "", kind: .external(URL(string: "x:")!), title: "", provider: "", resolution: q).resolutionLabel,
                                   active: qualityFilter == q) { qualityFilter = qualityFilter == q ? nil : q }
                    }
                    ForEach(providers, id: \.self) { p in
                        filterChip(p, active: providerFilter == p) { providerFilter = providerFilter == p ? nil : p }
                    }
                }
            }
        }
    }

    private func filterChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(active ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surface), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func start(_ source: PlaybackSource) {
        dismiss()
        player.play(PlaybackRequest(item: context.item, episode: context.episode, source: source, upcoming: context.upcoming))
    }
}

struct SourceRow: View {
    var source: PlaybackSource
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    Text(source.resolutionLabel.isEmpty ? "—" : source.resolutionLabel)
                        .font(.subheadline.weight(.heavy))
                        .frame(width: 58, height: 34)
                        .background(qualityColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(qualityColor)
                    Image(systemName: icon).font(.caption).foregroundStyle(Theme.secondaryText)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(source.provider).font(.caption.weight(.bold)).foregroundStyle(Theme.accent).lineLimit(1)
                    Text(source.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let d = source.detail { Text(d).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2) }
                    HStack(spacing: 5) {
                        if source.isCached { Pill(text: "INSTANT", color: Color.green.opacity(0.3), icon: "bolt.fill") }
                        ForEach(source.tags.prefix(5), id: \.self) { Pill(text: $0) }
                        if let size = source.sizeBytes { Pill(text: size.byteText, color: .clear) }
                        if let seeders = source.seeders { Pill(text: "\(seeders)", color: .clear, icon: "person.2.fill") }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Theme.accent)
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var icon: String {
        switch source.kind {
        case .torrent: return "arrow.down.circle"
        case .direct: return source.isCached ? "server.rack" : "link"
        case .external: return "arrow.up.right.square"
        case .dispatcharrRecording: return "record.circle"
        }
    }

    private var qualityColor: Color {
        switch source.resolution {
        case 2160...: return Theme.gold
        case 1080..<2160: return Theme.accent
        case 720..<1080: return .teal
        default: return .gray
        }
    }
}
