import Foundation
import Observation

/// One live channel in the multiview grid, with its own mpv instance.
@MainActor
@Observable
final class MultiviewTile: Identifiable, MPVPlayerDelegate {
    let id = UUID()
    private(set) var channel: XCChannel
    let player: MPVPlayer
    private(set) var isBuffering = true
    private(set) var hasStarted = false
    private(set) var errorText: String?
    private(set) var isMuted = true

    init(channel: XCChannel, compact: Bool) {
        self.channel = channel
        let s = AppSettings.shared.values
        // Always hardware-decode in multiview: several software decoders would overwhelm the device.
        let hwdec = s.hwdec == .software ? HardwareDecoding.videotoolbox.rawValue : s.hwdec.rawValue
        player = MPVPlayer(options: .init(
            hwdec: hwdec, hdr: s.hdrPassthrough, cacheMB: compact ? 16 : 32, userAgent: s.customUserAgent,
            audioLanguage: s.preferredAudioLanguage, subtitleLanguage: s.preferredSubtitleLanguage,
            autoSubtitles: false, subtitleScale: s.subtitleScale))
        player.delegate = self
        player.set("mute", "yes")
        applyCompact(compact)
    }

    func load() {
        guard let url = DispatcharrStore.shared.client?.liveURL(channel.id) else {
            errorText = "No Dispatcharr server"
            isBuffering = false
            return
        }
        errorText = nil
        isBuffering = true
        hasStarted = false
        player.load(url, title: channel.name, live: true)
    }

    func replace(with channel: XCChannel) {
        self.channel = channel
        load()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        player.set("mute", muted ? "yes" : "no")
    }

    /// With 3–4 tiles, decode with fewer threads and keep less in memory.
    func applyCompact(_ compact: Bool) {
        player.set("vd-lavc-threads", compact ? "2" : "0")
        player.set("demuxer-max-bytes", compact ? "16MiB" : "32MiB")
    }

    func shutdown() {
        player.delegate = nil
        player.command("stop")
        player.shutdown()
    }

    // MARK: MPVPlayerDelegate

    func mpvPropertyChanged(_ name: String, value: Any?) {
        switch name {
        case "time-pos":
            if let v = value as? Double, v > 0.3, !hasStarted {
                hasStarted = true
                isBuffering = false
            }
        case "paused-for-cache":
            isBuffering = (value as? Bool) ?? false
        case "core-idle":
            if (value as? Bool) == false, hasStarted { isBuffering = false }
        default:
            break
        }
    }

    func mpvFileLoaded() { errorText = nil }

    func mpvEndFile(error: String?) {
        if let error {
            errorText = error
            isBuffering = false
        }
    }

    func mpvTracksChanged() {}
}

/// State of the multiview grid: up to `MultiviewLimits.maxTiles` tiles, exactly one with sound.
@MainActor
@Observable
final class MultiviewModel {
    private(set) var tiles: [MultiviewTile] = []
    private(set) var audioTileID: UUID?

    var maxTiles: Int { MultiviewLimits.maxTiles }
    var canAdd: Bool { tiles.count < maxTiles }
    var isCompact: Bool { tiles.count > 2 }
    var channelIDs: Set<Int> { Set(tiles.map(\.channel.id)) }

    init(channels: [XCChannel]) {
        for ch in channels { add(ch) }
    }

    func add(_ channel: XCChannel) {
        guard canAdd, !channelIDs.contains(channel.id) else { return }
        let tile = MultiviewTile(channel: channel, compact: tiles.count + 1 > 2)
        tiles.append(tile)
        tile.load()
        if audioTileID == nil { setAudio(tile.id) } else { tile.setMuted(true) }
        updateCompact()
    }

    func replace(_ id: UUID, with channel: XCChannel) {
        guard !tiles.contains(where: { $0.id != id && $0.channel.id == channel.id }) else { return }
        guard let tile = tiles.first(where: { $0.id == id }) else { return }
        tile.replace(with: channel)
    }

    func remove(_ id: UUID) {
        guard let i = tiles.firstIndex(where: { $0.id == id }) else { return }
        let tile = tiles.remove(at: i)
        tile.shutdown()
        if audioTileID == id {
            audioTileID = nil
            if let first = tiles.first { setAudio(first.id) }
        }
        updateCompact()
    }

    func setAudio(_ id: UUID) {
        guard audioTileID != id || tiles.contains(where: { $0.id == id && $0.isMuted }) else { return }
        audioTileID = id
        for t in tiles { t.setMuted(t.id != id) }
    }

    func shutdown() {
        for t in tiles { t.shutdown() }
        tiles = []
        audioTileID = nil
    }

    private func updateCompact() {
        let compact = isCompact
        for t in tiles { t.applyCompact(compact) }
    }
}
