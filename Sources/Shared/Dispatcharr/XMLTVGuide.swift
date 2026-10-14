import Foundation
import Observation

/// Compact on-disk representation of one XMLTV programme. Short keys keep the cache small.
struct GuideProgramme: Codable, Hashable {
    var start: Double
    var stop: Double
    var title: String
    var subtitle: String?
    var desc: String?
    var categories: [String]?
    var episode: String?
    /// Bit 1: <new/>, bit 2: <live/>, bit 4: <premiere/>.
    var flags: Int?
    var icon: String?

    enum CodingKeys: String, CodingKey {
        case start = "s", stop = "e", title = "t", subtitle = "u", desc = "d", categories = "c", episode = "n", flags = "f", icon = "i"
    }

    func listing(channelKey: String) -> XCEPGListing {
        var l = XCEPGListing(id: "\(channelKey)|\(Int(start))", title: title, description: desc ?? "",
                             start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: stop))
        l.subtitle = subtitle
        l.categories = categories ?? []
        l.episodeNumber = episode
        let f = flags ?? 0
        l.isNew = f & 1 != 0
        l.isLiveBroadcast = f & 2 != 0
        l.isPremiere = f & 4 != 0
        l.icon = icon.flatMap(URL.init(string:))
        return l
    }
}

/// Fast parser for XMLTV timestamps ("yyyyMMddHHmmss +0000"); DateFormatter is far too slow
/// for hundreds of thousands of programmes.
enum XMLTVDate {
    static func parse(_ s: String) -> Double? {
        let bytes = Array(s.utf8)
        guard bytes.count >= 12 else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= bytes.count else { return nil }
            var v = 0
            for i in from..<(from + len) {
                let b = bytes[i]
                guard b >= 48 && b <= 57 else { return nil }
                v = v * 10 + Int(b - 48)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(4, 2), let d = num(6, 2), let h = num(8, 2), let mi = num(10, 2) else { return nil }
        let sec = num(12, 2) ?? 0
        // Timezone offset: first '+' or '-' after the digits.
        var offset = 0
        if let signIndex = bytes.indices.first(where: { $0 >= 12 && (bytes[$0] == 43 || bytes[$0] == 45) }),
           let oh = num(signIndex + 1, 2), let om = num(signIndex + 3, 2) {
            offset = (oh * 3600 + om * 60) * (bytes[signIndex] == 45 ? -1 : 1)
        }
        // Days from civil (Howard Hinnant's algorithm).
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (mo + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Double(days * 86_400 + h * 3600 + mi * 60 + sec - offset)
    }
}

/// Streaming XMLTV parser (SAX). Never builds a DOM, so 200 MB guides parse in constant memory
/// apart from the programmes we keep.
final class XMLTVParser: NSObject, XMLParserDelegate {
    private(set) var programmes: [String: [GuideProgramme]] = [:]
    private(set) var count = 0
    var onProgress: ((Int) -> Void)?

    private var current: GuideProgramme?
    private var currentChannel = ""
    private var text = ""
    private var capturing = false
    private var episodeSystem: String?
    private var onscreen: String?
    private var xmltvNS: String?

    func parse(fileURL: URL) -> Bool {
        guard let stream = InputStream(url: fileURL) else { return false }
        let parser = XMLParser(stream: stream)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        // A truncated file still yields everything parsed so far.
        return ok || count > 0
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "programme":
            guard let channel = attributeDict["channel"], let start = attributeDict["start"].flatMap(XMLTVDate.parse) else {
                current = nil
                return
            }
            let stop = attributeDict["stop"].flatMap(XMLTVDate.parse) ?? start + 1800
            current = GuideProgramme(start: start, stop: max(stop, start + 60), title: "")
            currentChannel = channel
            onscreen = nil
            xmltvNS = nil
        case "title", "sub-title", "desc", "category":
            guard current != nil else { return }
            text = ""
            capturing = true
        case "episode-num":
            guard current != nil else { return }
            text = ""
            capturing = true
            episodeSystem = attributeDict["system"]
        case "icon":
            if current != nil, current?.icon == nil, let src = attributeDict["src"] { current?.icon = src }
        case "new":
            if var p = current { p.flags = (p.flags ?? 0) | 1; current = p }
        case "live":
            if var p = current { p.flags = (p.flags ?? 0) | 2; current = p }
        case "premiere":
            if var p = current { p.flags = (p.flags ?? 0) | 4; current = p }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if capturing, let string = String(data: CDATABlock, encoding: .utf8) { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard current != nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title":
            if current?.title.isEmpty == true { current?.title = value }
        case "sub-title":
            if current?.subtitle == nil, !value.isEmpty { current?.subtitle = value }
        case "desc":
            if current?.desc == nil, !value.isEmpty { current?.desc = value }
        case "category":
            if !value.isEmpty {
                var cats = current?.categories ?? []
                if !cats.contains(value), cats.count < 6 { cats.append(value) }
                current?.categories = cats
            }
        case "episode-num":
            if episodeSystem == "onscreen" { onscreen = value } else if episodeSystem == "xmltv_ns" { xmltvNS = value }
        case "programme":
            if var p = current {
                p.episode = onscreen.flatMap { $0.isEmpty ? nil : $0 } ?? xmltvNS.flatMap(Self.episodeCode)
                if p.title.isEmpty { p.title = "Untitled" }
                programmes[currentChannel, default: []].append(p)
                count += 1
                if count % 5000 == 0 { onProgress?(count) }
            }
            current = nil
        default:
            break
        }
        if elementName != "programme" { capturing = false }
    }

    /// xmltv_ns is zero-based "season.episode.part" ("1.4." → S02E05).
    static func episodeCode(_ ns: String) -> String? {
        let parts = ns.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        let s = Int(parts[0].components(separatedBy: "/")[0].trimmed)
        let e = Int(parts[1].components(separatedBy: "/")[0].trimmed)
        switch (s, e) {
        case let (s?, e?): return String(format: "S%02dE%02d", s + 1, e + 1)
        case let (nil, e?): return "E\(e + 1)"
        default: return nil
        }
    }
}

private struct GuideCacheFile: Codable {
    var savedAt: Date
    var serverID: UUID
    var days: Int
    var channels: [String: [GuideProgramme]]
}

/// A programme currently airing on a channel, for the "Live Sports Now" shelf.
struct LiveProgrammeEntry: Identifiable, Hashable {
    var channel: XCChannel
    var programme: XCEPGListing
    var id: Int { channel.id }
}

/// Dispatcharr's full XMLTV guide, downloaded once (and every 6 hours), parsed off the main
/// thread and cached on disk. Channels map by XC `epg_channel_id`.
@MainActor
@Observable
final class GuideStore {
    static let shared = GuideStore()

    enum Phase: Equatable {
        case idle
        case downloading(bytes: Int64, fraction: Double?)
        case parsing(programmes: Int)
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .parsing: return true
            default: return false
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var programmeCount = 0
    private(set) var channelCount = 0
    private(set) var updatedAt: Date?
    private(set) var earliest: Date?
    private(set) var latest: Date?
    private(set) var revision = 0
    private var listingsByKey: [String: [XCEPGListing]] = [:]
    private var serverID: UUID?
    @ObservationIgnored private var cacheLoadedFor: UUID?
    /// When the last automatic download started; failed downloads aren't retried for 10 minutes.
    @ObservationIgnored private var lastAutoAttempt: Date?
    @ObservationIgnored private var cacheLoadTask: Task<Void, Never>?
    @ObservationIgnored private var sportsCache: (date: Date, revision: Int, channelCount: Int, entries: [LiveProgrammeEntry])?

    static let refreshInterval: TimeInterval = 6 * 3600

    private init() {}

    var hasData: Bool { !listingsByKey.isEmpty }

    var statusText: String {
        switch phase {
        case .downloading(let bytes, let fraction):
            if let fraction, fraction > 0 { return "Downloading guide… \(Int(fraction * 100))%" }
            return "Downloading guide… \(bytes.byteText)"
        case .parsing(let n):
            return "Reading guide… \(n.formatted()) programmes"
        case .failed(let msg):
            return "Guide failed: \(msg)"
        case .idle, .ready:
            guard let updatedAt, programmeCount > 0 else { return "Guide not downloaded yet" }
            return "Guide: \(programmeCount.formatted()) programmes, updated \(updatedAt.formatted(date: .omitted, time: .shortened))"
        }
    }

    // MARK: Lookups

    /// Bulk programmes for a channel, sorted by start; nil when the guide doesn't cover it.
    /// Dispatcharr's xmltv.php uses the channel number as the XMLTV channel id, which is also what
    /// its XC API reports as `epg_channel_id`. Fall back to the number when the id is missing.
    func listings(for channel: XCChannel) -> [XCEPGListing]? {
        if let key = channel.epgChannelID?.trimmingCharacters(in: .whitespaces), !key.isEmpty,
           let list = listingsByKey[key], !list.isEmpty {
            return list
        }
        if let n = channel.number {
            for key in [String(n), "\(n).0"] {
                if let list = listingsByKey[key], !list.isEmpty { return list }
            }
        }
        return nil
    }

    /// Binary search for the programme airing at `date`.
    static func programme(in list: [XCEPGListing], at date: Date) -> XCEPGListing? {
        var lo = 0, hi = list.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if list[mid].start <= date { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0, list[found].end > date else { return nil }
        return list[found]
    }

    static func next(in list: [XCEPGListing], after date: Date) -> XCEPGListing? {
        var lo = 0, hi = list.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if list[mid].start > date { found = mid; hi = mid - 1 } else { lo = mid + 1 }
        }
        return found >= 0 ? list[found] : nil
    }

    /// Sports / event programmes airing right now. Cached for 2 minutes.
    func liveSportsNow(channels: [XCChannel], limit: Int = 30) -> [LiveProgrammeEntry] {
        _ = revision
        let now = Date()
        if let c = sportsCache, c.revision == revision, c.channelCount == channels.count, now.timeIntervalSince(c.date) < 120 {
            return Array(c.entries.prefix(limit))
        }
        var out: [LiveProgrammeEntry] = []
        for ch in channels {
            guard let list = listings(for: ch), let p = Self.programme(in: list, at: now), p.isSports else { continue }
            out.append(LiveProgrammeEntry(channel: ch, programme: p))
            if out.count >= 300 { break }
        }
        sportsCache = (now, revision, channels.count, out)
        return Array(out.prefix(limit))
    }

    // MARK: Loading

    private func cacheName(_ id: UUID) -> String { "guide-\(id.uuidString).json" }

    /// Loads the on-disk guide for the active server (once per server).
    func loadCacheIfNeeded() async {
        guard let server = DispatcharrStore.shared.activeServer else { return }
        guard cacheLoadedFor != server.id else {
            // Another caller is (or was) loading it: wait, so nobody mistakes "still decoding" for "stale".
            await cacheLoadTask?.value
            return
        }
        cacheLoadedFor = server.id
        let task = Task { await self.loadCache(server) }
        cacheLoadTask = task
        await task.value
    }

    private func loadCache(_ server: DispatcharrServer) async {
        if serverID != server.id { clear() }
        let url = FileStore.url(cacheName(server.id))
        let result: (GuideCacheFile, [String: [XCEPGListing]])? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(GuideCacheFile.self, from: data) else { return nil }
            return (file, GuideStore.convert(file.channels))
        }.value
        guard let result else { return }
        let file = result.0
        guard DispatcharrStore.shared.activeServer?.id == file.serverID, !phase.isBusy else { return }
        apply(result.1, serverID: file.serverID, savedAt: file.savedAt)
    }

    func clear() {
        listingsByKey = [:]
        programmeCount = 0
        channelCount = 0
        updatedAt = nil
        earliest = nil
        latest = nil
        serverID = nil
        lastAutoAttempt = nil
        revision += 1
        if !phase.isBusy { phase = .idle }
    }

    /// Called when the active server changes.
    func serverDidChange() {
        cacheLoadedFor = nil
        clear()
        Task { await loadCacheIfNeeded() }
    }

    var isStale: Bool {
        guard let updatedAt, serverID == DispatcharrStore.shared.activeServer?.id else { return true }
        return Date().timeIntervalSince(updatedAt) > Self.refreshInterval
    }

    func refreshIfStale() async {
        await loadCacheIfNeeded()
        guard AppSettings.shared.values.refreshGuideAutomatically || !hasData, isStale else { return }
        if let lastAutoAttempt, Date().timeIntervalSince(lastAutoAttempt) < 600 { return }
        guard DispatcharrStore.shared.activeServer != nil, !phase.isBusy else { return }
        lastAutoAttempt = Date()
        await refresh(force: true)
    }

    /// Downloads and parses the XMLTV guide.
    func refresh(force: Bool = false) async {
        let store = DispatcharrStore.shared
        guard let server = store.activeServer, let client = store.client, !server.xcPassword.isEmpty else { return }
        guard !phase.isBusy else { return }
        if !force, !isStale { return }
        let days = AppSettings.shared.values.guideDays
        let prevDays = store.channels.contains(where: \.hasArchive) ? 1 : 0
        guard let url = try? client.xmltvURL(days: days, prevDays: prevDays) else { return }
        phase = .downloading(bytes: 0, fraction: nil)
        do {
            let file = try await GuideDownloader.download(url) { bytes, fraction in
                Task { @MainActor in
                    if case .downloading = GuideStore.shared.phase {
                        GuideStore.shared.phase = .downloading(bytes: bytes, fraction: fraction)
                    }
                }
            }
            phase = .parsing(programmes: 0)
            let serverID = server.id
            let cacheURL = FileStore.url(cacheName(serverID))
            let parsed: [String: [XCEPGListing]]? = await Task.detached(priority: .utility) {
                defer { try? FileManager.default.removeItem(at: file) }
                let parser = XMLTVParser()
                parser.onProgress = { n in
                    Task { @MainActor in
                        if case .parsing = GuideStore.shared.phase { GuideStore.shared.phase = .parsing(programmes: n) }
                    }
                }
                guard parser.parse(fileURL: file), parser.count > 0 else { return nil }
                var channels = parser.programmes
                for key in channels.keys { channels[key]?.sort { $0.start < $1.start } }
                let cache = GuideCacheFile(savedAt: Date(), serverID: serverID, days: days, channels: channels)
                if let data = try? JSONEncoder().encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
                return GuideStore.convert(channels)
            }.value
            guard let parsed else {
                phase = .failed("The guide was empty or not valid XMLTV.")
                return
            }
            guard DispatcharrStore.shared.activeServer?.id == serverID else { phase = .idle; return }
            cacheLoadedFor = serverID
            apply(parsed, serverID: serverID, savedAt: Date())
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func apply(_ listings: [String: [XCEPGListing]], serverID: UUID, savedAt: Date) {
        listingsByKey = listings
        self.serverID = serverID
        updatedAt = savedAt
        programmeCount = listings.values.reduce(0) { $0 + $1.count }
        channelCount = listings.count
        earliest = listings.values.compactMap { $0.first?.start }.min()
        latest = listings.values.compactMap { $0.last?.end }.max()
        revision += 1
        if !phase.isBusy { phase = .ready }
        SnapshotPublisher.schedule()
    }

    nonisolated private static func convert(_ channels: [String: [GuideProgramme]]) -> [String: [XCEPGListing]] {
        var out: [String: [XCEPGListing]] = [:]
        out.reserveCapacity(channels.count)
        for (key, list) in channels {
            out[key] = list.map { $0.listing(channelKey: key) }.sorted { $0.start < $1.start }
        }
        return out
    }
}

/// Downloads a (potentially huge) file to disk with progress, without buffering it in memory.
enum GuideDownloader {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func download(_ url: URL, progress: @escaping @Sendable (Int64, Double?) -> Void) async throws -> URL {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("xmltv-\(UUID().uuidString).xml")
        var request = URLRequest(url: url)
        request.setValue("StreamForge/1.0", forHTTPHeaderField: "User-Agent")
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: request) { tmp, response, error in
                    if let error {
                        cont.resume(throwing: HTTPError.transport(error.localizedDescription))
                        return
                    }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        cont.resume(throwing: (http.statusCode == 401 || http.statusCode == 403) ? HTTPError.unauthorized : HTTPError.status(http.statusCode, nil))
                        return
                    }
                    guard let tmp else {
                        cont.resume(throwing: HTTPError.transport("Empty guide download"))
                        return
                    }
                    do {
                        try FileManager.default.moveItem(at: tmp, to: dest)
                        cont.resume(returning: dest)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
                box.set(task)
                task.resume()
                Task.detached {
                    while task.state == .running || task.state == .suspended {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        let received = task.countOfBytesReceived
                        let expected = task.countOfBytesExpectedToReceive
                        progress(received, expected > 0 ? Double(received) / Double(expected) : nil)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Holds the in-flight download task so cancellation can reach it.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    func set(_ t: URLSessionTask) { lock.lock(); task = t; lock.unlock() }
    func cancel() { lock.lock(); task?.cancel(); task = nil; lock.unlock() }
}
