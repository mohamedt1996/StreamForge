import Foundation
import Observation
#if canImport(TorrServerKit) && os(iOS)
import TorrServerKit
#endif

struct TorrentFile: Decodable, Hashable, Identifiable {
    var id: Int
    var path: String
    var length: Int64

    enum CodingKeys: String, CodingKey { case id, path, length }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.id) ?? 0
        path = c.flexString(.path) ?? ""
        length = Int64(c.flexDouble(.length) ?? 0)
    }

    var name: String { (path as NSString).lastPathComponent }
    var isVideo: Bool {
        ["mkv", "mp4", "avi", "m4v", "mov", "ts", "m2ts", "webm", "wmv", "flv", "mpg", "mpeg", "vob", "iso"]
            .contains((path as NSString).pathExtension.lowercased())
    }
    var isSubtitle: Bool { ["srt", "ass", "ssa", "vtt", "sub"].contains((path as NSString).pathExtension.lowercased()) }
}

struct TorrentStatus: Decodable, Hashable, Identifiable {
    var id: String { hash }
    var hash: String
    var title: String
    var poster: URL?
    var stat: Int
    var statText: String
    var loaded: Int64
    var size: Int64
    var preloaded: Int64
    var preloadSize: Int64
    var downloadSpeed: Double
    var uploadSpeed: Double
    var activePeers: Int
    var totalPeers: Int
    var seeders: Int
    var files: [TorrentFile]

    enum CodingKeys: String, CodingKey {
        case hash, title, name, poster, stat, stat_string, loaded_size, torrent_size, preloaded_bytes, preload_size
        case download_speed, upload_speed, active_peers, total_peers, connected_seeders, file_stats
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hash = c.flexString(.hash) ?? ""
        title = c.flexString(.title) ?? c.flexString(.name) ?? hash
        poster = c.flexURL(.poster)
        stat = c.flexInt(.stat) ?? 0
        statText = c.flexString(.stat_string) ?? ""
        loaded = Int64(c.flexDouble(.loaded_size) ?? 0)
        size = Int64(c.flexDouble(.torrent_size) ?? 0)
        preloaded = Int64(c.flexDouble(.preloaded_bytes) ?? 0)
        preloadSize = Int64(c.flexDouble(.preload_size) ?? 0)
        downloadSpeed = c.flexDouble(.download_speed) ?? 0
        uploadSpeed = c.flexDouble(.upload_speed) ?? 0
        activePeers = c.flexInt(.active_peers) ?? 0
        totalPeers = c.flexInt(.total_peers) ?? 0
        seeders = c.flexInt(.connected_seeders) ?? 0
        files = (try? c.decode(LossyArray<TorrentFile>.self, forKey: .file_stats))?.elements ?? []
    }

    var hasMetadata: Bool { !files.isEmpty }
    var speedText: String { "\(Int64(downloadSpeed).byteText)/s" }
    var videoFiles: [TorrentFile] { files.filter(\.isVideo).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending } }
}

/// What a Stremio stream or a pasted magnet asks the engine to play.
struct TorrentSource: Hashable, Codable {
    var infoHash: String
    var fileIdx: Int?
    var filename: String?
    var trackers: [String] = []
    var title: String?
    var poster: URL?
    /// Season/episode hint for picking a file in season packs.
    var season: Int?
    var episode: Int?
    /// Which addon returned this stream and which MediaItem it plays (shown in Activity).
    var addonName: String? = nil
    var itemID: String? = nil

    var magnet: String {
        var s = "magnet:?xt=urn:btih:\(infoHash)"
        if let title, let t = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { s += "&dn=\(t)" }
        for tr in trackers {
            if let enc = tr.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { s += "&tr=\(enc)" }
        }
        return s
    }

    static func parse(magnet: String) -> TorrentSource? {
        guard let comps = URLComponents(string: magnet), comps.scheme == "magnet" else { return nil }
        let items = comps.queryItems ?? []
        guard let xt = items.first(where: { $0.name == "xt" })?.value,
              let hash = xt.components(separatedBy: ":").last, !hash.isEmpty else { return nil }
        return TorrentSource(infoHash: hash.lowercased(), trackers: items.filter { $0.name == "tr" }.compactMap(\.value),
                             title: items.first { $0.name == "dn" }?.value)
    }
}

/// What started a torrent: recorded when the player resolves it, shown in the Activity screen.
struct TorrentOrigin: Codable, Hashable {
    var hash: String
    var title: String?
    var poster: URL?
    var season: Int?
    var episode: Int?
    var addonName: String?
    var itemID: String?
    var fileName: String?
    var addedAt: Date
    var kept: Bool = false

    var episodeCode: String? {
        guard let season, let episode else { return nil }
        return String(format: "S%02dE%02d", season, episode)
    }
}

/// Talks to TorrServer — either the copy embedded in the app or one on the user's network.
/// Both expose the same HTTP API, so playback code doesn't care which is active.
@MainActor
@Observable
final class TorrentEngine {
    static let shared = TorrentEngine()

    static let embeddedPort = 8091
    private(set) var embeddedRunning = false
    private(set) var lastError: String?
    private(set) var torrents: [TorrentStatus] = []
    /// hash → where the torrent came from.
    private(set) var origins: [String: TorrentOrigin] = [:]
    /// hash → last 60 download-speed samples (bytes/s), for sparklines.
    private(set) var speedHistory: [String: [Double]] = [:]

    nonisolated static var embeddedAvailable: Bool {
        #if canImport(TorrServerKit) && os(iOS)
        return true
        #else
        return false
        #endif
    }

    private var settings: AppSettings { AppSettings.shared }
    private let http = HTTPClient(timeout: 20)

    var mode: TorrentMode { Self.embeddedAvailable ? settings.values.torrentMode : .remote }

    var baseURL: URL? {
        switch mode {
        case .embedded: return URL(string: "http://127.0.0.1:\(Self.embeddedPort)")
        case .remote: return URL.normalizedBase(settings.values.remoteTorrServerURL)
        }
    }

    var isConfigured: Bool { mode == .embedded || baseURL != nil }

    private var authHeaders: [String: String] {
        let user = settings.values.torrServerUser
        guard mode == .remote, !user.isEmpty else { return [:] }
        let token = Data("\(user):\(settings.torrServerPassword)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(token)"]
    }

    /// Headers mpv must send when reading from a password-protected remote TorrServer.
    var playbackHeaders: [String: String] { authHeaders }

    private init() {
        origins = FileStore.load([String: TorrentOrigin].self, "torrent-origins.json") ?? [:]
    }

    /// Torrents that are downloading or preparing (TorrServer stat 0–3).
    var activeTorrents: [TorrentStatus] { torrents.filter { (0...3).contains($0.stat) } }
    var activeCount: Int { activeTorrents.count }

    private func saveOrigins() {
        // Keep the newest 200.
        if origins.count > 200 {
            let keep = origins.values.sorted { $0.addedAt > $1.addedAt }.prefix(200)
            origins = Dictionary(keep.map { ($0.hash, $0) }, uniquingKeysWith: { a, _ in a })
        }
        FileStore.save(origins, "torrent-origins.json")
    }

    private func recordOrigin(_ source: TorrentSource, hash: String, file: TorrentFile?) {
        let key = hash.lowercased()
        var o = origins[key] ?? TorrentOrigin(hash: key, addedAt: Date())
        o.title = source.title ?? o.title
        o.poster = source.poster ?? o.poster
        o.season = source.season ?? o.season
        o.episode = source.episode ?? o.episode
        o.addonName = source.addonName ?? o.addonName
        o.itemID = source.itemID ?? o.itemID
        o.fileName = file?.name ?? o.fileName
        o.addedAt = Date()
        origins[key] = o
        saveOrigins()
    }

    func origin(for hash: String) -> TorrentOrigin? { origins[hash.lowercased()] }

    // MARK: Embedded lifecycle

    /// Result of `ensureRunning()`.
    struct Health {
        /// TorrServer answered /echo.
        var reachable: Bool
        /// The embedded engine had died and was started again: every torrent it had is gone and
        /// open stream connections are dead, so a playing torrent must be re-added and reloaded.
        var restarted: Bool
    }

    /// One in-flight start, shared by every caller (app launch, Activity, API calls, the player).
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// One in-flight health check / revive, shared by every caller.
    @ObservationIgnored private var healthTask: Task<Health, Never>?
    @ObservationIgnored private var backgroundedAt: Date?

    func startEmbeddedIfNeeded() async {
        guard mode == .embedded, !embeddedRunning else { return }
        if let running = startTask {
            await running.value
            return
        }
        let task = Task { @MainActor in
            await self.startEmbeddedNow()
            self.startTask = nil
        }
        startTask = task
        await task.value
    }

    private func startEmbeddedNow() async {
        guard mode == .embedded, !embeddedRunning else { return }
        #if canImport(TorrServerKit) && os(iOS)
        let dir = FileStore.directory.appendingPathComponent("torrserver", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let port = Self.embeddedPort
        let err: String = await Task.detached(priority: .userInitiated) {
            TorrserverkitStartServer(port, dir.path)
        }.value
        if err.isEmpty || err.contains("already running") {
            // Only trust the engine once it answers: after iOS suspended the app, the Go side can
            // still report "already running" while its HTTP listener is gone.
            if await waitUntilReachable(seconds: 8) {
                embeddedRunning = true
                lastError = nil
                await applyEmbeddedSettings()
            } else {
                embeddedRunning = false
                lastError = err.isEmpty
                    ? "The torrent engine didn't start. Try again in a moment."
                    : "The torrent engine stopped responding. Close StreamForge from the app switcher and open it again."
            }
        } else {
            lastError = err
        }
        #endif
    }

    func stopEmbedded() {
        #if canImport(TorrServerKit) && os(iOS)
        guard embeddedRunning else { return }
        _ = TorrserverkitStopServer()
        embeddedRunning = false
        #endif
    }

    @discardableResult
    private func waitUntilReachable(seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if await ping(timeout: 2) { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        } while Date() < deadline
        return false
    }

    /// Makes sure TorrServer answers before a torrent is (re)resolved. iOS suspends the app (and with
    /// it the embedded Go engine, its listener and every socket) whenever nothing plays in the
    /// background, so on return the engine can be dead while `embeddedRunning` is still true, and
    /// pooled keep-alive connections to it are stale. This drops stale connections, pings, and
    /// starts the embedded engine again when it doesn't answer.
    @discardableResult
    func ensureRunning() async -> Health {
        if let running = healthTask { return await running.value }
        let task = Task { @MainActor () -> Health in
            let result = await self.checkAndRevive()
            self.healthTask = nil
            return result
        }
        healthTask = task
        return await task.value
    }

    private func checkAndRevive() async -> Health {
        guard isConfigured else { return Health(reachable: false, restarted: false) }
        if mode == .remote {
            if await ping() { return Health(reachable: true, restarted: false) }
            await http.flushConnections()
            return Health(reachable: await ping(), restarted: false)
        }
        let wasRunning = embeddedRunning
        if wasRunning {
            if await ping() { return Health(reachable: true, restarted: false) }
            await http.flushConnections()
            if await ping() { return Health(reachable: true, restarted: false) }
            // Dead: forget it, so the start below really runs.
            embeddedRunning = false
            torrents = []
        }
        await startEmbeddedIfNeeded()
        return Health(reachable: embeddedRunning, restarted: wasRunning && embeddedRunning)
    }

    /// Called when the app goes to the background.
    func noteBackground() {
        backgroundedAt = Date()
    }

    /// Called when the app is active again: drops connections that died while the app was suspended
    /// and revives the embedded engine if it was running before.
    func returnedToForeground() {
        guard let since = backgroundedAt else { return }
        backgroundedAt = nil
        let away = Date().timeIntervalSince(since)
        Task { @MainActor in
            await HTTPClient.shared.flushConnections()
            await self.http.flushConnections()
            if self.mode == .embedded, self.embeddedRunning, away > 2 {
                await self.ensureRunning()
            }
        }
    }

    /// Keeps the on-device cache small and favours sequential reading for streaming.
    private func applyEmbeddedSettings() async {
        guard let base = baseURL else { return }
        let cacheBytes = settings.values.embeddedCacheMB * 1024 * 1024
        // "set" replaces the whole settings object, so read-modify-write.
        guard let getBody = try? JSONSerialization.data(withJSONObject: ["action": "get"]),
              let current = try? await http.data(base.appendingRawPath("settings"), method: "POST", headers: authHeaders, body: getBody),
              var sets = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any] else { return }
        let overrides: [String: Any] = [
            "CacheSize": cacheBytes,
            "ReaderReadAHead": 95,
            "PreloadCache": settings.values.preloadPercent,
            "UseDisk": false,
            "RemoveCacheOnDrop": true,
            "ConnectionsLimit": 40,
            "TorrentDisconnectTimeout": 30,
            "EnableDLNA": false,
            "EnableBonjour": false,
            "EnableIPv6": false,
        ]
        for (k, v) in overrides { sets[k] = v }
        if let data = try? JSONSerialization.data(withJSONObject: ["action": "set", "sets": sets]) {
            _ = try? await http.data(base.appendingRawPath("settings"), method: "POST", headers: authHeaders, body: data)
        }
    }

    // MARK: API

    func ping(timeout: TimeInterval = 3) async -> Bool {
        guard let base = baseURL else { return false }
        return (try? await http.data(base.appendingRawPath("echo"), headers: authHeaders, timeout: timeout)) != nil
    }

    func serverVersion() async -> String? {
        guard let base = baseURL, let data = try? await http.data(base.appendingRawPath("echo"), headers: authHeaders, timeout: 5) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmed
    }

    private func torrentsCall<T: Decodable>(_ type: T.Type, _ body: [String: Any]) async throws -> T {
        if mode == .embedded { await startEmbeddedIfNeeded() }
        guard let base = baseURL else { throw HTTPError.transport("Set a TorrServer address in Settings → Torrents.") }
        let data = try JSONSerialization.data(withJSONObject: body)
        let res = try await http.data(base.appendingRawPath("torrents"), method: "POST", headers: authHeaders, body: data)
        return try http.decode(T.self, res)
    }

    func add(_ source: TorrentSource) async throws -> TorrentStatus {
        var body: [String: Any] = ["action": "add", "link": source.magnet, "save_to_db": false]
        if let t = source.title { body["title"] = t }
        if let p = source.poster { body["poster"] = p.absoluteString }
        return try await torrentsCall(TorrentStatus.self, body)
    }

    func addTorrentFile(_ data: Data, title: String?) async throws -> TorrentStatus {
        if mode == .embedded { await startEmbeddedIfNeeded() }
        guard let base = baseURL else { throw HTTPError.transport("Set a TorrServer address in Settings → Torrents.") }
        let boundary = "sf-\(UUID().uuidString)"
        var body = Data()
        func part(_ name: String, _ value: Data, filename: String? = nil) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            var disp = "Content-Disposition: form-data; name=\"\(name)\""
            if let filename { disp += "; filename=\"\(filename)\"" }
            body.append("\(disp)\r\n\r\n".data(using: .utf8)!)
            body.append(value)
            body.append("\r\n".data(using: .utf8)!)
        }
        part("file", data, filename: "file.torrent")
        if let title { part("title", Data(title.utf8)) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        var headers = authHeaders
        headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
        let res = try await http.data(base.appendingRawPath("torrent/upload"), method: "POST", headers: headers, body: body)
        return try http.decode(TorrentStatus.self, res)
    }

    func status(_ hash: String) async throws -> TorrentStatus {
        try await torrentsCall(TorrentStatus.self, ["action": "get", "hash": hash])
    }

    func refreshList() async {
        guard isConfigured else { return }
        if let list = try? await torrentsCall([TorrentStatus].self, ["action": "list"]) {
            torrents = list
            var history = speedHistory
            let live = Set(list.map(\.hash))
            for t in list {
                var samples = history[t.hash] ?? []
                samples.append(max(0, t.downloadSpeed))
                if samples.count > 60 { samples.removeFirst(samples.count - 60) }
                history[t.hash] = samples
            }
            for key in history.keys where !live.contains(key) { history[key] = nil }
            speedHistory = history
        }
    }

    /// Polls the list without waking the embedded engine (for badges).
    func refreshListIfRunning() async {
        if mode == .embedded && !embeddedRunning { return }
        await refreshList()
    }

    func remove(_ hash: String) async {
        _ = try? await torrentsCall(AnyDecodable.self, ["action": "rem", "hash": hash])
        torrents.removeAll { $0.hash == hash }
        speedHistory[hash] = nil
        origins[hash.lowercased()] = nil
        saveOrigins()
    }

    /// Saves the torrent in TorrServer's database so it survives restarts ("keep"). TorrServer's
    /// `add` with save_to_db on an existing hash just persists it.
    func keep(_ status: TorrentStatus) async throws {
        var body: [String: Any] = ["action": "add", "link": "magnet:?xt=urn:btih:\(status.hash)", "save_to_db": true]
        let o = origin(for: status.hash)
        if let t = o?.title ?? status.title.nilIfEmpty { body["title"] = t }
        if let p = o?.poster ?? status.poster { body["poster"] = p.absoluteString }
        _ = try await torrentsCall(AnyDecodable.self, body)
        let key = status.hash.lowercased()
        var updated = origins[key] ?? TorrentOrigin(hash: key, title: status.title, poster: status.poster, addedAt: Date())
        updated.kept = true
        origins[key] = updated
        saveOrigins()
    }

    func drop(_ hash: String) async {
        _ = try? await torrentsCall(AnyDecodable.self, ["action": "drop", "hash": hash])
    }

    /// Adds the torrent, waits for metadata, chooses the right file and returns a URL mpv can stream.
    func resolve(_ source: TorrentSource, progress: @escaping @MainActor (String) -> Void) async throws -> (url: URL, file: TorrentFile, hash: String) {
        progress("Connecting to peers…")
        // Never trust a stale engine/session: after the app was in the background the engine may be
        // dead (or restarted without our torrent). Re-adding below restores the torrent with its trackers.
        let health = await ensureRunning()
        guard health.reachable else {
            throw HTTPError.transport(lastError ?? (mode == .remote
                ? "Can't reach your TorrServer. Check the address in Settings → Torrents."
                : "The torrent engine isn't responding. Try again in a moment."))
        }
        try Task.checkCancellation()
        var status = try await add(source)
        let hash = status.hash.isEmpty ? source.infoHash : status.hash
        var attempts = 0
        while !status.hasMetadata {
            try Task.checkCancellation()
            attempts += 1
            if attempts > 90 { throw HTTPError.transport("No peers responded. The torrent may be dead.") }
            try await Task.sleep(nanoseconds: 500_000_000)
            status = try await self.status(hash)
            let peers = status.activePeers > 0 ? " · \(status.activePeers) peers" : ""
            progress("Fetching torrent info…\(peers)")
        }
        guard let file = pickFile(status.files, source: source) else {
            throw HTTPError.transport("No playable video file in this torrent.")
        }
        recordOrigin(source, hash: hash, file: file)
        guard let base = baseURL else { throw HTTPError.transport("TorrServer not configured") }
        let name = file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "video"
        let url = base.appendingRawPath("stream/\(name)").appendingQuery(["link": hash, "index": String(file.id), "play": ""])
        // gin treats "play=" as present; strip the "=" for clarity with older builds.
        let final = URL(string: url.absoluteString.replacingOccurrences(of: "play=", with: "play")) ?? url
        progress("Buffering…")
        return (final, file, hash)
    }

    private func pickFile(_ files: [TorrentFile], source: TorrentSource) -> TorrentFile? {
        // Stremio's fileIdx is 0-based in torrent order; TorrServer ids are 1-based in the same order.
        if let idx = source.fileIdx, let f = files.first(where: { $0.id == idx + 1 }), f.isVideo || files.count == 1 {
            return f
        }
        if let name = source.filename?.lowercased(), let f = files.first(where: { $0.name.lowercased() == name }) {
            return f
        }
        let videos = files.filter(\.isVideo)
        if let s = source.season, let e = source.episode {
            let patterns = [String(format: "s%02de%02d", s, e), String(format: "%dx%02d", s, e), String(format: "e%02d", e)]
            for p in patterns {
                if let f = videos.first(where: { $0.name.lowercased().contains(p) }) { return f }
            }
        }
        return videos.max { $0.length < $1.length } ?? files.max { $0.length < $1.length }
    }

    func streamURL(hash: String, file: TorrentFile) -> URL? {
        guard let base = baseURL else { return nil }
        let name = file.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "video"
        let url = base.appendingRawPath("stream/\(name)").appendingQuery(["link": hash, "index": String(file.id), "play": ""])
        return URL(string: url.absoluteString.replacingOccurrences(of: "play=", with: "play")) ?? url
    }
}
