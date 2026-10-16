import Foundation
import Observation

/// One offline download with the metadata needed to play it without a network.
struct DownloadRecord: Codable, Identifiable, Hashable {
    enum State: String, Codable { case queued, preparing, downloading, paused, completed, failed }

    /// LibraryStore.key(item, episode), so progress is shared with streaming playback.
    var id: String
    var item: MediaItem
    var episode: EpisodeRef?
    var sourceTitle: String
    var provider: String
    var remoteURL: URL?
    var headers: [String: String] = [:]
    var torrent: TorrentSource?
    var state: State = .queued
    var usesBackgroundSession = true
    var activeTaskToken: String?
    var bytesWritten: Int64 = 0
    var bytesExpected: Int64 = 0
    var fileName: String?
    var posterFileName: String?
    var error: String?
    var createdAt = Date()

    var fraction: Double { bytesExpected > 0 ? min(1, Double(bytesWritten) / Double(bytesExpected)) : 0 }
    var isTorrent: Bool { torrent != nil }
    var displayTitle: String { episode.map { "\(item.title) · \($0.code)" } ?? item.title }

    static func == (a: DownloadRecord, b: DownloadRecord) -> Bool {
        a.id == b.id && a.state == b.state && a.bytesWritten == b.bytesWritten && a.fileName == b.fileName
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Downloads direct HTTP sources (Dispatcharr VOD, direct addon links) and torrents (through
/// TorrServer's stream URL) for offline playback. iOS only: Apple TV has almost no persistent storage.
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    static var isSupported: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    static let unsupportedReason = "Apple TV only gives apps a small cache that the system can clear at any time, so offline downloads are available on iPhone and iPad only."

    private(set) var records: [DownloadRecord] = []

    @ObservationIgnored private var legacyBackgroundIDs: Set<String> = []
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var pausingTasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var pendingResumes: Set<String> = []
    @ObservationIgnored private var backgroundSession: URLSession?
    @ObservationIgnored private var foregroundSession: URLSession?
    @ObservationIgnored private let delegate = DownloadSessionDelegate()
    @ObservationIgnored private var lastProgressUpdate: [String: Date] = [:]
    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?

    nonisolated static let backgroundIdentifier = "com.mohamedt.streamforge.downloads"

    nonisolated static var directory: URL {
        let dir = FileStore.directory.appendingPathComponent("Downloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = dir
            try? url.setResourceValues(values)
        }
        return dir
    }

    nonisolated static func safeName(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return String(cleaned.suffix(120))
    }

    nonisolated static func fileName(for id: String, ext: String) -> String {
        "\(safeName(id)).\(ext.isEmpty ? "mkv" : ext)"
    }

    private init() {
        records = FileStore.load([DownloadRecord].self, "downloads.json") ?? []
        guard Self.isSupported else { return }
        #if os(iOS)
        let bg = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
        bg.isDiscretionary = false
        bg.sessionSendsLaunchEvents = true
        bg.allowsCellularAccess = true
        backgroundSession = URLSession(configuration: bg, delegate: delegate, delegateQueue: nil)
        let fg = URLSessionConfiguration.default
        fg.timeoutIntervalForRequest = 120
        foregroundSession = URLSession(configuration: fg, delegate: delegate, delegateQueue: nil)
        #endif
        legacyBackgroundIDs = Set(records.filter {
            $0.usesBackgroundSession && $0.activeTaskToken == nil && [.queued, .preparing, .downloading].contains($0.state)
        }.map(\.id))
        // Fix up records whose files vanished or whose foreground tasks died with the app.
        for i in records.indices {
            if records[i].state == .completed, localURL(records[i]) == nil {
                records[i].state = .failed
                records[i].error = "The downloaded file is missing."
            }
            if records[i].state == .downloading || records[i].state == .preparing || records[i].state == .queued {
                records[i].state = .paused
            }
        }
        reattachBackgroundTasks()
        save()
    }

    private func save() {
        FileStore.save(records, "downloads.json")
    }

    private func reattachBackgroundTasks() {
        backgroundSession?.getAllTasks { tasks in
            let pairs: [(String, URLSessionDownloadTask)] = tasks.compactMap { t in
                guard let d = t as? URLSessionDownloadTask, let description = d.taskDescription else { return nil }
                return (description.components(separatedBy: "|task|")[0], d)
            }
            Task { @MainActor in
                let manager = DownloadManager.shared
                for (id, task) in pairs {
                    guard manager.ownsTask(id: id, task: task),
                          let i = manager.records.firstIndex(where: { $0.id == id }),
                          manager.records[i].state != .completed else { continue }
                    manager.tasks[id] = task
                    manager.records[i].state = .downloading
                }
                manager.save()
            }
        }
    }

    /// Downloads are shared on disk, but kids may only see and play positively classified content.
    var visibleRecords: [DownloadRecord] { records.filter { isAllowed($0) } }

    private func isAllowed(_ record: DownloadRecord) -> Bool {
        !ProfileStore.shared.isKidsMode || KidsFilter.allows(record.item)
    }

    // MARK: Queries

    func record(for item: MediaItem, episode: EpisodeRef? = nil) -> DownloadRecord? {
        let key = LibraryStore.key(item, episode)
        return visibleRecords.first { $0.id == key }
    }

    func localURL(_ record: DownloadRecord) -> URL? {
        guard let name = record.fileName else { return nil }
        let url = Self.directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func posterURL(_ record: DownloadRecord) -> URL? {
        guard let name = record.posterFileName else { return record.item.poster }
        let url = Self.directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : record.item.poster
    }

    var activeCount: Int { records.filter { $0.state == .downloading || $0.state == .preparing || $0.state == .queued }.count }

    /// Bytes used by finished and partial downloads.
    var storageUsed: Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    var freeSpace: Int64? {
        #if os(iOS)
        let values = try? FileStore.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
        #else
        return nil
        #endif
    }

    // MARK: Actions

    /// Only direct HTTP and torrent sources can be downloaded.
    static func canDownload(_ source: PlaybackSource) -> Bool {
        switch source.kind {
        case .direct(let url, _):
            return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                && !["m3u8", "m3u", "mpd"].contains(url.pathExtension.lowercased())
        case .torrent: return true
        default: return false
        }
    }

    func start(item: MediaItem, episode: EpisodeRef?, source: PlaybackSource) {
        guard Self.isSupported, Self.canDownload(source) else { return }
        let id = LibraryStore.key(item, episode)
        if let existing = records.first(where: { $0.id == id }) {
            guard existing.state == .failed else { return }
            delete(existing)
        }
        var rec = DownloadRecord(id: id, item: item, episode: episode, sourceTitle: source.title, provider: source.provider)
        switch source.kind {
        case .direct(let url, let headers):
            rec.remoteURL = url
            rec.headers = headers
            rec.usesBackgroundSession = true
            records.insert(rec, at: 0)
            save()
            begin(id: id, url: url, headers: headers, background: true)
        case .torrent(let t):
            rec.torrent = t
            rec.state = .preparing
            // The embedded TorrServer is suspended with the app, so its downloads must run in the
            // foreground; a remote TorrServer keeps serving while we're in the background.
            rec.usesBackgroundSession = TorrentEngine.shared.mode == .remote
            records.insert(rec, at: 0)
            save()
            Task { await resolveTorrent(id: id, source: t) }
        default:
            return
        }
        Task { await savePoster(id: id, url: episode?.still ?? item.poster) }
    }

    private func resolveTorrent(id: String, source: TorrentSource) async {
        let engine = TorrentEngine.shared
        do {
            let result = try await engine.resolve(source) { _ in }
            guard let i = records.firstIndex(where: { $0.id == id }), records[i].state == .preparing else { return }
            records[i].remoteURL = result.url
            records[i].headers = engine.playbackHeaders
            records[i].bytesExpected = result.file.length
            save()
            begin(id: id, url: result.url, headers: engine.playbackHeaders, background: records[i].usesBackgroundSession)
        } catch {
            update(id) { $0.state = .failed; $0.error = error.localizedDescription }
        }
    }

    private func begin(id: String, url: URL, headers: [String: String], background: Bool, resumeData: Data? = nil) {
        guard let session = background ? backgroundSession : foregroundSession else { return }
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: url)
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                let ua = AppSettings.shared.values.customUserAgent
                request.setValue(ua.isEmpty ? "StreamForge/1.0" : ua, forHTTPHeaderField: "User-Agent")
            }
            task = session.downloadTask(with: request)
        }
        let token = id + "|task|" + UUID().uuidString
        task.taskDescription = token
        tasks[id] = task
        update(id) { $0.state = .downloading; $0.error = nil; $0.activeTaskToken = token }
        task.resume()
    }

    func pause(_ record: DownloadRecord) {
        legacyBackgroundIDs.remove(record.id)
        guard let task = tasks[record.id] else {
            update(record.id) { $0.state = .paused; $0.activeTaskToken = nil }
            return
        }
        update(record.id) { $0.state = .paused; $0.activeTaskToken = nil }
        let id = record.id
        tasks[id] = nil // Invalidate callbacks from the cancelled task immediately.
        pausingTasks[id] = task
        task.cancel(byProducingResumeData: { data in
            Task { @MainActor in
                let manager = DownloadManager.shared
                guard manager.pausingTasks[id] === task else { return }
                manager.pausingTasks[id] = nil
                if let data {
                    let url = Self.directory.appendingPathComponent(Self.safeName(id) + ".resume")
                    try? data.write(to: url, options: .atomic)
                }
                if manager.pendingResumes.remove(id) != nil,
                   let current = manager.records.first(where: { $0.id == id }) {
                    manager.resume(current)
                }
            }
        })
    }

    func resume(_ record: DownloadRecord) {
        guard let current = records.first(where: { $0.id == record.id }),
              current.state == .paused || current.state == .failed else { return }
        if pausingTasks[record.id] != nil {
            pendingResumes.insert(record.id)
            return
        }
        let resumeURL = Self.directory.appendingPathComponent(Self.safeName(record.id) + ".resume")
        let data = try? Data(contentsOf: resumeURL)
        try? FileManager.default.removeItem(at: resumeURL)
        if let torrent = record.torrent, data == nil {
            // Stream URLs from TorrServer are cheap to re-resolve.
            update(record.id) { $0.state = .preparing; $0.bytesWritten = 0 }
            Task { await resolveTorrent(id: record.id, source: torrent) }
            return
        }
        guard let url = record.remoteURL else { return }
        begin(id: record.id, url: url, headers: record.headers, background: record.usesBackgroundSession, resumeData: data)
    }

    func retry(_ record: DownloadRecord) {
        update(record.id) { $0.bytesWritten = 0; $0.error = nil }
        resume(record)
    }

    func delete(_ record: DownloadRecord) {
        legacyBackgroundIDs.remove(record.id)
        pausingTasks[record.id] = nil
        pendingResumes.remove(record.id)
        tasks[record.id]?.cancel()
        tasks[record.id] = nil
        let fm = FileManager.default
        if let name = record.fileName { try? fm.removeItem(at: Self.directory.appendingPathComponent(name)) }
        if let poster = record.posterFileName { try? fm.removeItem(at: Self.directory.appendingPathComponent(poster)) }
        try? fm.removeItem(at: Self.directory.appendingPathComponent(Self.safeName(record.id) + ".resume"))
        records.removeAll { $0.id == record.id }
        save()
    }

    /// Plays a finished download from disk (mpv plays file:// URLs).
    func play(_ record: DownloadRecord) {
        guard isAllowed(record), let url = localURL(record) else { return }
        var item = record.item
        item.poster = posterURL(record)
        let source = PlaybackSource(id: "offline:\(record.id)", kind: .direct(url, headers: [:]),
                                    title: record.displayTitle, provider: "Downloaded")
        PlayerCoordinator.shared.play(PlaybackRequest(item: item, episode: record.episode, source: source))
    }

    private func savePoster(id: String, url: URL?) async {
        guard let url, url.scheme?.hasPrefix("http") == true,
              let result = try? await URLSession.shared.data(from: url), !result.0.isEmpty else { return }
        let data = result.0
        let name = Self.safeName(id) + ".poster.jpg"
        do {
            try data.write(to: Self.directory.appendingPathComponent(name), options: .atomic)
            update(id) { $0.posterFileName = name }
        } catch {}
    }

    private func update(_ id: String, _ change: (inout DownloadRecord) -> Void) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[i])
        save()
    }

    private func ownsTask(id: String, task: URLSessionTask) -> Bool {
        guard let record = records.first(where: { $0.id == id }) else { return false }
        if let token = record.activeTaskToken { return token == task.taskDescription }
        return tasks[id] === task || (legacyBackgroundIDs.contains(id) && task.taskDescription == id)
    }

    // MARK: Delegate callbacks (hopped to the main actor)

    fileprivate func didProgress(id: String, task: URLSessionTask, written: Int64, expected: Int64) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].state == .downloading else { return }
        guard ownsTask(id: id, task: task) else { return }
        let now = Date()
        if let last = lastProgressUpdate[id], now.timeIntervalSince(last) < 0.5 { return }
        lastProgressUpdate[id] = now
        records[i].bytesWritten = written
        if expected > 0 { records[i].bytesExpected = expected }
    }

    fileprivate func didFinish(id: String, task: URLSessionTask, fileName: String, size: Int64) {
        guard ownsTask(id: id, task: task) else {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(fileName))
            return
        }
        tasks[id] = nil
        legacyBackgroundIDs.remove(id)
        update(id) {
            $0.activeTaskToken = nil
            $0.state = .completed
            $0.fileName = fileName
            $0.bytesWritten = size
            if size > 0 { $0.bytesExpected = size }
            $0.error = nil
        }
    }

    fileprivate func didFail(id: String, task: URLSessionTask, message: String, resumeData: Data?) {
        guard ownsTask(id: id, task: task) else { return }
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        // Pausing cancels the task; that's not a failure.
        guard records[i].state != .completed else { return }
        tasks[id] = nil
        if let resumeData {
            let url = Self.directory.appendingPathComponent(Self.safeName(id) + ".resume")
            try? resumeData.write(to: url, options: .atomic)
        }
        legacyBackgroundIDs.remove(id)
        records[i].activeTaskToken = nil
        records[i].state = .failed
        records[i].error = message
        save()
    }

    fileprivate func finishBackgroundEvents() {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }
}

/// URLSession delegate. Runs on URLSession's queue; state changes hop to the main actor.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription?.components(separatedBy: "|task|").first else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = "Server returned HTTP \(http.statusCode)"
            Task { @MainActor in DownloadManager.shared.didFail(id: id, task: downloadTask, message: message, resumeData: nil) }
            return
        }
        let mime = downloadTask.response?.mimeType?.lowercased() ?? ""
        let prefix: String = {
            guard let handle = try? FileHandle(forReadingFrom: location) else { return "" }
            defer { try? handle.close() }
            return String(data: (try? handle.read(upToCount: 1024)) ?? Data(), encoding: .utf8) ?? ""
        }()
        if mime.contains("mpegurl") || mime.contains("dash+xml") || prefix.contains("#EXTM3U") || prefix.contains("<MPD") {
            Task { @MainActor in
                DownloadManager.shared.didFail(id: id, task: downloadTask,
                    message: "Offline playlist downloads aren't supported. Choose a direct video file or torrent.", resumeData: nil)
            }
            return
        }
        var ext = downloadTask.response?.suggestedFilename.map { ($0 as NSString).pathExtension } ?? ""
        if ext.isEmpty || ext.count > 5 { ext = downloadTask.originalRequest?.url?.pathExtension ?? "" }
        if ext.isEmpty || ext.count > 5 || ext == "php" { ext = "mkv" }
        let name = UUID().uuidString + "-" + DownloadManager.fileName(for: id, ext: ext.lowercased())
        let dest = DownloadManager.directory.appendingPathComponent(name)
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: location, to: dest)
            let size = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            Task { @MainActor in DownloadManager.shared.didFinish(id: id, task: downloadTask, fileName: name, size: size) }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in DownloadManager.shared.didFail(id: id, task: downloadTask, message: message, resumeData: nil) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription?.components(separatedBy: "|task|").first else { return }
        Task { @MainActor in
            DownloadManager.shared.didProgress(id: id, task: downloadTask, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription?.components(separatedBy: "|task|").first else { return }
        let ns = error as NSError
        let resume = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let message = ns.code == NSURLErrorCancelled ? "Cancelled" : error.localizedDescription
        Task { @MainActor in DownloadManager.shared.didFail(id: id, task: task, message: message, resumeData: resume) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in DownloadManager.shared.finishBackgroundEvents() }
    }
}
