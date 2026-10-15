import Foundation
import Observation

/// Groups server movies into TMDB collections ("franchises"). TMDB lookups are lazy, cached on
/// disk, run 4 at a time and capped per session so big libraries don't hammer the API.
@MainActor
@Observable
final class CollectionsIndex {
    static let shared = CollectionsIndex()

    struct Entry: Identifiable, Hashable {
        var info: CollectionInfo
        var items: [MediaItem]
        var id: Int { info.id }
    }

    private struct Cache: Codable {
        /// tmdb movie id → collection id (0 = not in a collection).
        var movieCollection: [String: Int] = [:]
        var collections: [String: CollectionInfo] = [:]
    }

    private(set) var collections: [Entry] = []
    private(set) var isBuilding = false
    private(set) var lookedUp = 0
    @ObservationIgnored private var cache: Cache
    @ObservationIgnored private var lookupsThisSession = 0
    @ObservationIgnored private var running = false

    static let sessionCap = 400

    private init() {
        cache = FileStore.load(Cache.self, "collections-cache.json") ?? Cache()
    }

    /// Server movie that matches a TMDB collection part, if any.
    func serverItem(tmdbID: Int, title: String, year: Int?) -> MediaItem? {
        DispatcharrStore.shared.matchMovieItem(tmdbID: tmdbID, imdbID: nil, title: title, year: year)
    }

    /// Rebuilds groups from the cache, then looks up uncached movies (within the session cap).
    func buildIfNeeded() async {
        guard !isBuilding, !running else { return }
        let tmdb = MetadataService.shared.tmdb
        let store = DispatcharrStore.shared
        guard store.activeServer != nil else { collections = []; return }
        running = true
        defer { running = false }
        // Grouping walks the whole library: done off the main thread on the ready-made MediaItems.
        let unknown = await regroup()
        guard tmdb.isConfigured else { return }
        let budget = Self.sessionCap - lookupsThisSession
        guard budget > 0, !unknown.isEmpty else { return }
        isBuilding = true
        let batch = Array(Set(unknown)).prefix(budget)
        lookupsThisSession += batch.count
        var found: [(Int, TMDBClient.CollectionRef?)] = []
        await withTaskGroup(of: (Int, TMDBClient.CollectionRef?, Bool).self) { group in
            var it = batch.makeIterator()
            for _ in 0..<4 {
                guard let id = it.next() else { break }
                group.addTask { await CollectionsIndex.lookup(tmdb, id) }
            }
            for await (id, ref, ok) in group {
                if ok { found.append((id, ref)) }
                if let next = it.next() { group.addTask { await CollectionsIndex.lookup(tmdb, next) } }
            }
        }
        for pair in found {
            cache.movieCollection[String(pair.0)] = pair.1?.id ?? 0
            if let ref = pair.1 { cache.collections[String(ref.id)] = ref.info }
        }
        lookedUp += found.count
        let snapshot = cache
        Task.detached(priority: .utility) { FileStore.save(snapshot, "collections-cache.json") }
        isBuilding = false
        await regroup()
    }

    nonisolated private static func lookup(_ tmdb: TMDBClient, _ id: Int) async -> (Int, TMDBClient.CollectionRef?, Bool) {
        do {
            let basics = try await tmdb.movieBasics(id: id)
            return (id, basics.belongs_to_collection, true)
        } catch {
            return (id, nil, false)
        }
    }

    /// Rebuilds `collections` from the cache; returns the library's TMDB ids not looked up yet.
    @discardableResult
    private func regroup() async -> [Int] {
        let items = DispatcharrStore.shared.movieItems
        let cache = self.cache
        let result = await detachedCancellable(priority: .utility) { CollectionsIndex.group(items, cache) }
        collections = result.entries
        return result.unknown
    }

    nonisolated private static func group(_ items: [MediaItem], _ cache: Cache) -> (entries: [Entry], unknown: [Int]) {
        var groups: [Int: [MediaItem]] = [:]
        var unknown: [Int] = []
        for m in items {
            guard let t = m.tmdbID else { continue }
            guard let cid = cache.movieCollection[String(t)] else { unknown.append(t); continue }
            if cid > 0 { groups[cid, default: []].append(m) }
        }
        let entries = groups.compactMap { cid, items -> Entry? in
            guard items.count >= 2, let info = cache.collections[String(cid)] else { return nil }
            return Entry(info: info, items: items.sorted { ($0.year ?? 0) < ($1.year ?? 0) })
        }
        .sorted { ($0.items.count, $1.info.name) > ($1.items.count, $0.info.name) }
        return (entries, unknown)
    }
}
