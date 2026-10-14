import SwiftUI

struct DownloadSheetContext: Identifiable {
    let id = UUID()
    var item: MediaItem
    var episode: EpisodeRef?
}

/// Pick which source (quality) to download. Only direct HTTP and torrent sources qualify.
struct DownloadSourceSheet: View {
    var context: DownloadSheetContext
    @Environment(\.dismiss) private var dismiss
    @State private var model: SourcesModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    let list = model.sorted.filter { DownloadManager.canDownload($0) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if TorrentEngine.shared.mode == .embedded, list.contains(where: \.isTorrent) {
                                Label("Torrent downloads run through the on-device engine and pause when you leave the app.",
                                      systemImage: "info.circle")
                                    .font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                            if list.isEmpty && !model.isLoading {
                                EmptyStateView(icon: "arrow.down.circle", title: "Nothing to download",
                                               message: "None of the sources for this title can be downloaded. Server files and direct or torrent addon links can.")
                            }
                            ForEach(list) { s in
                                SourceRow(source: s) {
                                    DownloadManager.shared.start(item: context.item, episode: context.episode, source: s)
                                    dismiss()
                                }
                            }
                            if model.isLoading {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Finding sources…").font(.footnote).foregroundStyle(Theme.secondaryText)
                                }
                                .padding()
                            }
                        }
                        .padding(Theme.gutter)
                    }
                } else {
                    LoadingView(text: "Finding sources…")
                }
            }
            .screenBackground()
            .navigationTitle("Download")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .task {
            let m = SourcesModel(item: context.item, episode: context.episode)
            model = m
            await m.load()
        }
    }
}

/// Download / downloaded indicator button used on detail pages and episode rows.
struct DownloadButton: View {
    var item: MediaItem
    var episode: EpisodeRef?
    var onRequest: () -> Void
    private var manager: DownloadManager { .shared }

    var body: some View {
        let record = manager.record(for: item, episode: episode)
        Button {
            if let record, record.state == .completed {
                manager.play(record)
            } else if record == nil || record?.state == .failed {
                onRequest()
            } else {
                AppRouter.shared.showActivity()
            }
        } label: {
            ZStack {
                switch record?.state {
                case .completed?:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .downloading?, .preparing?, .queued?:
                    ProgressRing(fraction: record?.fraction ?? 0)
                case .paused?:
                    Image(systemName: "pause.circle")
                case .failed?:
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.live)
                case nil:
                    Image(systemName: "arrow.down.circle")
                }
            }
            .font(.headline)
            .frame(width: 22, height: 22)
            .padding(.vertical, 6)
        }
        .accessibilityLabel(record?.state == .completed ? "Play download" : "Download")
    }
}

struct ProgressRing: View {
    var fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(Theme.surfaceHigh, lineWidth: 3)
            Circle().trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
