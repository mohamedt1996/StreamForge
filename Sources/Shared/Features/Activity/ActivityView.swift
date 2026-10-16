import SwiftUI
import UniformTypeIdentifiers

/// Live torrent status (TorrServer) and offline downloads.
struct ActivityView: View {
    @Environment(TorrentEngine.self) private var engine
    @Environment(PlayerCoordinator.self) private var player
    @Environment(AppRouter.self) private var router
    private var downloads: DownloadManager { .shared }
    @State private var magnet = ""
    @State private var importing = false
    @State private var message: String?
    @State private var reachable: Bool?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                magnetSection
                torrentsSection
                downloadsSection
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 16)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task {
            // Poll every second while visible.
            if engine.mode == .embedded { await engine.startEmbeddedIfNeeded() }
            reachable = await engine.ping()
            while !Task.isCancelled {
                await engine.refreshList()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        #if os(iOS)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data]) { result in
            if case .success(let url) = result { router.handle(url) }
        }
        #endif
        .alert("Activity", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private func refresh() async {
        if engine.mode == .embedded { await engine.startEmbeddedIfNeeded() }
        reachable = await engine.ping()
        await engine.refreshList()
    }

    // MARK: Magnet

    private var magnetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stream a torrent").font(.title3.weight(.bold))
            HStack(spacing: 10) {
                TextField("Paste a magnet link", text: $magnet)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    #endif
                Button("Play") {
                    player.playMagnet(magnet.trimmed)
                    magnet = ""
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(TorrentSource.parse(magnet: magnet.trimmed) == nil)
            }
            #if os(iOS)
            Button { importing = true } label: { Label("Open .torrent file", systemImage: "doc.badge.plus") }
                .font(.subheadline)
            #endif
            Text("Engine: \(engine.mode.label)\(reachable == false ? " — not reachable" : "")")
                .font(.caption).foregroundStyle(reachable == false ? Theme.live : Theme.secondaryText)
        }
    }

    // MARK: Torrents

    private var torrentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Torrents").font(.title3.weight(.bold))
                if engine.activeCount > 0 {
                    Pill(text: "\(engine.activeCount) active", color: Theme.accent.opacity(0.4))
                }
            }
            if engine.torrents.isEmpty {
                Text(engine.isConfigured ? "No torrents right now. Streams you start from addons show up here."
                                         : "Set up torrent streaming in Settings → Torrent Streaming.")
                    .font(.subheadline).foregroundStyle(Theme.secondaryText)
            }
            ForEach(engine.torrents) { t in
                TorrentCard(status: t, origin: engine.origin(for: t.hash), history: engine.speedHistory[t.hash] ?? []) { action in
                    perform(action, on: t)
                }
            }
        }
    }

    private func perform(_ action: TorrentCard.Action, on t: TorrentStatus) {
        switch action {
        case .play(let file):
            let origin = engine.origin(for: t.hash)
            let source = TorrentSource(infoHash: t.hash, fileIdx: file.id - 1, filename: file.name, title: origin?.title ?? t.title,
                                       poster: origin?.poster ?? t.poster, season: origin?.season, episode: origin?.episode,
                                       addonName: origin?.addonName, itemID: origin?.itemID)
            let item = MediaItem(id: origin?.itemID ?? "torrent:\(t.hash):\(file.id)", type: .other, title: origin?.title ?? file.name,
                                 poster: origin?.poster ?? t.poster, origin: .tmdb(id: 0))
            player.play(PlaybackRequest(item: item,
                                        source: PlaybackSource(id: "tfile:\(t.hash):\(file.id)", kind: .torrent(source), title: file.name, provider: "Torrent")))
        case .stop:
            Task { await engine.drop(t.hash); await engine.refreshList() }
        case .remove:
            Task { await engine.remove(t.hash) }
        case .keep:
            Task {
                do {
                    try await engine.keep(t)
                    message = "“\(t.title)” is saved in TorrServer and will stay after restarts."
                } catch {
                    message = error.localizedDescription
                }
            }
        }
    }

    // MARK: Downloads

    @ViewBuilder
    private var downloadsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downloads").font(.title3.weight(.bold))
            if !DownloadManager.isSupported {
                Text(DownloadManager.unsupportedReason).font(.subheadline).foregroundStyle(Theme.secondaryText)
            } else {
                HStack(spacing: 14) {
                    Label(downloads.storageUsed.byteText + " used", systemImage: "internaldrive")
                    if let free = downloads.freeSpace { Text("\(free.byteText) free") }
                }
                .font(.caption).foregroundStyle(Theme.secondaryText)
                if downloads.visibleRecords.contains(where: { $0.isTorrent && $0.state != .completed }), engine.mode == .embedded {
                    Label("Torrent downloads use the on-device engine, which iOS pauses when StreamForge is in the background. Keep the app open until they finish, or use a remote TorrServer.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.gold)
                }
                if downloads.visibleRecords.isEmpty {
                    Text("Download movies and episodes from their detail pages to watch offline.")
                        .font(.subheadline).foregroundStyle(Theme.secondaryText)
                }
                ForEach(downloads.visibleRecords) { rec in
                    DownloadRow(record: rec)
                }
            }
        }
    }
}

/// One torrent with live stats, a speed sparkline and actions.
struct TorrentCard: View {
    enum Action { case play(TorrentFile), stop, remove, keep }

    var status: TorrentStatus
    var origin: TorrentOrigin?
    var history: [Double]
    var onAction: (Action) -> Void

    private var posterWidth: CGFloat {
        #if os(tvOS)
        return 120
        #else
        return 64
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                RemoteImage(url: origin?.poster ?? status.poster, placeholderSymbol: "arrow.down.circle")
                    .frame(width: posterWidth, height: posterWidth * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(origin?.title ?? status.title).font(.headline).lineLimit(2)
                    HStack(spacing: 6) {
                        if let code = origin?.episodeCode { Pill(text: code) }
                        if let addon = origin?.addonName { Pill(text: addon, color: Theme.accent.opacity(0.35)) }
                        if origin?.kept == true { Pill(text: "KEPT", color: Color.green.opacity(0.35), icon: "pin.fill") }
                        Text(status.statText.replacingOccurrences(of: "Torrent ", with: "").capitalized)
                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    }
                    if let file = origin?.fileName {
                        Text(file).font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    statsGrid
                }
                Spacer(minLength: 0)
            }
            if status.size > 0 {
                ProgressLine(fraction: Double(status.loaded) / Double(status.size), height: 4)
            }
            Sparkline(values: history)
                .frame(height: 34)
            HStack(spacing: 10) {
                if let file = status.videoFiles.first(where: { $0.name == origin?.fileName }) ?? status.videoFiles.max(by: { $0.length < $1.length }) {
                    Button { onAction(.play(file)) } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                }
                if status.stat <= 3 {
                    Button { onAction(.stop) } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.bordered)
                }
                if origin?.kept != true {
                    Button { onAction(.keep) } label: { Label("Keep", systemImage: "pin") }
                        .buttonStyle(.bordered)
                }
                Button(role: .destructive) { onAction(.remove) } label: { Label("Remove", systemImage: "trash") }
                    .buttonStyle(.bordered)
            }
            .font(.caption.weight(.semibold))
            if status.videoFiles.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(status.videoFiles.count) files").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    ForEach(status.videoFiles.prefix(12)) { f in
                        Button { onAction(.play(f)) } label: {
                            Label("\(f.name) · \(f.length.byteText)", systemImage: "play.circle").font(.caption).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var statsGrid: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                Label("\(status.activePeers)/\(status.totalPeers) peers", systemImage: "person.2")
                Label("\(status.seeders) seeds", systemImage: "leaf")
            }
            HStack(spacing: 12) {
                Label("\(Int64(status.downloadSpeed).byteText)/s", systemImage: "arrow.down")
                Label("\(Int64(status.uploadSpeed).byteText)/s", systemImage: "arrow.up")
            }
            HStack(spacing: 12) {
                Text("\(status.loaded.byteText) of \(status.size > 0 ? status.size.byteText : "?")")
                if status.preloaded > 0 { Text("Preloaded \(status.preloaded.byteText)") }
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.secondaryText)
    }
}

/// Tiny speed chart for the last 60 samples.
struct Sparkline: View {
    var values: [Double]

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 0, 1)
            let count = max(values.count - 1, 1)
            ZStack {
                if values.count > 1 {
                    Path { p in
                        for (i, v) in values.enumerated() {
                            let x = geo.size.width * CGFloat(i) / CGFloat(count)
                            let y = geo.size.height * (1 - CGFloat(v / maxV))
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        p.addLine(to: CGPoint(x: 0, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [Theme.accent.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        for (i, v) in values.enumerated() {
                            let x = geo.size.width * CGFloat(i) / CGFloat(count)
                            let y = geo.size.height * (1 - CGFloat(v / maxV))
                            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                } else {
                    Rectangle().fill(Theme.surface).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct DownloadRow: View {
    var record: DownloadRecord
    private var manager: DownloadManager { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(url: manager.posterURL(record), placeholderSymbol: "arrow.down.circle")
                .frame(width: 54, height: 81)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(record.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("\(record.provider) · \(record.sourceTitle)").font(.caption2).foregroundStyle(Theme.secondaryText).lineLimit(1)
                switch record.state {
                case .completed:
                    Text("Downloaded · \(record.bytesWritten.byteText)").font(.caption).foregroundStyle(.green)
                case .failed:
                    Text(record.error ?? "Failed").font(.caption).foregroundStyle(Theme.live).lineLimit(2)
                case .preparing:
                    Text("Preparing torrent…").font(.caption).foregroundStyle(Theme.secondaryText)
                default:
                    ProgressLine(fraction: record.fraction, height: 4)
                    Text("\(record.state == .paused ? "Paused · " : "")\(record.bytesWritten.byteText)\(record.bytesExpected > 0 ? " of \(record.bytesExpected.byteText)" : "")")
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                }
                HStack(spacing: 10) {
                    switch record.state {
                    case .completed:
                        Button { manager.play(record) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                    case .downloading, .queued, .preparing:
                        Button { manager.pause(record) } label: { Label("Pause", systemImage: "pause.fill") }
                            .buttonStyle(.bordered)
                    case .paused:
                        Button { manager.resume(record) } label: { Label("Resume", systemImage: "play.fill") }
                            .buttonStyle(.bordered)
                    case .failed:
                        Button { manager.retry(record) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                            .buttonStyle(.bordered)
                    }
                    Button(role: .destructive) { manager.delete(record) } label: { Label("Delete", systemImage: "trash") }
                        .buttonStyle(.bordered)
                }
                .font(.caption.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
