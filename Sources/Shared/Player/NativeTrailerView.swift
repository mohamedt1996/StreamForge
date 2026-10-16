import SwiftUI
import AVKit

/// Direct URLs are playable by AVPlayer; YouTube web pages are never passed to it.
enum TrailerSelection {
    static func directURL(_ url: URL?) -> URL? {
        guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              ["mp4", "m4v", "mov", "m3u8"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
}

@MainActor
enum NativeTrailerResolver {
    static func resolve(item: MediaItem, source: PlaybackSource? = nil) async -> URL? {
        if let url = TrailerSelection.directURL(source?.trailerURL) ?? TrailerSelection.directURL(item.trailerURL) { return url }
        let details = await MetadataService.shared.details(for: item)
        guard !Task.isCancelled else { return nil }
        if let url = TrailerSelection.directURL(details.item.trailerURL) { return url }
        let instance = AppSettings.shared.values.invidiousInstance
        guard !instance.isEmpty else { return nil }
        for key in details.trailerKeys {
            if let url = await InvidiousTrailer.streamURL(instance: instance, youtubeKey: key) {
                guard !Task.isCancelled else { return nil }
                return url
            }
            if Task.isCancelled { return nil }
        }
        return nil
    }
}

/// Owns the queue and looper only for the lifetime of the visible preview.
struct NativeTrailerView: View {
    let item: MediaItem
    var source: PlaybackSource? = nil
    var muted = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var unavailable = false

    var body: some View {
        ZStack {
            Color.black
            if unavailable {
                Text("No playable preview available").padding()
            } else if let player {
                VideoPlayer(player: player)
                    .disabled(muted)
            } else { ProgressView("Loading trailer…") }
        }
        .task(id: item.id) {
            player?.pause()
            looper?.disableLooping()
            player?.removeAllItems()
            player = nil
            looper = nil
            unavailable = false
            guard let url = await NativeTrailerResolver.resolve(item: item, source: source), !Task.isCancelled else {
                if !Task.isCancelled { unavailable = true }
                return
            }
            let queue = AVQueuePlayer()
            queue.isMuted = muted
            let loop = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
            player = queue
            looper = loop
            TrailerAudio.prepare(muted: muted)
            if scenePhase == .active { queue.play() }
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            if queue.currentItem?.status != .readyToPlay {
                queue.pause()
                unavailable = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { note in
            if let failed = note.object as? AVPlayerItem, failed === player?.currentItem {
                player?.pause()
                unavailable = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { player?.play() } else { player?.pause() }
        }
        .onDisappear {
            player?.pause()
            looper?.disableLooping()
            player?.removeAllItems()
            looper = nil
            player = nil
        }
    }
}
