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

    static let sessionCap = 400

    private init() {
        cache = FileStore.load(Cache.self, "collections-cache.json") ?? Cache()
    }

    /// Server movie that matches a TMDB collection part, if any.
    func serverItem(tmdbID: Int, title: String, year: Int?) -> MediaItem? {
        let store = DispatcharrStore.shared
        guard let serverID = store.activeServer?.id,
              let m = store.matchMovie(tmdbID: tmdbID, imdbID: nil, title: title, year: year) else { return nil }
        return m.mediaItem(serverID: serverID)
    }

    /// Rebuilds groups from the cache, then looks up uncached movies (within the session cap).
    func buildIfNeeded() async {
        guard !isBuilding else { return }
        let tmdb = MetadataService.shared.tmdb
        let store = DispatcharrStore.shared
        guard let serverID = store.activeServer?.id else { collections = []; return }
        regroup(serverID: serverID)
        guard tmdb.isConfigured else { return }
        let unknown = store.movies.compactMap(\.tmdbID).filter { cache.movieCollection[String($0)] == nil }
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
        FileStore.save(cache, "collections-cache.json")
        isBuilding = false
        regroup(serverID: serverID)
    }

    nonisolated private static func lookup(_ tmdb: TMDBClient, _ id: Int) async -> (Int, TMDBClient.CollectionRef?, Bool) {
        do {
            let basics = try await tmdb.movieBasics(id: id)
            return (id, basics.belongs_to_collection, true)
        } catch {
            return (id, nil, false)
        }
    }

    private func regroup(serverID: UUID) {
        var groups: [Int: [MediaItem]] = [:]
        for m in DispatcharrStore.shared.movies {
            guard let t = m.tmdbID, let cid = cache.movieCollection[String(t)], cid > 0 else { continue }
            groups[cid, default: []].append(m.mediaItem(serverID: serverID))
        }
        collections = groups.compactMap { cid, items -> Entry? in
            guard items.count >= 2, let info = cache.collections[String(cid)] else { return nil }
            return Entry(info: info, items: items.sorted { ($0.year ?? 0) < ($1.year ?? 0) })
        }
        .sorted { ($0.items.count, $1.info.name) > ($1.items.count, $0.info.name) }
    }
}
