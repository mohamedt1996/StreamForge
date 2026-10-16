import SwiftUI
import AVKit

/// URL check kept for any metadata code that still recognises direct links. Trailers don't
/// play direct links; they use YouTube, then IMDb.
enum TrailerSelection {
    static func directURL(_ url: URL?) -> URL? {
        guard let url, url.host != nil, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              ["mp4", "m4v", "mov", "m3u8"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
    }
}

/// Trailer sources, tried in this order: YouTube first, IMDb as the backup.
/// A YouTube id plays in the iOS embed, or natively through the user's optional Invidious
/// instance (the only route on tvOS, which has no WebKit). IMDb is iOS only (embed page).
enum TrailerSource: Equatable {
    case youtube(String)
    /// An IMDb video id ("vi12345") from metadata.
    case imdb(String)
    /// Look the trailer up on the title's IMDb page ("tt0111161") when YouTube doesn't play.
    case imdbTitle(String)

    var youTubeKey: String? {
        if case .youtube(let key) = self { return key }
        return nil
    }

    static func imdbVideoID(_ raw: String) -> String? {
        guard let url = URL(string: raw), url.scheme == "https",
              ["imdb.com", "www.imdb.com", "m.imdb.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        return url.path.split(separator: "/").map(String.init).first {
            $0.hasPrefix("vi") && $0.count > 2 && $0.dropFirst(2).allSatisfy(\.isNumber)
        }
    }

    /// A bare YouTube id, a youtube.com / youtu.be link or an IMDb video link. Anything else is ignored.
    static func parse(_ raw: String) -> TrailerSource? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let scheme = url.scheme {
            guard ["http", "https"].contains(scheme.lowercased()), url.host != nil,
                  url.user == nil, url.password == nil else { return nil }
            if let id = imdbVideoID(text) { return .imdb(id) }
        }
        return MediaDetails.cleanYouTubeKey(text).map { .youtube($0) }
    }

    /// YouTube first (in metadata order), then IMDb; duplicates removed.
    static func ordered(_ sources: [TrailerSource]) -> [TrailerSource] {
        func rank(_ s: TrailerSource) -> Int {
            switch s { case .youtube: return 0; case .imdb: return 1; case .imdbTitle: return 2 }
        }
        var unique: [TrailerSource] = []
        for source in sources where !unique.contains(source) { unique.append(source) }
        return unique.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

/// Best-effort IMDb trailer lookup from the title's public structured data (JSON-LD), never from
/// the generic latest-trailers feed. HTTP blocks, consent pages and missing links just fail.
enum IMDbTrailerResolver {
    static func videoID(imdbID: String) async -> String? {
        guard imdbID.hasPrefix("tt"), imdbID.count > 2,
              imdbID.dropFirst(2).allSatisfy(\.isNumber),
              let url = URL(string: "https://www.imdb.com/title/\(imdbID)/") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            var data = Data()
            for try await byte in bytes {
                if Task.isCancelled || data.count >= 2_000_000 { return nil }
                data.append(byte)
            }
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            return videoID(inHTML: html)
        } catch { return nil }
    }

    static func videoID(inHTML html: String) -> String? {
        let pattern = #"(?is)<script\b[^>]*\btype\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        func trailerID(_ object: Any) -> String? {
            if let array = object as? [Any] { return array.compactMap(trailerID).first }
            guard let node = object as? [String: Any] else { return nil }
            if let graph = node["@graph"], let id = trailerID(graph) { return id }
            let trailers = (node["trailer"] as? [Any]) ?? node["trailer"].map { [$0] } ?? []
            for entry in trailers {
                if let link = entry as? String, let id = TrailerSource.imdbVideoID(link) { return id }
                if let video = entry as? [String: Any] {
                    for key in ["embedUrl", "url"] {
                        if let link = video[key] as? String, let id = TrailerSource.imdbVideoID(link) { return id }
                    }
                }
            }
            return nil
        }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html),
                  let data = String(html[range]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let id = trailerID(object) { return id }
        }
        return nil
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
