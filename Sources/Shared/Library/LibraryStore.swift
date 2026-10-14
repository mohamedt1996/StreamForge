import Foundation
import Observation

struct WatchProgress: Codable, Hashable, Identifiable {
    var id: String { key }
    /// item id, or item id + episode id for episodes.
    var key: String
    var item: MediaItem
    var episode: EpisodeRef?
    var position: Double
    var duration: Double
    var updatedAt: Date

    var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
    var isFinished: Bool { duration > 0 && (position / duration > 0.92 || duration - position < 120) }
    var remainingText: String {
        let mins = Int((duration - position) / 60)
        return mins >= 60 ? "\(mins / 60)h \(mins % 60)m left" : "\(max(1, mins))m left"
    }
}

/// Favorites, watch progress, history and channel preferences, persisted locally.
@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private struct Snapshot: Codable {
        var favorites: [MediaItem] = []
        var favoriteChannelIDs: [Int] = []
        var recentChannelIDs: [Int] = []
        var progress: [String: WatchProgress] = [:]
        var watched: Set<String> = []
        var lastChannelID: Int?
        var hiddenCategoryIDs: Set<String> = []
    }

    private(set) var favorites: [MediaItem] = []
    private(set) var favoriteChannelIDs: [Int] = []
    private(set) var recentChannelIDs: [Int] = []
    private(set) var progress: [String: WatchProgress] = [:]
    private(set) var watched: Set<String> = []
    private(set) var lastChannelID: Int?
    private(set) var hiddenCategoryIDs: Set<String> = []

    private var saveTask: Task<Void, Never>?

    private init() {
        let s = FileStore.load(Snapshot.self, "library.json") ?? Snapshot()
        favorites = s.favorites
        favoriteChannelIDs = s.favoriteChannelIDs
        recentChannelIDs = s.recentChannelIDs
        progress = s.progress
        watched = s.watched
        lastChannelID = s.lastChannelID
        hiddenCategoryIDs = s.hiddenCategoryIDs
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = Snapshot(favorites: favorites, favoriteChannelIDs: favoriteChannelIDs, recentChannelIDs: recentChannelIDs,
                                progress: progress, watched: watched, lastChannelID: lastChannelID, hiddenCategoryIDs: hiddenCategoryIDs)
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            FileStore.save(snapshot, "library.json", mirrorToDefaults: true)
        }
    }

    // MARK: Favorites

    func isFavorite(_ item: MediaItem) -> Bool { favorites.contains { $0.id == item.id } }

    func toggleFavorite(_ item: MediaItem) {
        if let i = favorites.firstIndex(where: { $0.id == item.id }) {
            favorites.remove(at: i)
        } else {
            favorites.insert(item, at: 0)
        }
        scheduleSave()
    }

    func isFavoriteChannel(_ id: Int) -> Bool { favoriteChannelIDs.contains(id) }

    func toggleFavoriteChannel(_ id: Int) {
        if let i = favoriteChannelIDs.firstIndex(of: id) { favoriteChannelIDs.remove(at: i) } else { favoriteChannelIDs.append(id) }
        scheduleSave()
    }

    func moveFavoriteChannels(from: IndexSet, to: Int) {
        favoriteChannelIDs.move(fromOffsets: from, toOffset: to)
        scheduleSave()
    }

    func recordChannel(_ id: Int) {
        recentChannelIDs.removeAll { $0 == id }
        recentChannelIDs.insert(id, at: 0)
        if recentChannelIDs.count > 20 { recentChannelIDs.removeLast(recentChannelIDs.count - 20) }
        lastChannelID = id
        scheduleSave()
    }

    // MARK: Categories

    func isHidden(category id: String) -> Bool { hiddenCategoryIDs.contains(id) }
    func toggleHidden(category id: String) {
        if hiddenCategoryIDs.contains(id) { hiddenCategoryIDs.remove(id) } else { hiddenCategoryIDs.insert(id) }
        scheduleSave()
    }

    // MARK: Progress

    static func key(_ item: MediaItem, _ episode: EpisodeRef?) -> String {
        episode.map { "\(item.id)#\($0.season)x\($0.episode)" } ?? item.id
    }

    func progress(for item: MediaItem, episode: EpisodeRef? = nil) -> WatchProgress? {
        progress[Self.key(item, episode)]
    }

    func isWatched(_ item: MediaItem, episode: EpisodeRef? = nil) -> Bool {
        watched.contains(Self.key(item, episode))
    }

    func setWatched(_ item: MediaItem, episode: EpisodeRef? = nil, _ value: Bool) {
        let key = Self.key(item, episode)
        if value { watched.insert(key); progress[key] = nil } else { watched.remove(key) }
        scheduleSave()
    }

    func updateProgress(item: MediaItem, episode: EpisodeRef?, position: Double, duration: Double) {
        guard duration > 60, position > 5 else { return }
        let key = Self.key(item, episode)
        let p = WatchProgress(key: key, item: item, episode: episode, position: position, duration: duration, updatedAt: Date())
        if p.isFinished {
            progress[key] = nil
            watched.insert(key)
        } else {
            progress[key] = p
        }
        scheduleSave()
    }

    /// "Continue watching": newest first, one entry per show.
    var continueWatching: [WatchProgress] {
        var seen = Set<String>()
        return progress.values.sorted { $0.updatedAt > $1.updatedAt }.filter { seen.insert($0.item.id).inserted }
    }

    /// Latest in-progress or most recently finished episode for a series, used to pick "Resume S2E4".
    func latestEpisodeProgress(for item: MediaItem) -> WatchProgress? {
        progress.values.filter { $0.item.id == item.id && $0.episode != nil }.max { $0.updatedAt < $1.updatedAt }
    }

    func clearProgress(_ key: String) {
        progress[key] = nil
        scheduleSave()
    }
}
