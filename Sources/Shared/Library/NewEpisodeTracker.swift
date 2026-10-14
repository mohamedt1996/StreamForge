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

    /// Called after each library refresh with the unfiltered server series.
    func noteServerSeries(_ series: [XCSeries], serverID: UUID) {
        let library = LibraryStore.shared
        let prefix = String(serverID.uuidString.prefix(8))
        var followed = Set(library.favorites.filter { $0.type == .series }.map(\.id))
        for p in library.progress.values where p.item.type == .series { followed.insert(p.item.id) }
        for key in library.watched {
            if let hash = key.firstIndex(of: "#") { followed.insert(String(key[..<hash])) }
        }
        let firstRun = serverState.lastModified.isEmpty
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        for s in series {
            guard let modified = s.lastModified else { continue }
            let key = "\(prefix):\(s.id)"
            let itemID = "xc:\(prefix):series:\(s.id)"
            if let previous = serverState.lastModified[key], modified > previous, !firstRun, followed.contains(itemID),
               Date(timeIntervalSince1970: TimeInterval(modified)) > cutoff {
                serverState.marks[itemID] = Date()
            }
            serverState.lastModified[key] = modified
        }
        serverState.marks = serverState.marks.filter { $0.value > cutoff }
        FileStore.save(serverState, "series-updates.json")
        rebuild()
    }

    /// Opening a series clears its server-side mark.
    func markSeen(_ item: MediaItem) {
        guard serverState.marks[item.id] != nil else { return }
        serverState.marks[item.id] = nil
        FileStore.save(serverState, "series-updates.json")
        rebuild()
    }
}
