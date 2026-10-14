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

    private init() {}

    // MARK: Embedded lifecycle

    func startEmbeddedIfNeeded() async {
        guard mode == .embedded, !embeddedRunning else { return }
        #if canImport(TorrServerKit) && os(iOS)
        let dir = FileStore.directory.appendingPathComponent("torrserver", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let port = Self.embeddedPort
        let err: String = await Task.detached(priority: .userInitiated) {
            TorrserverkitStartServer(port, dir.path)
        }.value
        if err.isEmpty || err.contains("already running") {
            embeddedRunning = true
            lastError = nil
            await waitUntilReachable()
            await applyEmbeddedSettings()
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

    private func waitUntilReachable() async {
        for _ in 0..<40 {
            if await ping() { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
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

    func ping() async -> Bool {
        guard let base = baseURL else { return false }
        return (try? await http.data(base.appendingRawPath("echo"), headers: authHeaders, timeout: 3)) != nil
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
        }
    }

    func remove(_ hash: String) async {
        _ = try? await torrentsCall(AnyDecodable.self, ["action": "rem", "hash": hash])
        torrents.removeAll { $0.hash == hash }
    }

    func drop(_ hash: String) async {
        _ = try? await torrentsCall(AnyDecodable.self, ["action": "drop", "hash": hash])
    }

    /// Adds the torrent, waits for metadata, chooses the right file and returns a URL mpv can stream.
    func resolve(_ source: TorrentSource, progress: @escaping @MainActor (String) -> Void) async throws -> (url: URL, file: TorrentFile, hash: String) {
        progress("Connecting to peers…")
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
