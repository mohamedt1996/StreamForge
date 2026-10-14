import Foundation
import Observation
import MediaPlayer
import AVFoundation
import UIKit

/// Everything the player needs to start: what to play and the surrounding context.
struct PlaybackRequest: Identifiable {
    let id = UUID()
    var item: MediaItem
    var episode: EpisodeRef?
    var source: PlaybackSource
    var startPosition: Double?
    /// Remaining episodes after this one, for autoplay.
    var upcoming: [EpisodeRef] = []
    /// Live TV context.
    var channelID: Int?
    var channelList: [XCChannel] = []
    var catchup: XCEPGListing?

    var isLive: Bool { channelID != nil && catchup == nil }

    var displayTitle: String {
        if let catchup { return catchup.title }
        return item.title
    }

    var displaySubtitle: String? {
        if let episode { return "\(episode.code) · \(episode.title)" }
        if catchup != nil { return "\(item.title) · Catch-up" }
        return item.yearText
    }
}

/// App-wide entry point for starting playback; the root view presents the player for `current`.
@MainActor
@Observable
final class PlayerCoordinator {
    static let shared = PlayerCoordinator()
    var current: PlaybackRequest?
    var sourcePickerRequest: (item: MediaItem, episode: EpisodeRef?, upcoming: [EpisodeRef])?
    private init() {}

    func play(_ request: PlaybackRequest) { current = request }

    func playChannel(_ channel: XCChannel, in list: [XCChannel]) {
        let store = DispatcharrStore.shared
        guard let server = store.activeServer, let url = store.client?.liveURL(channel.id) else { return }
        let source = PlaybackSource(id: "live:\(channel.id)", kind: .direct(url, headers: [:]), title: channel.name, provider: server.name)
        current = PlaybackRequest(item: channel.mediaItem(serverID: server.id), source: source, channelID: channel.id,
                                  channelList: list.isEmpty ? store.channels : list)
        LibraryStore.shared.recordChannel(channel.id)
    }

    func playCatchup(_ channel: XCChannel, programme: XCEPGListing) {
        let store = DispatcharrStore.shared
        guard let server = store.activeServer,
              let url = store.client?.catchupURL(channelID: channel.id, start: programme.start, end: programme.end) else { return }
        let source = PlaybackSource(id: "catchup:\(channel.id):\(programme.id)", kind: .direct(url, headers: [:]),
                                    title: programme.title, provider: server.name)
        current = PlaybackRequest(item: channel.mediaItem(serverID: server.id), source: source, channelID: channel.id, catchup: programme)
    }

    func playRecording(_ recording: DispatcharrRecording) {
        let store = DispatcharrStore.shared
        guard let server = store.activeServer else { return }
        let item = MediaItem(id: "recording:\(recording.id)", type: .other, title: recording.title, poster: recording.poster,
                             overview: recording.description, origin: .dispatcharrChannel(serverID: server.id, channelID: recording.channelID ?? 0))
        let source = PlaybackSource(id: "rec:\(recording.id)", kind: .dispatcharrRecording(id: recording.id), title: recording.title, provider: server.name)
        let resume = LibraryStore.shared.progress(for: item)?.position
        current = PlaybackRequest(item: item, source: source, startPosition: resume)
    }

    func playMagnet(_ magnet: String) {
        guard let t = TorrentSource.parse(magnet: magnet) else { return }
        let item = MediaItem(id: "torrent:\(t.infoHash)", type: .other, title: t.title ?? "Torrent", origin: .tmdb(id: 0))
        current = PlaybackRequest(item: item, source: PlaybackSource(id: "magnet:\(t.infoHash)", kind: .torrent(t), title: t.title ?? "Torrent", provider: "Magnet"))
    }
}

enum VideoFit: String, CaseIterable {
    case fit, fill, stretch
    var label: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .fit: return "rectangle.arrowtriangle.2.inward"
        case .fill: return "rectangle.arrowtriangle.2.outward"
        case .stretch: return "arrow.left.and.right.square"
        }
    }
}

@MainActor
@Observable
final class PlayerModel: MPVPlayerDelegate {
    private(set) var request: PlaybackRequest
    let player: MPVPlayer

    // Playback state
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var cachedUntil: Double = 0
    private(set) var isPaused = false
    private(set) var isBuffering = true
    private(set) var bufferPercent: Int?
    private(set) var hasStarted = false
    private(set) var statusText: String?
    private(set) var errorText: String?
    private(set) var ended = false
    private(set) var isHDR = false
    private(set) var speed: Double = 1

    // Tracks
    private(set) var audioTracks: [MPVTrack] = []
    private(set) var subtitleTracks: [MPVTrack] = []
    private(set) var videoTracks: [MPVTrack] = []
    private(set) var chapters: [MPVPlayer.Chapter] = []
    private(set) var addonSubtitles: [StremioSubtitle] = []
    private(set) var loadedAddonSubtitleIDs: Set<String> = []
    var subtitleDelay: Double = 0 { didSet { player.setDouble("sub-delay", subtitleDelay) } }
    var audioDelay: Double = 0 { didSet { player.setDouble("audio-delay", audioDelay) } }
    var subtitleScale: Double = AppSettings.shared.values.subtitleScale { didSet { player.setDouble("sub-scale", subtitleScale) } }
    private(set) var fit: VideoFit = .fit

    // Live / torrent
    private(set) var torrentStatus: TorrentStatus?
    private(set) var currentProgramme: XCEPGListing?
    private(set) var nextProgramme: XCEPGListing?

    // UI
    var showStats = false
    private(set) var stats: [(String, String)] = []

    private var resolveTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var lastSavedPosition: Double = 0
    private var resolvedTorrentHash: String?
    private var didScrobbleStart = false
    var onFinished: (() -> Void)?

    var isLive: Bool { request.isLive }
    var title: String { request.displayTitle }
    var subtitle: String? {
        if isLive, let p = currentProgramme { return p.title }
        return request.displaySubtitle
    }
    var remaining: Double { max(0, duration - position) }
    var nextEpisode: EpisodeRef? { request.upcoming.first }
    var showNextEpisodeCard: Bool {
        AppSettings.shared.values.autoplayNext && nextEpisode != nil && duration > 300 && remaining < 35 && remaining > 0
    }

    init(request: PlaybackRequest) {
        self.request = request
        let s = AppSettings.shared.values
        player = MPVPlayer(options: .init(
            hwdec: s.hwdec.rawValue, hdr: s.hdrPassthrough, cacheMB: s.demuxerCacheMB, userAgent: s.customUserAgent,
            audioLanguage: s.preferredAudioLanguage, subtitleLanguage: s.preferredSubtitleLanguage,
            autoSubtitles: s.autoSubtitles, subtitleScale: s.subtitleScale))
        player.delegate = self
        configureAudioSession()
        configureRemoteCommands()
    }

    // MARK: Lifecycle

    func start() {
        load(request)
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.tick()
            }
        }
    }

    func stop() {
        saveProgress(force: true)
        if hasStarted { scrobble(.stop) }
        resolveTask?.cancel()
        tickTask?.cancel()
        player.command("stop")
        player.shutdown()
        if let hash = resolvedTorrentHash { Task { await TorrentEngine.shared.drop(hash) } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func load(_ req: PlaybackRequest) {
        request = req
        resetState()
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (url, headers) = try await self.resolve(req.source)
                guard !Task.isCancelled else { return }
                let start = req.startPosition ?? self.resumePosition(for: req)
                self.player.load(url, start: start, headers: headers, title: req.displayTitle, live: req.isLive)
                self.updateNowPlaying()
                await self.loadAddonSubtitles(for: req)
            } catch is CancellationError {
            } catch {
                self.errorText = error.localizedDescription
                self.isBuffering = false
            }
        }
        if req.isLive, let id = req.channelID { Task { await refreshProgramme(id) } }
    }

    private func resetState() {
        position = 0; duration = 0; cachedUntil = 0; isPaused = false; isBuffering = true
        hasStarted = false; statusText = nil; errorText = nil; ended = false; torrentStatus = nil
        audioTracks = []; subtitleTracks = []; videoTracks = []; chapters = []
        addonSubtitles = []; loadedAddonSubtitleIDs = []; lastSavedPosition = 0; didScrobbleStart = false
        currentProgramme = nil; nextProgramme = nil
    }

    private func resumePosition(for req: PlaybackRequest) -> Double? {
        guard AppSettings.shared.values.resumePlayback, !req.isLive, req.catchup == nil,
              let p = LibraryStore.shared.progress(for: req.item, episode: req.episode), !p.isFinished, p.position > 30 else { return nil }
        return p.position - 5
    }

    private func resolve(_ source: PlaybackSource) async throws -> (URL, [String: String]) {
        switch source.kind {
        case .direct(let url, let headers):
            return (url, headers)
        case .external(let url):
            throw HTTPError.transport("This source opens outside the app: \(url.host ?? url.absoluteString)")
        case .dispatcharrRecording(let id):
            guard let rest = DispatcharrStore.shared.restClient() else {
                throw HTTPError.transport("Add your Dispatcharr web password in Settings to play recordings.")
            }
            let url = try await rest.recordingURL(id)
            return (url, await rest.playbackHeaders)
        case .torrent(let t):
            let engine = TorrentEngine.shared
            guard engine.isConfigured else {
                throw HTTPError.transport("Torrent streaming needs a TorrServer. Set one in Settings → Torrents.")
            }
            let result = try await engine.resolve(t) { [weak self] text in self?.statusText = text }
            resolvedTorrentHash = result.hash
            return (result.url, engine.playbackHeaders)
        }
    }

    private func loadAddonSubtitles(for req: PlaybackRequest) async {
        var subs = req.source.subtitles
        let type = req.item.type == .movie ? "movie" : "series"
        let id: String?
        if let ep = req.episode {
            id = ep.stremioVideoID ?? req.item.imdbID.map { "\($0):\(ep.season):\(ep.episode)" }
        } else {
            id = req.item.stremioID
        }
        if let id, req.channelID == nil {
            let fetched = await AddonManager.shared.subtitles(type: type, id: id, videoSize: req.source.sizeBytes, filename: req.source.filename)
            subs.append(contentsOf: fetched)
        }
        let preferred = AppSettings.shared.values.preferredSubtitleLanguage
        // Preferred language first, then alphabetical by language name.
        addonSubtitles = subs.sorted { a, b in
            let ap = a.lang.hasPrefix(preferred) || Locale(identifier: a.lang).language.languageCode?.identifier == preferred
            let bp = b.lang.hasPrefix(preferred) || Locale(identifier: b.lang).language.languageCode?.identifier == preferred
            if ap != bp { return ap }
            return a.languageName < b.languageName
        }
    }

    // MARK: Controls

    func togglePause() {
        if ended { seek(to: 0); ended = false }
        player.setFlag("pause", !isPaused)
    }

    func seek(to seconds: Double) {
        guard !isLive || request.catchup != nil else { return }
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        position = target
        player.command("seek", String(format: "%.3f", target), "absolute+exact")
        updateNowPlaying()
    }

    func seek(by delta: Double) {
        guard !isLive || request.catchup != nil else { return }
        seek(to: position + delta)
    }

    func selectAudio(_ track: MPVTrack) { player.set("aid", String(track.id)); refreshTracks() }
    func selectVideo(_ track: MPVTrack) { player.set("vid", String(track.id)); refreshTracks() }
    func selectSubtitle(_ track: MPVTrack?) {
        player.set("sid", track.map { String($0.id) } ?? "no")
        refreshTracks()
    }

    func loadAddonSubtitle(_ sub: StremioSubtitle) {
        if loadedAddonSubtitleIDs.contains(sub.id) {
            if let t = subtitleTracks.first(where: { $0.isExternal && $0.title == "\(sub.languageName) · Addon" }) { selectSubtitle(t) }
            return
        }
        loadedAddonSubtitleIDs.insert(sub.id)
        player.command("sub-add", sub.url.absoluteString, "select", "\(sub.languageName) · Addon", sub.lang)
    }

    func setSpeed(_ value: Double) { player.setDouble("speed", value) }

    func setFit(_ f: VideoFit) {
        fit = f
        switch f {
        case .fit:
            player.set("panscan", "0"); player.set("keepaspect", "yes")
        case .fill:
            player.set("keepaspect", "yes"); player.set("panscan", "1")
        case .stretch:
            player.set("panscan", "0"); player.set("keepaspect", "no")
        }
    }

    func cycleFit() {
        let all = VideoFit.allCases
        setFit(all[(all.firstIndex(of: fit)! + 1) % all.count])
    }

    func jumpToChapter(_ chapter: MPVPlayer.Chapter) { seek(to: chapter.time) }

    func retry() {
        errorText = nil
        load(request)
    }

    // MARK: Episodes / channels

    func playNextEpisode() {
        guard let next = request.upcoming.first else { return }
        saveProgress(force: true)
        scrobble(.stop)
        Task { await startEpisode(next, remaining: Array(request.upcoming.dropFirst())) }
    }

    private func startEpisode(_ episode: EpisodeRef, remaining: [EpisodeRef]) async {
        statusText = "Finding \(episode.code)…"
        isBuffering = true
        let sources = SourcesModel(item: request.item, episode: episode)
        await sources.load()
        // Prefer the same addon/quality group as the current stream (Stremio "bingeGroup").
        let previous = request.source
        let pick = sources.sorted.first { $0.bingeGroup != nil && $0.bingeGroup == previous.bingeGroup }
            ?? sources.sorted.first { $0.provider == previous.provider && $0.resolution == previous.resolution }
            ?? sources.bestSource
        guard let pick else {
            errorText = "No source found for \(episode.code)."
            isBuffering = false
            return
        }
        var next = request
        next.episode = episode
        next.source = pick
        next.startPosition = nil
        next.upcoming = remaining
        load(next)
    }

    var channelIndex: Int? {
        guard let id = request.channelID else { return nil }
        return request.channelList.firstIndex { $0.id == id }
    }

    func zap(_ offset: Int) {
        guard let i = channelIndex, !request.channelList.isEmpty else { return }
        let list = request.channelList
        let next = list[(i + offset + list.count) % list.count]
        switchChannel(next)
    }

    func switchChannel(_ channel: XCChannel) {
        let store = DispatcharrStore.shared
        guard let server = store.activeServer, let url = store.client?.liveURL(channel.id) else { return }
        var req = request
        req.item = channel.mediaItem(serverID: server.id)
        req.channelID = channel.id
        req.catchup = nil
        req.source = PlaybackSource(id: "live:\(channel.id)", kind: .direct(url, headers: [:]), title: channel.name, provider: server.name)
        LibraryStore.shared.recordChannel(channel.id)
        load(req)
    }

    var currentChannel: XCChannel? { request.channelID.flatMap { id in request.channelList.first { $0.id == id } ?? DispatcharrStore.shared.channel(id) } }

    private func refreshProgramme(_ channelID: Int) async {
        let store = DispatcharrStore.shared
        await store.loadEPG(channelID)
        guard request.channelID == channelID else { return }
        currentProgramme = store.nowPlaying(channelID)
        nextProgramme = store.nextUp(channelID)
        updateNowPlaying()
    }

    // MARK: Delegate

    func mpvPropertyChanged(_ name: String, value: Any?) {
        switch name {
        case "time-pos":
            if let v = value as? Double { position = v; if v > 0.3 && !hasStarted { didStart() } }
        case "duration":
            duration = (value as? Double) ?? 0
        case "pause":
            isPaused = (value as? Bool) ?? false
            updateNowPlaying()
            if hasStarted { scrobble(isPaused ? .pause : .start) }
        case "paused-for-cache":
            isBuffering = (value as? Bool) ?? false
        case "core-idle":
            if (value as? Bool) == false, hasStarted { isBuffering = false }
        case "cache-buffering-state":
            bufferPercent = value as? Int
        case "demuxer-cache-time":
            cachedUntil = (value as? Double) ?? 0
        case "eof-reached":
            if (value as? Bool) == true { didReachEnd() }
        case "video-params/sig-peak":
            isHDR = ((value as? Double) ?? 1) > 1
        case "speed":
            speed = (value as? Double) ?? 1
        case "chapter-list/count":
            chapters = player.chapters()
        default:
            break
        }
    }

    func mpvFileLoaded() {
        statusText = nil
        errorText = nil
        duration = player.double("duration") ?? 0
        chapters = player.chapters()
        if fit != .fit { setFit(fit) }
    }

    func mpvEndFile(error: String?) {
        if let error {
            errorText = isLive ? "The channel stopped responding (\(error))." : "Playback failed: \(error)"
            isBuffering = false
        }
    }

    func mpvTracksChanged() { refreshTracks() }

    private func refreshTracks() {
        let all = player.tracks()
        audioTracks = all.filter { $0.kind == .audio }
        subtitleTracks = all.filter { $0.kind == .sub }
        videoTracks = all.filter { $0.kind == .video }
    }

    private func didStart() {
        hasStarted = true
        isBuffering = false
        statusText = nil
        scrobble(.start)
        updateNowPlaying()
    }

    private func didReachEnd() {
        guard !isLive else { return }
        ended = true
        saveProgress(force: true)
        if AppSettings.shared.values.autoplayNext, nextEpisode != nil {
            playNextEpisode()
        }
    }

    private func tick() async {
        saveProgress(force: false)
        if showStats { refreshStats() }
        if let hash = resolvedTorrentHash, isBuffering || showStats {
            torrentStatus = try? await TorrentEngine.shared.status(hash)
            if let t = torrentStatus, isBuffering, !hasStarted {
                statusText = "Buffering · \(t.activePeers) peers · \(t.speedText)"
            }
        }
        if isLive, let p = currentProgramme, p.end < Date(), let id = request.channelID {
            await refreshProgramme(id)
        }
    }

    private func saveProgress(force: Bool) {
        guard hasStarted, !isLive, duration > 0 else { return }
        guard force || abs(position - lastSavedPosition) >= 10 else { return }
        lastSavedPosition = position
        LibraryStore.shared.updateProgress(item: request.item, episode: request.episode, position: position, duration: duration)
    }

    private func scrobble(_ action: TraktService.ScrobbleAction) {
        guard !isLive, request.item.type == .movie || request.item.type == .series else { return }
        let item = request.item, ep = request.episode
        let progress = duration > 0 ? position / duration : 0
        Task { await TraktService.shared.scrobble(action, item: item, episode: ep, progress: progress) }
    }

    private func refreshStats() {
        func s(_ k: String) -> String? { player.string(k) }
        var rows: [(String, String)] = []
        if let w = player.int("video-params/w"), let h = player.int("video-params/h") { rows.append(("Resolution", "\(w)×\(h)")) }
        if let c = s("video-codec") { rows.append(("Video", c)) }
        if let hw = s("hwdec-current") { rows.append(("Decoder", hw == "no" ? "software" : hw)) }
        if let fps = player.double("estimated-vf-fps") { rows.append(("FPS", String(format: "%.2f", fps))) }
        if let br = player.double("video-bitrate") { rows.append(("Video bitrate", "\(Int(br / 1000)) kbps")) }
        if let gamma = s("video-params/gamma"), let prim = s("video-params/primaries") { rows.append(("Color", "\(prim) / \(gamma)")) }
        if let a = s("audio-codec-name") { rows.append(("Audio", a + (s("audio-params/channels").map { " · \($0)" } ?? ""))) }
        if let d = player.int("frame-drop-count") { rows.append(("Dropped frames", "\(d)")) }
        if let c = player.double("demuxer-cache-duration") { rows.append(("Buffer", String(format: "%.1fs", c))) }
        if let t = torrentStatus { rows.append(("Torrent", "\(t.activePeers)/\(t.totalPeers) peers · \(t.speedText)")) }
        stats = rows
    }

    // MARK: System integration

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.removeTarget(nil)
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePause(); return .success }
        center.playCommand.addTarget { [weak self] _ in self?.player.setFlag("pause", false); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.player.setFlag("pause", true); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
        ]
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if !isLive, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
