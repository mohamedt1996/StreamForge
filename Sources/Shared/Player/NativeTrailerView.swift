import SwiftUI
import AVKit

/// Trailers are YouTube only. Web pages are never handed to AVPlayer; the only native
/// playback is the user's optional Invidious proxy of a YouTube trailer.
enum TrailerSource: Equatable {
    case youtube(String)

    static func parse(_ raw: String) -> TrailerSource? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let scheme = url.scheme {
            guard ["http", "https"].contains(scheme.lowercased()), url.host != nil,
                  url.user == nil, url.password == nil else { return nil }
            return MediaDetails.cleanYouTubeKey(text).map { .youtube($0) }
        }
        return MediaDetails.cleanYouTubeKey(text).map { .youtube($0) }
    }

    static func ordered(_ sources: [TrailerSource]) -> [TrailerSource] {
        var unique: [TrailerSource] = []
        for source in sources where !unique.contains(source) { unique.append(source) }
        return unique
    }
}

@MainActor
enum NativeTrailerResolver {
    static func resolve(item: MediaItem, source: PlaybackSource? = nil) async -> URL? {
        let details = await MetadataService.shared.details(for: item)
        guard !Task.isCancelled else { return nil }
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
