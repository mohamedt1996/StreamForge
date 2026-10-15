import Foundation
import Observation

/// Decides which series get a "NEW" badge: Trakt's next episode aired in the last 7 days, or
/// (without Trakt) the Dispatcharr series' `last_modified` moved forward for a show in your library.
@MainActor
@Observable
final class NewEpisodeTracker {
    static let shared = NewEpisodeTracker()

    /// Item ids plus "imdb:tt…" / "tmdb:123" keys.
    private(set) var newKeys: Set<String> = []

    private struct ServerState: Codable {
        var lastModified: [String: Int] = [:]
        /// series item id → when we noticed the update.
        var marks: [String: Date] = [:]
    }

    @ObservationIgnored private var serverState: ServerState

    private init() {
        serverState = FileStore.load(ServerState.self, "series-updates.json") ?? ServerState()
        rebuild()
    }

    func isNew(_ item: MediaItem) -> Bool {
        guard item.type == .series, !newKeys.isEmpty else { return false }
        if newKeys.contains(item.id) { return true }
        if let i = item.imdbID, newKeys.contains("imdb:\(i)") { return true }
        if let t = item.tmdbID, newKeys.contains("tmdb:\(t)") { return true }
        return false
    }

    func rebuild() {
        var keys = Set<String>()
        let trakt = TraktService.shared
        if trakt.isSignedIn {
            for entry in trakt.upNext where entry.isNew {
                keys.insert(entry.item.id)
                if let i = entry.item.imdbID { keys.insert("imdb:\(i)") }
                if let t = entry.item.tmdbID { keys.insert("tmdb:\(t)") }
            }
        } else {
            let cutoff = Date().addingTimeInterval(-7 * 86_400)
            for (id, date) in serverState.marks where date > cutoff { keys.insert(id) }
        }
        if keys != newKeys { newKeys = keys }
    }

    /// Called after each library refresh with the unfiltered server series. The per-series pass (and
    /// the file write) runs in the background: big libraries have thousands of series.
    func noteServerSeries(_ series: [XCSeries], serverID: UUID) {
        let library = LibraryStore.shared
        let prefix = String(serverID.uuidString.prefix(8))
        var followed = Set(library.favorites.filter { $0.type == .series }.map(\.id))
        for p in library.progress.values where p.item.type == .series { followed.insert(p.item.id) }
        for key in library.watched {
            if let hash = key.firstIndex(of: "#") { followed.insert(String(key[..<hash])) }
        }
        let previous = serverState.lastModified
        let firstRun = previous.isEmpty
        let follows = followed
        Task {
            let result = await detachedCancellable(priority: .utility) { () -> (lastModified: [String: Int], marked: [String]) in
                var lastModified = previous
                var marked: [String] = []
                let cutoff = Date().addingTimeInterval(-7 * 86_400)
                for s in series {
                    guard let modified = s.lastModified else { continue }
                    let key = "\(prefix):\(s.id)"
                    let itemID = "xc:\(prefix):series:\(s.id)"
                    if let old = lastModified[key], modified > old, !firstRun, follows.contains(itemID),
                       Date(timeIntervalSince1970: TimeInterval(modified)) > cutoff {
                        marked.append(itemID)
                    }
                    lastModified[key] = modified
                }
                return (lastModified, marked)
            }
            // Merge on main: new marks are added; marks cleared meanwhile (markSeen) stay cleared.
            serverState.lastModified = result.lastModified
            let now = Date()
            for id in result.marked { serverState.marks[id] = now }
            let cutoff = now.addingTimeInterval(-7 * 86_400)
            serverState.marks = serverState.marks.filter { $0.value > cutoff }
            persist()
            rebuild()
        }
    }

    /// Opening a series clears its server-side mark.
    func markSeen(_ item: MediaItem) {
        guard serverState.marks[item.id] != nil else { return }
        serverState.marks[item.id] = nil
        persist()
        rebuild()
    }

    /// One entry per server series: written off the main thread.
    private func persist() {
        let state = serverState
        Task.detached(priority: .utility) { FileStore.save(state, "series-updates.json") }
    }
}
