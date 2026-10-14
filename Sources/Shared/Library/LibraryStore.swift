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
/// Each profile has its own file ("library-<profileID>.json"); this store always reflects the
/// active profile, so its API is the same as before profiles existed.
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
        // Added for the sync server; optional so older files still decode.
        /// Favorite item id → when it was added (ms since 1970).
        var favoriteDates: [String: Double]?
        /// Watched local key → canonical sync key (see SyncKeys).
        var watchedCanonical: [String: String]?
    }

    private(set) var favorites: [MediaItem] = []
    private(set) var favoriteChannelIDs: [Int] = []
    private(set) var recentChannelIDs: [Int] = []
    private(set) var progress: [String: WatchProgress] = [:]
    private(set) var watched: Set<String> = []
    private(set) var lastChannelID: Int?
    private(set) var hiddenCategoryIDs: Set<String> = []
    @ObservationIgnored private var favoriteDates: [String: Double] = [:]
    @ObservationIgnored private var watchedCanonical: [String: String] = [:]

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The profile whose library is loaded.
    private(set) var profileID: UUID

    static func fileName(_ profileID: UUID) -> String { "library-\(profileID.uuidString).json" }

    private init() {
        let pid = ProfileStore.shared.activeProfileID
        profileID = pid
        var loaded = FileStore.load(Snapshot.self, Self.fileName(pid))
        // One-time migration of the pre-profiles library into the first profile.
        if !UserDefaults.standard.bool(forKey: "library.migratedToProfiles") {
            if loaded == nil, let legacy = FileStore.load(Snapshot.self, "library.json") {
                loaded = legacy
                FileStore.save(legacy, Self.fileName(pid), mirrorToDefaults: true)
            }
            UserDefaults.standard.set(true, forKey: "library.migratedToProfiles")
        }
        let s = loaded ?? Snapshot()
        favorites = s.favorites
        favoriteChannelIDs = s.favoriteChannelIDs
        recentChannelIDs = s.recentChannelIDs
        progress = s.progress
        watched = s.watched
        lastChannelID = s.lastChannelID
        hiddenCategoryIDs = s.hiddenCategoryIDs
        favoriteDates = s.favoriteDates ?? [:]
        watchedCanonical = s.watchedCanonical ?? [:]
    }

    private func currentSnapshot() -> Snapshot {
        Snapshot(favorites: favorites, favoriteChannelIDs: favoriteChannelIDs, recentChannelIDs: recentChannelIDs,
                 progress: progress, watched: watched, lastChannelID: lastChannelID, hiddenCategoryIDs: hiddenCategoryIDs,
                 favoriteDates: favoriteDates, watchedCanonical: watchedCanonical)
    }

    private func apply(_ s: Snapshot) {
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
        let snapshot = currentSnapshot()
        let name = Self.fileName(profileID)
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            FileStore.save(snapshot, name, mirrorToDefaults: true)
            SnapshotPublisher.schedule()
            CloudSync.shared.schedulePush()
            ServerSync.shared.noteLocalChange()
        }
    }

    /// Writes pending changes immediately (before switching profiles or going to background).
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        FileStore.save(currentSnapshot(), Self.fileName(profileID), mirrorToDefaults: true)
    }

    // MARK: Profiles

    func switchProfile(to id: UUID) {
        guard id != profileID else { return }
        flush()
        profileID = id
        apply(FileStore.load(Snapshot.self, Self.fileName(id)) ?? Snapshot())
    }

    func reloadActiveProfile() {
        saveTask?.cancel()
        saveTask = nil
        apply(FileStore.load(Snapshot.self, Self.fileName(profileID)) ?? Snapshot())
    }

    func deleteLibrary(profileID id: UUID) {
        guard id != profileID else { return }
        FileStore.remove(Self.fileName(id))
    }

    /// Raw library documents per profile id, for backups and device-to-device sync.
    func exportLibraries(profileIDs: [UUID]) -> [String: Data] {
        flush()
        var out: [String: Data] = [:]
        for id in profileIDs {
            let snap = id == profileID ? currentSnapshot() : (FileStore.load(Snapshot.self, Self.fileName(id)) ?? Snapshot())
            if let data = try? JSONEncoder().encode(snap) { out[id.uuidString] = data }
        }
        return out
    }

    func importLibraries(_ map: [String: Data]) {
        for (key, data) in map {
            guard let id = UUID(uuidString: key), let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { continue }
            FileStore.save(snap, Self.fileName(id), mirrorToDefaults: true)
        }
        reloadActiveProfile()
    }

    /// iCloud merge: positions keep the newest per title, watched marks are combined, and lists
    /// (favorites, channels, hidden categories) come from the remote copy only when it is newer
    /// than this device's last upload.
    func mergeLibraries(_ map: [String: Data], remoteIsNewer: Bool) {
        flush()
        for (key, data) in map {
            guard let id = UUID(uuidString: key), let remote = try? JSONDecoder().decode(Snapshot.self, from: data) else { continue }
            var local = id == profileID ? currentSnapshot() : (FileStore.load(Snapshot.self, Self.fileName(id)) ?? Snapshot())
            for (k, p) in remote.progress {
                if let mine = local.progress[k], mine.updatedAt >= p.updatedAt { continue }
                local.progress[k] = p
            }
            local.watched.formUnion(remote.watched)
            for k in local.watched { local.progress[k] = nil }
            if remoteIsNewer {
                local.favorites = remote.favorites
                local.favoriteChannelIDs = remote.favoriteChannelIDs
                local.hiddenCategoryIDs = remote.hiddenCategoryIDs
            }
            FileStore.save(local, Self.fileName(id), mirrorToDefaults: true)
        }
        reloadActiveProfile()
    }

    /// Library documents trimmed to fit iCloud's key-value store (1 MB in total).
    func exportLibrariesForCloud(profileIDs: [UUID]) -> [String: Data] {
        flush()
        var out: [String: Data] = [:]
        for id in profileIDs {
            var snap = id == profileID ? currentSnapshot() : (FileStore.load(Snapshot.self, Self.fileName(id)) ?? Snapshot())
            let newest = snap.progress.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(150)
            snap.progress = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0) })
            snap.favorites = Array(snap.favorites.prefix(300))
            if snap.watched.count > 4000 { snap.watched = Set(snap.watched.prefix(4000)) }
            if let data = try? JSONEncoder().encode(snap) { out[id.uuidString] = data }
        }
        return out
    }

    /// Merges a position from another device / Trakt when it is newer than what we have.
    func mergeRemoteProgress(item: MediaItem, episode: EpisodeRef?, fraction: Double, duration: Double, updatedAt: Date) {
        let key = Self.key(item, episode)
        guard !watched.contains(key), duration > 60, fraction > 0.01, fraction < 0.95 else { return }
        if let local = progress[key], local.updatedAt >= updatedAt { return }
        progress[key] = WatchProgress(key: key, item: item, episode: episode, position: fraction * duration,
                                      duration: duration, updatedAt: updatedAt)
        scheduleSave()
    }

    // MARK: Favorites

    func isFavorite(_ item: MediaItem) -> Bool { favorites.contains { $0.id == item.id } }

    func toggleFavorite(_ item: MediaItem) {
        // Pin dates on older favorites first so their sync records don't change with the order.
        Self.backfillFavoriteDates(favorites, &favoriteDates)
        if let i = favorites.firstIndex(where: { $0.id == item.id }) {
            favorites.remove(at: i)
            favoriteDates[item.id] = nil
        } else {
            favorites.insert(item, at: 0)
            favoriteDates[item.id] = (Date().timeIntervalSince1970 * 1000).rounded()
        }
        scheduleSave()
    }

    /// Favorites saved before dates were tracked get stable, ordered placeholder dates.
    static func backfillFavoriteDates(_ list: [MediaItem], _ dates: inout [String: Double]) {
        for (i, item) in list.enumerated() where dates[item.id] == nil {
            dates[item.id] = SyncKeys.legacyFavoriteBase - Double(i) * 1000
        }
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
        if value {
            watched.insert(key)
            progress[key] = nil
            watchedCanonical[key] = SyncKeys.fullKey(item, episode)
        } else {
            watched.remove(key)
            watchedCanonical[key] = nil
        }
        scheduleSave()
    }

    func updateProgress(item: MediaItem, episode: EpisodeRef?, position: Double, duration: Double) {
        guard duration > 60, position > 5 else { return }
        let key = Self.key(item, episode)
        let p = WatchProgress(key: key, item: item, episode: episode, position: position, duration: duration, updatedAt: Date())
        if p.isFinished {
            progress[key] = nil
            watched.insert(key)
            watchedCanonical[key] = SyncKeys.fullKey(item, episode)
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

    // MARK: Sync server

    /// The parts of a profile's library that the sync server mirrors.
    struct SyncLibrary {
        var favorites: [MediaItem]
        /// Favorite item id → added (ms since 1970); complete for every favorite.
        var favoriteDates: [String: Double]
        var favoriteChannelIDs: [Int]
        var progress: [String: WatchProgress]
        var watched: Set<String>
        var watchedCanonical: [String: String]
    }

    private static func syncLibrary(from s: Snapshot) -> SyncLibrary {
        var dates = s.favoriteDates ?? [:]
        backfillFavoriteDates(s.favorites, &dates)
        return SyncLibrary(favorites: s.favorites, favoriteDates: dates, favoriteChannelIDs: s.favoriteChannelIDs,
                           progress: s.progress, watched: s.watched, watchedCanonical: s.watchedCanonical ?? [:])
    }

    private static func merge(_ lib: SyncLibrary, into s: inout Snapshot) {
        s.favorites = lib.favorites
        let ids = Set(lib.favorites.map(\.id))
        s.favoriteDates = lib.favoriteDates.filter { ids.contains($0.key) }
        s.favoriteChannelIDs = lib.favoriteChannelIDs
        s.progress = lib.progress
        s.watched = lib.watched
        s.watchedCanonical = lib.watchedCanonical.filter { lib.watched.contains($0.key) }
    }

    /// A profile's library (the active one from memory, others from disk).
    func syncLibrary(for id: UUID) -> SyncLibrary {
        let snap = id == profileID ? currentSnapshot() : (FileStore.load(Snapshot.self, Self.fileName(id)) ?? Snapshot())
        return Self.syncLibrary(from: snap)
    }

    /// Writes records received from the sync server into a profile's library.
    func applySyncLibrary(_ lib: SyncLibrary, for id: UUID) {
        if id == profileID {
            var snap = currentSnapshot()
            Self.merge(lib, into: &snap)
            apply(snap)
            scheduleSave()
        } else {
            var snap = FileStore.load(Snapshot.self, Self.fileName(id)) ?? Snapshot()
            Self.merge(lib, into: &snap)
            FileStore.save(snap, Self.fileName(id), mirrorToDefaults: true)
        }
    }
}
