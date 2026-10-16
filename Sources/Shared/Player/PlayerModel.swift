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
    /// Channels shown in the multiview grid; non-nil while multiview is presented (see `playerPresentation()`).
    var multiview: [XCChannel]?
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

    /// Opens the multiview grid (2–4 live channels; 2 on iPhone). Extra channels are dropped.
    func openMultiview(_ channels: [XCChannel]) {
        var seen = Set<Int>()
        let unique = channels.filter { seen.insert($0.id).inserted }
        let list = Array(unique.prefix(MultiviewLimits.maxTiles))
        if current != nil {
            // Never stack the grid on top of the full player: close it first, then present.
            current = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 650_000_000)
                PlayerCoordinator.shared.multiview = list
            }
        } else {
            multiview = list
        }
    }

    /// Leaves multiview and opens one of its channels in the full player.
    func expandFromMultiview(_ channel: XCChannel, list: [XCChannel]) {
        multiview = nil
        Task { @MainActor in
            // Let the multiview cover finish dismissing before presenting the player cover.
            try? await Task.sleep(nanoseconds: 650_000_000)
            PlayerCoordinator.shared.playChannel(channel, in: list)
        }
    }
}

/// How many tiles multiview supports on this device.
enum MultiviewLimits {
    @MainActor static var maxTiles: Int {
        #if os(tvOS)
        return 4
        #else
        return Platform.isPad ? 4 : 2
        #endif
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

    // Resolved source (for AirPlay / PiP hand-off)
    private(set) var resolvedURL: URL?
    private(set) var resolvedHeaders: [String: String] = [:]

    // Skip intro / credits
    private(set) var skipSegments: [SkipSegment] = []
    @ObservationIgnored private var aniSkipSegments: [SkipSegment] = []
    @ObservationIgnored private var autoSkipped: Set<String> = []
    @ObservationIgnored private var seekChainOrigin: Double?
    @ObservationIgnored private var seekChainTarget: Double = 0
    @ObservationIgnored private var seekChainAt = Date.distantPast
    @ObservationIgnored private var aniSkipTask: Task<Void, Never>?
    @ObservationIgnored private var introDBSegments: [SkipSegment] = []
    @ObservationIgnored private var introDBTask: Task<Void, Never>?
    /// "Mark intro start" was pressed at this position; "Mark intro end" completes the range.
    private(set) var pendingIntroStart: Double?

    // Audio (session values start from PlayerPreferences)
    var volume: Int = 100 { didSet { player.setDouble("volume", Double(max(0, min(200, volume)))) } }
    var nightMode = false { didSet { applyAudioFilters() } }
    var dialogueBoost = false { didSet { applyAudioFilters() } }

    // Live timeshift
    private(set) var timeshiftActive = false
    private(set) var liveRangeStart: Double = 0
    private(set) var liveRangeEnd: Double = 0
    @ObservationIgnored private var usedTimeshift = false

    // Channel number entry / last channel
    private(set) var channelDigits = ""
    private(set) var previousChannelID: Int?
    @ObservationIgnored private var digitTask: Task<Void, Never>?

    // Transient message
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    // Platform helpers (typed in platform-specific extensions)
    @ObservationIgnored var pipStorage: AnyObject?
    @ObservationIgnored var displayCriteriaStorage: AnyObject?
    @ObservationIgnored var displayCriteriaTask: Task<Void, Never>?
    /// Called after pause changes and seeks so Picture in Picture can refresh its state.
    @ObservationIgnored var pipSync: (() -> Void)?

    // UI
    var showStats = false
    private(set) var stats: [(String, String)] = []

    // Recovery after the app was in the background / the stream dropped.
    // iOS suspends the app when nothing plays in the background: mpv's HTTP connections time out,
    // live streams hit EOF, and the embedded TorrServer can die or drop the torrent. Instead of
    // showing "Can't play this", the player reloads the same source (re-resolved: torrent re-added,
    // fresh headers) at the last position, or re-tunes a live channel, behind the buffering UI.
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var isInBackground = false
    @ObservationIgnored private var backgroundedAt: Date?
    /// Set when the app goes to the background; cleared after a stretch of healthy playback.
    /// While set, load failures, errors and stalls are retried instead of shown.
    @ObservationIgnored private var unhealthySinceBackground = false
    @ObservationIgnored private var lastProgressAt = Date()
    @ObservationIgnored private var lastProgressPosition: Double = -1
    @ObservationIgnored private var healthyTicks = 0
    @ObservationIgnored private var recoveryAttempts = 0
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundTask: Task<Void, Never>?
    @ObservationIgnored private var lastFailure: String?
    /// Bumped by every `load`, so a recovery started for an older load never touches a newer one.
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var isResolving = false
    /// What the user asked for (mpv's own `pause` also flips at keep-open EOF and during hand-offs).
    @ObservationIgnored private var userPaused = false
    /// AirPlay / PiP own playback: the main mpv is paused on purpose and must not be "recovered".
    @ObservationIgnored private var handoffActive = false
    @ObservationIgnored private var trailerHandoffActive = false
    /// mpv was paused because another app took the audio session.
    @ObservationIgnored private var pausedByInterruption = false
    private static let maxRecoveryAttempts = 3

    private var resolveTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var lastSavedPosition: Double = 0
    private var resolvedTorrentHash: String?
    private var didScrobbleStart = false
    /// Real throughput of this session, fed back into StartEstimator so source estimates learn this network.
    @ObservationIgnored private var throughput = ThroughputTracker()
    @ObservationIgnored private var throughputContext: (torrent: Bool, seeders: Int?)?
    var onFinished: (() -> Void)?

    var isLive: Bool { request.isLive }
    var title: String { request.displayTitle }
    var subtitle: String? {
        if isLive, let p = currentProgramme { return p.title }
        return request.displaySubtitle
    }
    var remaining: Double { max(0, duration - position) }
    var nextEpisode: EpisodeRef? { request.upcoming.first }
    /// Start of the end credits when known (chapters / AniSkip), used to show the next-episode card early.
    var creditsStart: Double? {
        guard PlayerPreferences.shared.values.nextEpisodeAtCredits, duration > 0 else { return nil }
        return skipSegments.filter { ($0.kind == .credits || $0.kind == .preview) && $0.start > duration * 0.5 }.map(\.start).min()
    }
    var showNextEpisodeCard: Bool {
        guard AppSettings.shared.values.autoplayNext, nextEpisode != nil, duration > 300, remaining > 0 else { return false }
        if let c = creditsStart, position >= c { return true }
        return remaining < 35
    }

    /// The skip button to show right now, if any.
    var activeSkip: SkipSegment? {
        guard PlayerPreferences.shared.values.showSkipButtons, hasStarted, !isLive, !ended else { return nil }
        return skipSegments.first { seg in
            guard seg.contains(position) else { return false }
            switch seg.kind {
            case .intro, .recap:
                return true
            case .credits, .preview:
                // With an episode up next, the next-episode card handles credits.
                if nextEpisode != nil && AppSettings.shared.values.autoplayNext { return false }
                return seg.end < duration - 10
            }
        }
    }

    /// Seeking is allowed for VOD, catch-up, and live channels with a timeshift buffer.
    var canSeek: Bool { !isLive || timeshiftActive }

    /// Where "live" is inside the timeshift buffer (the newest data minus the normal live delay).
    var liveEdge: Double { max(liveRangeStart, liveRangeEnd - Double(AppSettings.shared.values.liveBufferSeconds)) }
    var behindLive: Double { timeshiftActive && liveRangeEnd > 0 ? max(0, liveEdge - position) : 0 }
    var liveWindow: Double { max(0, liveRangeEnd - liveRangeStart) }

    init(request: PlaybackRequest) {
        self.request = request
        let s = AppSettings.shared.values
        player = MPVPlayer(options: .init(
            hwdec: s.hwdec.rawValue, hdr: s.hdrPassthrough, cacheMB: s.demuxerCacheMB, userAgent: s.customUserAgent,
            audioLanguage: s.preferredAudioLanguage, subtitleLanguage: s.preferredSubtitleLanguage,
            autoSubtitles: s.autoSubtitles, subtitleScale: s.subtitleScale))
        player.delegate = self
        let prefs = PlayerPreferences.shared.values
        volume = prefs.volume
        nightMode = prefs.nightMode
        dialogueBoost = prefs.dialogueBoost
        // Apply explicitly too: property observers don't run for assignments made during init.
        player.setDouble("volume", Double(max(0, min(200, prefs.volume))))
        applyAudioFilters()
        applyPreferences()
        configureAudioSession()
        configureRemoteCommands()
    }

    /// Pushes subtitle styling from PlayerPreferences to mpv (on start and whenever it changes).
    func applyPreferences() {
        for (name, value) in PlayerPreferences.shared.values.subtitleProperties { player.set(name, value) }
    }

    private func applyAudioFilters() {
        player.set("af", PlayerPreferences.audioFilter(nightMode: nightMode, dialogueBoost: dialogueBoost))
    }

    static var timeshiftDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mpv-timeshift", isDirectory: true)
    }

    private func timeshiftConfig(for req: PlaybackRequest) -> MPVPlayer.Timeshift? {
        let p = PlayerPreferences.shared.values
        guard req.isLive, p.timeshiftEnabled else { return nil }
        return MPVPlayer.Timeshift(megabytes: p.timeshiftMegabytes, seconds: max(60, p.timeshiftMinutes * 60),
                                   directory: Self.timeshiftDirectory.path)
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
        observeLifecycle()
    }

    func stop() {
        loadGeneration += 1
        #if os(iOS)
        stopPictureInPicture()
        #endif
        #if os(tvOS)
        resetDisplayCriteria()
        #endif
        saveProgress(force: true)
        if hasStarted { scrobble(.stop) }
        flushThroughput()
        resolveTask?.cancel()
        tickTask?.cancel()
        digitTask?.cancel()
        aniSkipTask?.cancel()
        introDBTask?.cancel()
        toastTask?.cancel()
        recoveryTask?.cancel()
        recoveryTask = nil
        foregroundTask?.cancel()
        for o in lifecycleObservers { NotificationCenter.default.removeObserver(o) }
        lifecycleObservers = []
        pipSync = nil
        player.command("stop")
        player.shutdown()
        if let hash = resolvedTorrentHash { Task { await TorrentEngine.shared.drop(hash) } }
        if usedTimeshift {
            // mpv unlinks its cache file itself; this removes anything left behind after a crash or kill.
            try? FileManager.default.removeItem(at: Self.timeshiftDirectory)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func load(_ req: PlaybackRequest) {
        request = req
        resetState()
        loadGeneration += 1
        let generation = loadGeneration
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryAttempts = 0
        lastFailure = nil
        lastProgressAt = Date()
        lastProgressPosition = -1
        // New content always plays: mpv keeps `pause` across loadfile (and keep-open pauses at EOF),
        // which would otherwise start the next channel/episode paused behind a "playing" UI.
        userPaused = false
        pausedByInterruption = false
        player.setFlag("pause", false)
        resolveTask?.cancel()
        isResolving = true
        resolveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (url, headers) = try await self.resolve(req.source)
                guard !Task.isCancelled, generation == self.loadGeneration else { return }
                let start = req.startPosition ?? self.resumePosition(for: req)
                self.resolvedURL = url
                self.resolvedHeaders = headers
                let timeshift = self.timeshiftConfig(for: req)
                self.timeshiftActive = timeshift != nil
                if timeshift != nil { self.usedTimeshift = true }
                self.lastProgressAt = Date()
                self.player.load(url, start: start, headers: headers, title: req.displayTitle, live: req.isLive, timeshift: timeshift)
                self.isResolving = false
                self.updateNowPlaying()
                await self.loadAddonSubtitles(for: req)
            } catch is CancellationError {
                if generation == self.loadGeneration { self.isResolving = false }
            } catch {
                guard !Task.isCancelled, generation == self.loadGeneration else { return }
                self.isResolving = false
                self.lastFailure = error.localizedDescription
                if self.unhealthySinceBackground && !Task.isCancelled {
                    // E.g. the app was suspended while the torrent was still being fetched.
                    self.scheduleRecovery(reason: error.localizedDescription)
                } else {
                    self.errorText = error.localizedDescription
                    self.isBuffering = false
                }
            }
        }
        if req.isLive, let id = req.channelID { Task { await refreshProgramme(id) } }
    }

    private func flushThroughput() {
        if let ctx = throughputContext, throughput.samples >= 8 {
            StartEstimator.shared.record(peakSpeed: throughput.peak, seeders: ctx.seeders, torrent: ctx.torrent)
        }
        throughput = ThroughputTracker()
        throughputContext = nil
    }

    private func sampleThroughput() {
        guard !isLive else { return }
        if let t = torrentStatus, resolvedTorrentHash != nil {
            throughputContext = (true, request.source.seeders ?? t.seeders)
            throughput.add(t.downloadSpeed)
        } else if case .direct = request.source.kind, !isPaused, let speed = player.double("cache-speed"),
                  throughput.samples < 40 {
            // Only the first seconds count: once mpv's cache is full it stops reading at full speed.
            throughputContext = (false, nil)
            throughput.add(speed)
        }
    }

    private func resetState() {
        flushThroughput()
        position = 0; duration = 0; cachedUntil = 0; isPaused = false; isBuffering = true
        hasStarted = false; statusText = nil; errorText = nil; ended = false; torrentStatus = nil
        audioTracks = []; subtitleTracks = []; videoTracks = []; chapters = []
        addonSubtitles = []; loadedAddonSubtitleIDs = []; lastSavedPosition = 0; didScrobbleStart = false
        currentProgramme = nil; nextProgramme = nil
        resolvedURL = nil; resolvedHeaders = [:]
        skipSegments = []; aniSkipSegments = []; autoSkipped = []; seekChainOrigin = nil
        aniSkipTask?.cancel()
        introDBSegments = []; introDBTask?.cancel(); pendingIntroStart = nil
        timeshiftActive = false; liveRangeStart = 0; liveRangeEnd = 0
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
            // The recording endpoint needs a valid JWT and mpv can't renew it, so make sure the
            // cached access token still works first (`me()` renews/re-logs in on a 401) — it may
            // have expired while the app was in the background.
            _ = try? await rest.me()
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
        let generation = loadGeneration
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
        guard !Task.isCancelled, generation == loadGeneration else { return }
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
        setPausedByUser(!isPaused)
    }

    /// Pause/play on the user's behalf (controls, remote commands, PiP buttons).
    func setPausedByUser(_ paused: Bool) {
        guard !trailerHandoffActive else { return }
        userPaused = paused
        pausedByInterruption = false
        // Paused time is not a stall.
        lastProgressAt = Date()
        // The session may have been taken by another app while we were paused.
        if !paused { try? AVAudioSession.sharedInstance().setActive(true) }
        player.setFlag("pause", paused)
    }

    func seek(to seconds: Double) {
        guard canSeek else { return }
        noteUserSeek(from: position, to: seconds)
        performSeek(to: seconds)
    }

    func seek(by delta: Double) {
        guard canSeek else { return }
        if isLive { refreshLiveWindow() }
        seek(to: position + delta)
    }

    /// Seeks without treating it as a user gesture (no intro learning).
    func performSeek(to seconds: Double) {
        let target: Double
        if isLive {
            guard timeshiftActive, liveRangeEnd > liveRangeStart else { return }
            target = max(liveRangeStart, min(seconds, liveEdge))
        } else {
            target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        }
        position = target
        player.command("seek", String(format: "%.3f", target), isLive ? "absolute" : "absolute+exact")
        updateNowPlaying()
        pipSync?()
    }

    /// Jumps back to the live edge of the timeshift buffer.
    func goLive() {
        guard timeshiftActive else { return }
        refreshLiveWindow()
        performSeek(to: liveEdge)
        if isPaused { setPausedByUser(false) }
    }

    func refreshLiveWindow() {
        guard timeshiftActive, let state = player.node("demuxer-cache-state") as? [String: Any] else { return }
        let ranges = (state["seekable-ranges"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let starts = ranges.compactMap { $0["start"] as? Double }
        let ends = ranges.compactMap { $0["end"] as? Double }
        if let s = starts.min(), let e = ends.max(), e > s {
            liveRangeStart = s
            liveRangeEnd = e
        } else if let e = state["cache-end"] as? Double {
            liveRangeEnd = e
            if liveRangeStart <= 0 || liveRangeStart > position { liveRangeStart = min(position, e) }
        }
    }

    // MARK: Skip intro / credits

    func skip(_ segment: SkipSegment) {
        autoSkipped.insert(segment.id)
        seekChainOrigin = nil
        performSeek(to: segment.end)
    }

    private var introKey: String? {
        guard let ep = request.episode, !isLive else { return nil }
        return IntroMemory.key(item: request.item, season: ep.season)
    }

    func rebuildSkipSegments() {
        // Priority: manual (per series) > TheIntroDB > chapter names > AniSkip > learned.
        var segs = introDBSegments
        let others = ChapterSkipDetector.segments(from: chapters, duration: duration) + aniSkipSegments
        for a in others where !segs.contains(where: { $0.kind == a.kind && ($0.overlaps(a) || abs($0.start - a.start) < 15) }) {
            segs.append(a)
        }
        if let manual = manualMarkers {
            if let start = manual.introStart, let end = manual.introEnd, end > start, duration <= 0 || end < duration {
                segs.removeAll { $0.kind == .intro }
                segs.append(SkipSegment(kind: .intro, start: start, end: end, source: .manual))
            }
            if let fromEnd = manual.creditsFromEnd, duration > fromEnd + 60 {
                segs.removeAll { $0.kind == .credits }
                segs.append(SkipSegment(kind: .credits, start: duration - fromEnd, end: duration, source: .manual))
            }
        }
        if !segs.contains(where: { $0.kind == .intro }), let key = introKey, let e = IntroMemory.shared.entry(key),
           duration <= 0 || e.end < duration * 0.5 {
            // Learned intros drift a little between episodes: offer the button from 10 s early.
            segs.append(SkipSegment(kind: .intro, start: max(0, e.start - 10), end: e.end, source: .learned))
        }
        skipSegments = segs.sorted { $0.start < $1.start }
    }

    // MARK: TheIntroDB

    private func loadIntroDB() {
        guard PlayerPreferences.shared.values.useIntroDB, !isLive, request.catchup == nil, duration > 0,
              request.item.type == .movie || request.item.type == .series else { return }
        let item = request.item
        let ep = request.episode
        let length = duration
        let tmdb = MetadataService.shared.tmdb
        introDBTask?.cancel()
        introDBTask = Task { [weak self] in
            var tmdbID = item.tmdbID
            if tmdbID == nil, let imdb = item.imdbID, tmdb.isConfigured {
                let found = try? await tmdb.find(imdbID: imdb)
                tmdbID = found?.tmdbID
            }
            guard let id = tmdbID, id > 0 else { return }
            let segs = await TheIntroDBClient.shared.segments(tmdbID: id, season: ep?.season, episode: ep?.episode, duration: length)
            guard let self, !Task.isCancelled, self.request.episode == ep, self.request.item.id == item.id, !segs.isEmpty else { return }
            self.introDBSegments = segs
            self.rebuildSkipSegments()
        }
    }

    // MARK: Manual markers (per series)

    /// Series whose markers the user can set (episodes only).
    var markerSeriesID: String? {
        guard request.episode != nil, !isLive, request.catchup == nil else { return nil }
        return request.item.id
    }

    var manualMarkers: IntroMemory.Manual? { markerSeriesID.flatMap { IntroMemory.shared.manual($0) } }

    func markIntroStart() {
        guard markerSeriesID != nil, hasStarted else { return }
        pendingIntroStart = position
        showToast("Intro start set at \(position.clockText). Now mark its end.")
    }

    func markIntroEnd() {
        guard let id = markerSeriesID, hasStarted else { return }
        let start = pendingIntroStart ?? 0
        guard position > start + 5 else {
            showToast("Play to the end of the intro first")
            return
        }
        IntroMemory.shared.setManualIntro(id, start: start, end: position)
        pendingIntroStart = nil
        rebuildSkipSegments()
        showToast("Intro marked \(start.clockText)–\(position.clockText) for this series")
    }

    func markCreditsStart() {
        guard let id = markerSeriesID, hasStarted, duration > 0, position < duration - 5 else { return }
        IntroMemory.shared.setManualCredits(id, fromEnd: duration - position)
        rebuildSkipSegments()
        showToast("Credits marked at \(position.clockText) for this series")
    }

    func clearManualMarkers() {
        guard let id = markerSeriesID else { return }
        IntroMemory.shared.forgetManual(id)
        pendingIntroStart = nil
        rebuildSkipSegments()
        showToast("Markers cleared for this series")
    }

    private func loadAniSkip() {
        guard PlayerPreferences.shared.values.useAniSkip, let ep = request.episode, duration > 0 else { return }
        let item = request.item
        let length = duration
        aniSkipTask?.cancel()
        aniSkipTask = Task { [weak self] in
            let segs = await AniSkipClient.shared.segments(item: item, episode: ep, duration: length)
            guard let self, !Task.isCancelled, self.request.episode == ep, !segs.isEmpty else { return }
            self.aniSkipSegments = segs
            self.rebuildSkipSegments()
        }
    }

    private func autoSkipIfNeeded(at t: Double) {
        guard PlayerPreferences.shared.values.autoSkipIntro, hasStarted, !isLive else { return }
        guard let seg = skipSegments.first(where: { ($0.kind == .intro || $0.kind == .recap) && $0.contains(t) && !autoSkipped.contains($0.id) })
        else { return }
        // Learned ranges start 10 s early for the button; only auto-skip once we're really in the intro.
        if seg.source == .learned && t < seg.start + 8 { return }
        autoSkipped.insert(seg.id)
        performSeek(to: seg.end)
        showToast(seg.kind == .recap ? "Skipped recap" : "Skipped intro")
    }

    /// Groups quick successive forward seeks into one gesture; committed from `tick` once idle.
    private func noteUserSeek(from: Double, to: Double) {
        guard introKey != nil, duration > 0 else { return }
        let now = Date()
        if seekChainOrigin != nil, now.timeIntervalSince(seekChainAt) < 3 {
            seekChainTarget = to
        } else {
            seekChainOrigin = from
            seekChainTarget = to
        }
        seekChainAt = now
    }

    private func commitSeekChain() {
        guard let origin = seekChainOrigin, Date().timeIntervalSince(seekChainAt) >= 3 else { return }
        seekChainOrigin = nil
        guard PlayerPreferences.shared.values.learnIntros, let key = introKey, duration > 0 else { return }
        let delta = seekChainTarget - origin
        guard origin < duration * 0.15, delta >= 30, delta <= 180 else { return }
        if skipSegments.contains(where: { $0.kind == .intro && $0.source != .learned }) { return }
        IntroMemory.shared.record(key, start: origin, end: seekChainTarget)
    }

    // MARK: Toast

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: AirPlay / PiP hand-off

    /// AVPlayer can play the current source (used for PiP hand-off).
    var isAVPlayerCompatible: Bool { resolvedURL.map { AVPlaybackCompatibility.isAVPlayerCompatible($0) } ?? false }
    /// An AirPlay receiver can fetch the current source itself.
    var isAirPlayCompatible: Bool { resolvedURL.map { AVPlaybackCompatibility.isAirPlayCompatible($0) } ?? false }

    func pauseForHandoff(forTrailer: Bool = false) {
        trailerHandoffActive = forTrailer
        handoffActive = true
        recoveryTask?.cancel()
        recoveryTask = nil
        player.setFlag("pause", true)
    }

    func resumeAfterHandoff(at seconds: Double?, play: Bool) {
        trailerHandoffActive = false
        handoffActive = false
        if let s = seconds, s.isFinite, s > 1, !isLive { performSeek(to: s) }
        setPausedByUser(!play)
    }

    // MARK: Volume

    func changeVolume(by delta: Int) {
        volume = max(0, min(200, volume + delta))
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
        if hasStarted {
            // Pick up where playback stopped (re-resolving the source), not from the original start.
            recoveryTask?.cancel()
            recoveryTask = nil
            recoveryAttempts = 0
            scheduleRecovery(reason: "retry", delay: 0)
        } else {
            load(request)
        }
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
        if let current = request.channelID, current != channel.id { previousChannelID = current }
        var req = request
        req.item = channel.mediaItem(serverID: server.id)
        req.channelID = channel.id
        req.catchup = nil
        if !req.channelList.contains(where: { $0.id == channel.id }) {
            req.channelList = store.channels.contains(where: { $0.id == channel.id }) ? store.channels : req.channelList + [channel]
        }
        req.source = PlaybackSource(id: "live:\(channel.id)", kind: .direct(url, headers: [:]), title: channel.name, provider: server.name)
        LibraryStore.shared.recordChannel(channel.id)
        load(req)
    }

    var currentChannel: XCChannel? { request.channelID.flatMap { id in request.channelList.first { $0.id == id } ?? DispatcharrStore.shared.channel(id) } }

    // MARK: Number entry / last channel

    func channel(number: Int) -> XCChannel? {
        request.channelList.first { $0.number == number } ?? DispatcharrStore.shared.channels.first { $0.number == number }
    }

    /// The channel the digits typed so far would tune to.
    var digitPreview: XCChannel? { Int(channelDigits).flatMap { channel(number: $0) } }

    var previousChannel: XCChannel? {
        previousChannelID.flatMap { id in request.channelList.first { $0.id == id } ?? DispatcharrStore.shared.channel(id) }
    }

    /// Adds a digit; tunes 1.5 s after the last one.
    func enterDigit(_ digit: Int) {
        guard request.channelID != nil, (0...9).contains(digit) else { return }
        if channelDigits.count >= 5 { channelDigits = "" }
        channelDigits += String(digit)
        digitTask?.cancel()
        digitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.commitDigits()
        }
    }

    func deleteDigit() {
        guard !channelDigits.isEmpty else { return }
        channelDigits.removeLast()
        if channelDigits.isEmpty { digitTask?.cancel() }
    }

    func commitDigits() {
        digitTask?.cancel()
        let digits = channelDigits
        channelDigits = ""
        guard let n = Int(digits) else { return }
        if let ch = channel(number: n) {
            if ch.id != request.channelID { switchChannel(ch) }
        } else {
            showToast("No channel \(n)")
        }
    }

    func cancelDigits() {
        digitTask?.cancel()
        channelDigits = ""
    }

    func toggleLastChannel() {
        guard let prev = previousChannel else { showToast("No previous channel"); return }
        switchChannel(prev)
    }

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
            if let v = value as? Double {
                position = v
                if abs(v - lastProgressPosition) > 0.05 {
                    lastProgressPosition = v
                    lastProgressAt = Date()
                }
                if v > 0.3 && !hasStarted { didStart() }
                if !skipSegments.isEmpty { autoSkipIfNeeded(at: v) }
            }
        case "duration":
            let old = duration
            duration = (value as? Double) ?? 0
            if old <= 0 && duration > 0 && !isLive {
                rebuildSkipSegments()
                if aniSkipSegments.isEmpty { loadAniSkip() }
                if introDBSegments.isEmpty { loadIntroDB() }
            }
        case "pause":
            isPaused = (value as? Bool) ?? false
            updateNowPlaying()
            pipSync?()
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
            if (value as? Bool) == true { handleEndOfStream() }
        case "video-params/sig-peak":
            isHDR = ((value as? Double) ?? 1) > 1
        case "speed":
            speed = (value as? Double) ?? 1
        case "chapter-list/count":
            chapters = player.chapters()
            rebuildSkipSegments()
        default:
            break
        }
    }

    func mpvFileLoaded() {
        statusText = nil
        errorText = nil
        // A recovery reload that keeps the user's pause never reports "playing": drop the spinner here.
        if hasStarted && (userPaused || pausedByInterruption) { isBuffering = false }
        duration = player.double("duration") ?? 0
        chapters = player.chapters()
        if fit != .fit { setFit(fit) }
        rebuildSkipSegments()
        loadAniSkip()
        loadIntroDB()
        if timeshiftActive { refreshLiveWindow() }
        #if os(tvOS)
        scheduleDisplayCriteriaMatch()
        #endif
    }

    func mpvEndFile(error: String?) {
        // The file being replaced by a recovery reload: its failure is why we're reloading.
        guard recoveryTask == nil else { return }
        if let error {
            lastFailure = isLive ? "The channel stopped responding (\(error))." : "Playback failed: \(error)"
            // Network errors during/right after a background period, or after playback had started,
            // are retried (with backoff) before anything is shown.
            if (unhealthySinceBackground || hasStarted) && !handoffActive {
                scheduleRecovery(reason: error)
                return
            }
            errorText = lastFailure
            isBuffering = false
        } else if isLive && !handoffActive {
            // A live stream doesn't end: it was cut. Re-tune.
            scheduleRecovery(reason: "stream ended")
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

    /// mpv (keep-open) reports EOF both at the real end and when the connection died mid-file
    /// (the demuxer just runs out of data). Only the former is "ended".
    private func handleEndOfStream() {
        guard recoveryTask == nil, !handoffActive else { return }
        if isLive {
            // Live streams don't end: the connection was cut (typically after a suspension). Re-tune.
            scheduleRecovery(reason: "stream ended")
            return
        }
        let reachedEnd = duration <= 0 ? hasStarted : position >= duration - 20
        if reachedEnd {
            didReachEnd()
        } else {
            // EOF far from the end (or before anything played): the stream dropped.
            scheduleRecovery(reason: "the stream was interrupted")
        }
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
        trackHealth()
        commitSeekChain()
        if timeshiftActive { refreshLiveWindow() }
        if showStats { refreshStats() }
        if let hash = resolvedTorrentHash {
            // Polled every second while a torrent plays: drives the top-bar chip and the stats overlay.
            if let status = try? await TorrentEngine.shared.status(hash) { torrentStatus = status }
            if let t = torrentStatus, isBuffering, !hasStarted {
                statusText = "Buffering · \(t.activePeers) peers · \(t.speedText)"
            }
        }
        sampleThroughput()
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
        if let t = torrentStatus {
            rows.append(("Torrent", t.statText.isEmpty ? "Active" : t.statText))
            rows.append(("Peers", "\(t.activePeers) active / \(t.totalPeers) total · \(t.seeders) seeders"))
            rows.append(("Download", t.speedText))
            rows.append(("Upload", "\(Int64(t.uploadSpeed).byteText)/s"))
            if t.preloadSize > 0 { rows.append(("Preload", "\(t.preloaded.byteText) / \(t.preloadSize.byteText)")) }
            if t.size > 0 { rows.append(("Downloaded", "\(t.loaded.byteText) / \(t.size.byteText)")) }
        }
        if timeshiftActive {
            rows.append(("Timeshift", "\(Int(liveWindow / 60)) min buffered · \(Int(behindLive))s behind"))
        }
        if volume != 100 || nightMode || dialogueBoost {
            rows.append(("Audio FX", "vol \(volume)%" + (nightMode ? " · night" : "") + (dialogueBoost ? " · dialogue" : "")))
        }
        stats = rows
    }

    /// Torrent fill shown in the top-bar chip: preload buffer while it fills, else overall progress.
    var torrentBufferPercent: Int? {
        guard let t = torrentStatus else { return nil }
        if t.preloadSize > 0 { return min(100, Int(Double(t.preloaded) * 100 / Double(t.preloadSize))) }
        if t.size > 0 { return min(100, Int(Double(t.loaded) * 100 / Double(t.size))) }
        return nil
    }

    // MARK: Background / foreground recovery

    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        // All three are delivered on the main queue (`queue: .main`).
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { () -> Void in self?.appDidEnterBackground() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { () -> Void in self?.appDidBecomeActive() }
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                               queue: .main) { [weak self] note in
                let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let began = rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
                let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                MainActor.assumeIsolated { () -> Void in self?.audioInterruption(began: began, shouldResume: shouldResume) }
            },
        ]
    }

    private var pipBusy: Bool {
        #if os(iOS)
        if let pip = pipStorage as? PiPController { return pip.isActive || pip.isStarting }
        #endif
        return false
    }

    private func appDidEnterBackground() {
        isInBackground = true
        backgroundedAt = Date()
        unhealthySinceBackground = true
        healthyTicks = 0
        foregroundTask?.cancel()
        saveProgress(force: true)
    }

    /// Also fires after Control Center / notification banners; only acts after a real background trip.
    private func appDidBecomeActive() {
        guard isInBackground else { return }
        isInBackground = false
        let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
        backgroundedAt = nil
        // Time spent suspended is not a stall; measure from now.
        lastProgressAt = Date()
        reactivateAudio()
        foregroundTask?.cancel()
        foregroundTask = Task { [weak self] in
            // Give mpv a moment to bring video back and report what state it is in.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.foregroundCheck(away: away)
        }
    }

    private func foregroundCheck(away: TimeInterval) async {
        guard recoveryTask == nil, !handoffActive, !pipBusy, !isResolving, !ended else { return }
        let eof = player.flag("eof-reached")
        let nearEnd = duration > 0 && position >= duration - 20
        if errorText != nil || player.flag("idle-active") || (eof && (isLive || !nearEnd)) {
            // Failed while away (error shown, file unloaded, or the stream ran dry): reload now.
            recoveryAttempts = 0
            scheduleRecovery(reason: lastFailure ?? "returned from the background", delay: 0)
            return
        }
        guard case .torrent(let source) = request.source.kind, away > 3 else { return }
        // The engine may have died (or dropped the torrent) while the app was suspended: revive it and
        // re-add the torrent with its trackers before mpv reconnects to /stream by hash alone.
        let generation = loadGeneration
        let health = await TorrentEngine.shared.ensureRunning()
        guard generation == loadGeneration, recoveryTask == nil, !handoffActive else { return }
        if health.restarted || !health.reachable {
            scheduleRecovery(reason: TorrentEngine.shared.lastError ?? "the torrent engine restarted", delay: 0)
        } else {
            _ = try? await TorrentEngine.shared.add(source)
        }
    }

    private func reactivateAudio() {
        // Only when we mean to play: activating would stop another app's music under a paused player.
        guard !userPaused, !handoffActive else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if pausedByInterruption {
            // iOS often never sends "interruption ended" (the other app didn't deactivate its session).
            pausedByInterruption = false
            player.command("ao-reload")
            if !userPaused && !handoffActive { player.setFlag("pause", false) }
        }
    }

    private func audioInterruption(began: Bool, shouldResume: Bool) {
        if began {
            // Another app took the audio: pause like any media app (and remember it wasn't the user).
            if !userPaused && !isPaused && !handoffActive {
                pausedByInterruption = true
                player.setFlag("pause", true)
            }
        } else {
            try? AVAudioSession.sharedInstance().setActive(true)
            // The audio unit may not come back by itself after an interruption.
            player.command("ao-reload")
            if pausedByInterruption && !userPaused && !handoffActive && (shouldResume || !isInBackground) {
                player.setFlag("pause", false)
            }
            pausedByInterruption = false
            lastProgressAt = Date()
        }
    }

    /// Called every second: watches for a stall after a background trip and resets the retry budget
    /// once playback has been healthy for a while.
    private func trackHealth() {
        let progressing = Date().timeIntervalSince(lastProgressAt) < 2.5
        if progressing && !isPaused {
            healthyTicks += 1
            if healthyTicks >= 20 {
                recoveryAttempts = 0
                lastFailure = nil
                if !isInBackground { unhealthySinceBackground = false }
            }
        } else if !isPaused {
            healthyTicks = 0
        }

        // Stall watchdog: only after returning from the background, only while the user wants it to play.
        guard unhealthySinceBackground, !isInBackground, recoveryTask == nil, !isResolving, !handoffActive, !pipBusy,
              !userPaused, !pausedByInterruption, !ended, errorText == nil, resolvedURL != nil,
              hasStarted || isLive else { return }
        let limit: TimeInterval = isLive ? 15 : (resolvedTorrentHash != nil ? 30 : 20)
        if Date().timeIntervalSince(lastProgressAt) > limit {
            scheduleRecovery(reason: "playback stalled")
        }
    }

    /// Reloads the current source behind the buffering UI: VOD/torrent/catch-up at the last position
    /// (re-resolving it: torrent re-added, fresh headers), live channels re-tuned at the live edge
    /// (a timeshift buffer starts over). Keeps the user's pause state. After
    /// `maxRecoveryAttempts` failures in a row the error is shown.
    private func scheduleRecovery(reason: String, delay: Double? = nil) {
        guard recoveryTask == nil, !handoffActive else { return }
        recoveryAttempts += 1
        guard recoveryAttempts <= Self.maxRecoveryAttempts else {
            isBuffering = false
            statusText = nil
            errorText = lastFailure ?? (isLive ? "The channel stopped responding." : "Playback stopped: \(reason)")
            return
        }
        let attempt = recoveryAttempts
        let wait = delay ?? [0.5, 2.0, 5.0][min(attempt - 1, 2)]
        let req = request
        let generation = loadGeneration
        let resumeAt: Double? = req.isLive ? nil : (hasStarted ? max(0, position - 2) : (req.startPosition ?? resumePosition(for: req)))
        let stayPaused = userPaused
        errorText = nil
        ended = false
        isBuffering = true
        statusText = attempt == 1 ? "Reconnecting…" : "Reconnecting… (try \(attempt) of \(Self.maxRecoveryAttempts))"
        recoveryTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
            // Pooled connections may be dead after a suspension.
            await HTTPClient.shared.flushConnections()
            var source = req.source
            if req.isLive, let id = req.channelID, let url = DispatcharrStore.shared.client?.liveURL(id) {
                source.kind = .direct(url, headers: [:])
            }
            do {
                let (url, headers) = try await self.resolve(source)
                guard !Task.isCancelled, generation == self.loadGeneration else { return }
                self.resolvedURL = url
                self.resolvedHeaders = headers
                let timeshift = self.timeshiftConfig(for: req)
                self.timeshiftActive = timeshift != nil
                self.liveRangeStart = 0
                self.liveRangeEnd = 0
                if timeshift != nil { self.usedTimeshift = true }
                self.lastProgressAt = Date()
                self.lastProgressPosition = -1
                self.healthyTicks = 0
                self.recoveryTask = nil
                // mpv keeps `pause` across loadfile; keep-open set it at EOF. Restore the user's choice.
                self.player.setFlag("pause", stayPaused)
                self.player.load(url, start: resumeAt, headers: headers, title: req.displayTitle, live: req.isLive, timeshift: timeshift)
                self.updateNowPlaying()
            } catch {
                guard !Task.isCancelled, generation == self.loadGeneration else { return }
                self.lastFailure = error.localizedDescription
                self.recoveryTask = nil
                self.scheduleRecovery(reason: error.localizedDescription)
            }
        }
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
        center.playCommand.addTarget { [weak self] _ in self?.setPausedByUser(false); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.setPausedByUser(true); return .success }
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
