import Foundation
import Observation

enum VODSort: String, CaseIterable, Identifiable, Codable {
    case added = "Recently Added"
    case title = "A–Z"
    case year = "Release Year"
    case rating = "Rating"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .added: return "clock"
        case .title: return "textformat"
        case .year: return "calendar"
        case .rating: return "star"
        }
    }
}

struct VODFilter: Equatable {
    var sort: VODSort = .added
    var genre: String?
    var decade: Int?
    var minRating: Double = 0
    var unwatchedOnly = false
    var query = ""

    var isActive: Bool { genre != nil || decade != nil || minRating > 0 || unwatchedOnly }
}

/// The Dispatcharr VOD library as MediaItems, with per-category slices and the shelves. Everything is
/// built off the main thread by `DispatcharrStore` together with the library (titles are cleaned
/// once there), so this is a thin, observable view of the store's published data.
@MainActor
@Observable
final class VODIndex {
    static let shared = VODIndex()

    private init() {}

    private var store: DispatcharrStore { DispatcharrStore.shared }

    var movies: [MediaItem] { store.movieItems }
    var series: [MediaItem] { store.seriesItems }
    var moviesByCategory: [String: [MediaItem]] { store.movieItemsByCategory }
    var seriesByCategory: [String: [MediaItem]] { store.seriesItemsByCategory }
    var isBuilding: Bool { store.isBuildingVOD }

    /// Kept for callers: the store rebuilds the items whenever the library or the filters change.
    func rebuildIfNeeded() {}

    /// All items, or one category's (newest first).
    func items(_ kind: MediaType, categoryID: String?) -> [MediaItem] {
        if let categoryID {
            return (kind == .series ? seriesByCategory : moviesByCategory)[categoryID] ?? []
        }
        return kind == .series ? series : movies
    }

    /// Newest 30.
    func recent(_ kind: MediaType) -> [MediaItem] { kind == .series ? store.recentSeriesItems : store.recentMovieItems }
    /// Best rated (7+) 30.
    func topRated(_ kind: MediaType) -> [MediaItem] { kind == .series ? store.topSeriesItems : store.topMovieItems }

    /// Filters and sorts on a detached task; nil when the calling task was cancelled (a newer
    /// filter or keystroke superseded it).
    nonisolated static func filtered(_ filter: VODFilter, items: [MediaItem], watched: Set<String>) async -> [MediaItem]? {
        await detachedCancellable { VODIndex.apply(filter, to: items, watched: watched, checkCancellation: true) }
    }

    nonisolated static func apply(_ filter: VODFilter, to items: [MediaItem], watched: Set<String>) -> [MediaItem] {
        apply(filter, to: items, watched: watched, checkCancellation: false) ?? []
    }

    nonisolated private static func apply(_ filter: VODFilter, to items: [MediaItem], watched: Set<String>,
                                          checkCancellation: Bool) -> [MediaItem]? {
        let q = filter.query.trimmed
        let fold: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var out: [MediaItem] = []
        for (n, item) in items.enumerated() {
            if checkCancellation, n % 4096 == 0, Task.isCancelled { return nil }
            if !q.isEmpty, item.title.range(of: q, options: fold) == nil { continue }
            if let g = filter.genre, !item.genres.contains(where: { $0.range(of: g, options: fold) != nil }) { continue }
            if let d = filter.decade {
                guard let y = item.year, y >= d, y < d + 10 else { continue }
            }
            if filter.minRating > 0, (item.rating ?? 0) < filter.minRating { continue }
            if filter.unwatchedOnly, watched.contains(item.id) { continue }
            out.append(item)
        }
        if checkCancellation, Task.isCancelled { return nil }
        switch filter.sort {
        case .added: out.sort { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
        case .title:
            // Fold each title once (not per comparison) and compare without locale lookups: sorting
            // tens of thousands of titles with localizedStandardCompare takes seconds.
            let keyed = out.map { ($0.title.folding(options: fold, locale: nil), $0) }
            out = keyed.sorted { $0.0.compare($1.0, options: [.numeric]) == .orderedAscending }.map { $0.1 }
        case .year: out.sort { ($0.year ?? 0, $0.added ?? .distantPast) > ($1.year ?? 0, $1.added ?? .distantPast) }
        case .rating: out.sort { ($0.rating ?? 0) > ($1.rating ?? 0) }
        }
        return out
    }
}
