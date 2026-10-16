import SwiftUI
import AVKit

/// URL check kept for any metadata code that still recognises direct links. Trailers no longer
/// play them; they are YouTube only.
enum TrailerSelection {
    static func directURL(_ url: URL?) -> URL? {
        guard let url, url.host != nil, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              ["mp4", "m4v", "mov", "m3u8"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
}

/// Trailers are YouTube only. A YouTube id plays in the iOS embed, or natively through the
/// user's optional Invidious instance (the only route on tvOS, which has no WebKit).
enum TrailerSource: Equatable {
    case youtube(String)

    var youTubeKey: String {
        switch self { case .youtube(let key): return key }
    }

    /// Accepts a bare YouTube id or a youtube.com / youtu.be link. Anything else is ignored.
    static func parse(_ raw: String) -> TrailerSource? {
        MediaDetails.cleanYouTubeKey(raw).map { .youtube($0) }
    }

    /// Removes duplicates, keeping the metadata's order (best first).
    static func ordered(_ sources: [TrailerSource]) -> [TrailerSource] {
        var unique: [TrailerSource] = []
        for source in sources where !unique.contains(source) { unique.append(source) }
        return unique
    }
}

@MainActor
enum NativeTrailerResolver {
    /// Native playback of the title's YouTube trailer via Invidious; nil when not configured.
    static func resolve(item: MediaItem) async -> URL? {
        let instance = AppSettings.shared.values.invidiousInstance
        guard !instance.isEmpty else { return nil }
        let details = await MetadataService.shared.details(for: item)
        guard !Task.isCancelled else { return nil }
        for key in details.trailerKeys.prefix(3) {
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
            guard let url = await NativeTrailerResolver.resolve(item: item), !Task.isCancelled else {
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
