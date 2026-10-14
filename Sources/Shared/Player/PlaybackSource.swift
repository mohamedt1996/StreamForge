import Foundation
import Observation

/// A single playable option shown in the source picker.
struct PlaybackSource: Identifiable, Hashable {
    enum Kind: Hashable {
        case direct(URL, headers: [String: String])
        case torrent(TorrentSource)
        case dispatcharrRecording(id: Int)
        case external(URL)
    }

    var id: String
    var kind: Kind
    var title: String
    var detail: String?
    var provider: String
    var providerLogo: URL?
    var resolution: Int = 0
    var tags: [String] = []
    var sizeBytes: Int64?
    var seeders: Int?
    var isCached: Bool = false
    var bingeGroup: String?
    var subtitles: [StremioSubtitle] = []
    var filename: String?

    var isTorrent: Bool { if case .torrent = kind { return true }; return false }

    var resolutionLabel: String {
        switch resolution {
        case 2160...: return "4K"
        case 1440..<2160: return "1440p"
        case 1080..<1440: return "1080p"
        case 720..<1080: return "720p"
        case 1..<720: return "SD"
        default: return ""
        }
    }

    /// Ranks sources: cached/direct first, then resolution, HDR, seeders.
    var score: Double {
        var s = Double(resolution)
        if tags.contains("DV") { s += 60 }
        if tags.contains("HDR") || tags.contains("HDR10+") { s += 40 }
        if tags.contains("Atmos") { s += 10 }
        if tags.contains("REMUX") { s += 20 }
        if isCached { s += 2000 }
        if case .direct = kind { s += 500 }
        if let seeders { s += min(Double(seeders), 200) / 4 }
        if tags.contains("CAM") { s -= 3000 }
        return s
    }
}

/// Extracts quality, HDR flags, size and seeders from the free-form text addons return.
enum StreamTextParser {
    private static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private static let resRegex = regex(#"\b(2160|1440|1080|720|576|480|360)p\b|\b(4k|uhd)\b"#)
    private static let sizeRegex = regex(#"(\d+(?:[.,]\d+)?)\s*(gb|mb|gib|mib)\b"#)
    private static let seedRegex = regex(#"(?:👤|seeders?:?|seeds?:?|s:)\s*(\d+)"#)

    struct Parsed { var resolution = 0; var tags: [String] = []; var size: Int64?; var seeders: Int?; var cached = false }

    static func parse(_ text: String) -> Parsed {
        var p = Parsed()
        let ns = NSRange(text.startIndex..., in: text)
        if let m = resRegex.firstMatch(in: text, range: ns) {
            if let r = Range(m.range(at: 1), in: text) { p.resolution = Int(text[r]) ?? 0 } else { p.resolution = 2160 }
        }
        if let m = sizeRegex.matches(in: text, range: ns).last,
           let nr = Range(m.range(at: 1), in: text), let ur = Range(m.range(at: 2), in: text),
           let value = Double(text[nr].replacingOccurrences(of: ",", with: ".")) {
            let unit = text[ur].lowercased()
            p.size = Int64(value * (unit.hasPrefix("g") ? 1_073_741_824 : 1_048_576))
        }
        if let m = seedRegex.firstMatch(in: text, range: ns), let r = Range(m.range(at: 1), in: text) {
            p.seeders = Int(text[r])
        }
        let lower = text.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { lower.contains($0) } }
        if has("dolby vision", " dv ", ".dv.", "dovi", "[dv]", " dv|", "dv hdr") { p.tags.append("DV") }
        if has("hdr10+", "hdr10plus") { p.tags.append("HDR10+") } else if has("hdr") { p.tags.append("HDR") }
        if has("remux") { p.tags.append("REMUX") }
        if has("hevc", "x265", "h265", "h.265") { p.tags.append("HEVC") }
        if has("av1") { p.tags.append("AV1") }
        if has("atmos") { p.tags.append("Atmos") }
        if has("dts-hd", "dts-x", "truehd") { p.tags.append("Lossless") }
        if has(" cam ", "camrip", "hdcam", ".cam.", "telesync", " ts ", "hdts") { p.tags.append("CAM") }
        if has("[rd+]", "[ad+]", "[pm+]", "[tb+]", "[dl+]", "rd+", "⚡", "instant", "cached") { p.cached = true }
        return p
    }
}

/// Collects sources for one item/episode from Dispatcharr and every Stremio addon, incrementally.
@MainActor
@Observable
final class SourcesModel {
    private(set) var sources: [PlaybackSource] = []
    private(set) var loadingAddons: Set<String> = []
    private(set) var isLoading = false
    private(set) var subtitles: [StremioSubtitle] = []

    let item: MediaItem
    let episode: EpisodeRef?

    init(item: MediaItem, episode: EpisodeRef?) {
        self.item = item
        self.episode = episode
    }

    var sorted: [PlaybackSource] {
        let settings = AppSettings.shared.values
        var list = sources
        if settings.excludeCam { list = list.filter { !$0.tags.contains("CAM") } }
        list = list.filter { $0.resolution <= settings.maxStreamResolution || $0.resolution == 0 }
        switch settings.streamSort {
        case .quality: return list.sorted { $0.score > $1.score }
        case .size: return list.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        case .seeders: return list.sorted { ($0.seeders ?? -1) > ($1.seeders ?? -1) }
        case .fastest:
            let est = StartEstimator.shared
            let keyed = list.map { ($0, est.fastestKey($0, runtimeMinutes: runtimeMinutes, isEpisode: episode != nil)) }
            return keyed.sorted { $0.1 < $1.1 }.map(\.0)
        case .addon: return list
        }
    }

    var bestSource: PlaybackSource? { sorted.first }

    var runtimeMinutes: Int? { episode?.runtimeMinutes ?? item.runtimeMinutes }

    func estimate(_ source: PlaybackSource) -> StartEstimator.Estimate? {
        StartEstimator.shared.estimate(source, runtimeMinutes: runtimeMinutes, isEpisode: episode != nil)
    }

    func load() async {
        isLoading = true
        sources = []
        await prepareDispatcharrPlayback()
        addDispatcharrSources()
        await loadAddonStreams()
        isLoading = false
    }

    /// REST streaming servers address streams by UUID: look up any this device hasn't seen yet
    /// (e.g. an episode from Continue Watching synced from another device).
    private func prepareDispatcharrPlayback() async {
        guard let client = DispatcharrStore.shared.client, client.server.usesRESTStreaming else { return }
        var movieID: Int?
        if case .dispatcharrMovie(_, let id, _) = item.origin { movieID = id }
        await client.preparePlayback(movieID: episode == nil ? movieID : nil, episodeID: episode?.dispatcharrEpisodeID)
    }

    private func addDispatcharrSources() {
        let store = DispatcharrStore.shared
        guard let server = store.activeServer, let client = store.client else { return }
        let name = server.name.isEmpty ? "Dispatcharr" : server.name

        func add(url: URL?, title: String, detail: String?, ext: String?) {
            guard let url else { return }
            var s = PlaybackSource(id: "dispatcharr:\(url.absoluteString)", kind: .direct(url, headers: [:]),
                                   title: title, detail: detail, provider: name)
            s.isCached = true
            let parsed = StreamTextParser.parse(title + " " + (ext ?? ""))
            s.resolution = parsed.resolution
            s.tags = parsed.tags + (ext.map { [$0.uppercased()] } ?? [])
            sources.append(s)
        }

        if let episode {
            if let eid = episode.dispatcharrEpisodeID {
                add(url: client.episodeURL(eid, ext: episode.ext ?? "mp4"), title: "\(item.title) \(episode.code)", detail: "From your server", ext: episode.ext)
            }
            return
        }
        switch item.origin {
        case .dispatcharrMovie(_, let id, let ext):
            add(url: client.movieURL(id, ext: ext), title: item.title, detail: "From your server", ext: ext)
        default:
            if item.type == .movie, let m = store.matchMovie(tmdbID: item.tmdbID, imdbID: item.imdbID, title: item.title, year: item.year) {
                add(url: client.movieURL(m.id, ext: m.ext), title: m.name, detail: "From your server", ext: m.ext)
            }
        }
    }

    private func loadAddonStreams() async {
        let type = item.type == .movie ? "movie" : "series"
        let id: String?
        if let episode {
            id = episode.stremioVideoID ?? item.imdbID.map { "\($0):\(episode.season):\(episode.episode)" }
        } else {
            id = item.stremioID
        }
        guard let id else { return }
        loadingAddons = Set(AddonManager.shared.enabled.filter { $0.manifest.supports("stream", type: type, id: id) }.map(\.id))
        let ep = episode
        let poster = item.poster
        let itemTitle = item.title
        let itemID = item.id
        await AddonManager.shared.streams(type: type, id: id) { [weak self] addon, streams in
            guard let self else { return }
            self.loadingAddons.remove(addon.id)
            self.sources.append(contentsOf: streams.enumerated().compactMap { i, s in
                Self.makeSource(s, index: i, addon: addon, episode: ep, poster: poster, itemTitle: itemTitle, itemID: itemID)
            })
            for s in streams { self.subtitles.append(contentsOf: s.subtitles) }
        }
        loadingAddons = []
    }

    static func makeSource(_ s: StremioStream, index: Int, addon: InstalledAddon, episode: EpisodeRef?, poster: URL?, itemTitle: String,
                           itemID: String? = nil) -> PlaybackSource? {
        let name = s.name ?? addon.manifest.name
        let text = [s.name, s.title, s.description, s.hints?.filename].compactMap { $0 }.joined(separator: " ")
        let parsed = StreamTextParser.parse(text)
        let lines = (s.title ?? s.description ?? "").split(separator: "\n").map(String.init)
        let kind: PlaybackSource.Kind
        if let url = s.url {
            kind = .direct(url, headers: s.hints?.requestHeaders ?? [:])
        } else if let hash = s.infoHash {
            let trackers = s.sources.compactMap { src -> String? in
                src.hasPrefix("tracker:") ? String(src.dropFirst("tracker:".count)) : nil
            }
            kind = .torrent(TorrentSource(infoHash: hash, fileIdx: s.fileIdx, filename: s.hints?.filename, trackers: trackers,
                                          title: itemTitle, poster: poster, season: episode?.season, episode: episode?.episode,
                                          addonName: addon.manifest.name, itemID: itemID))
        } else if let ext = s.externalURL {
            kind = .external(ext)
        } else if let yt = s.ytID, let url = URL(string: "https://www.youtube.com/watch?v=\(yt)") {
            kind = .external(url)
        } else {
            return nil
        }
        var source = PlaybackSource(
            id: "\(addon.id):\(index):\(s.infoHash ?? s.url?.absoluteString ?? "")",
            kind: kind,
            title: lines.first ?? name,
            detail: lines.dropFirst().joined(separator: " · ").nilIfEmpty,
            provider: name.replacingOccurrences(of: "\n", with: " "),
            providerLogo: addon.logoURL)
        source.resolution = parsed.resolution
        source.tags = parsed.tags
        source.sizeBytes = s.hints?.videoSize ?? parsed.size
        source.seeders = parsed.seeders
        source.isCached = parsed.cached
        source.bingeGroup = s.hints?.bingeGroup
        source.subtitles = s.subtitles
        source.filename = s.hints?.filename
        return source
    }
}
