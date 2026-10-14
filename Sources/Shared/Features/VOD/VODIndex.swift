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

/// Pre-built MediaItems for the whole Dispatcharr VOD library, rebuilt off the main thread when
/// the library changes. Browsing 50k titles stays smooth because cleaning/mapping happens once.
@MainActor
@Observable
final class VODIndex {
    static let shared = VODIndex()

    private(set) var movies: [MediaItem] = []
    private(set) var series: [MediaItem] = []
    private(set) var moviesByCategory: [String: [MediaItem]] = [:]
    private(set) var seriesByCategory: [String: [MediaItem]] = [:]
    private(set) var isBuilding = false
    private var builtKey: String?

    private init() {}

    func rebuildIfNeeded() {
        let store = DispatcharrStore.shared
        guard let serverID = store.activeServer?.id else {
            movies = []; series = []; moviesByCategory = [:]; seriesByCategory = [:]; builtKey = nil
            return
        }
        let key = "\(serverID)-\(store.movies.count)-\(store.series.count)-\(store.movies.first?.id ?? 0)-\(store.lastRefresh?.timeIntervalSince1970 ?? 0)"
        guard key != builtKey, !isBuilding else { return }
        isBuilding = true
        let rawMovies = store.movies
        let rawSeries = store.series
        Task {
            let built = await Task.detached(priority: .userInitiated) { () -> ([MediaItem], [MediaItem]) in
                (rawMovies.map { $0.mediaItem(serverID: serverID) }, rawSeries.map { $0.mediaItem(serverID: serverID) })
            }.value
            self.movies = built.0
            self.series = built.1
            self.moviesByCategory = Dictionary(grouping: built.0) { $0.categoryID ?? "0" }
            self.seriesByCategory = Dictionary(grouping: built.1) { $0.categoryID ?? "0" }
            self.builtKey = key
            self.isBuilding = false
        }
    }

    func items(_ kind: MediaType, categoryID: String?) -> [MediaItem] {
        if let categoryID {
            return (kind == .series ? seriesByCategory : moviesByCategory)[categoryID] ?? []
        }
        return kind == .series ? series : movies
    }

    nonisolated static func apply(_ filter: VODFilter, to items: [MediaItem], watched: Set<String>) -> [MediaItem] {
        let q = filter.query.trimmed.lowercased()
        var out = items.filter { item in
            if !q.isEmpty, !item.title.lowercased().contains(q) { return false }
            if let g = filter.genre, !item.genres.contains(where: { $0.localizedCaseInsensitiveContains(g) }) { return false }
            if let d = filter.decade {
                guard let y = item.year, y >= d, y < d + 10 else { return false }
            }
            if filter.minRating > 0, (item.rating ?? 0) < filter.minRating { return false }
            if filter.unwatchedOnly, watched.contains(item.id) { return false }
            return true
        }
        switch filter.sort {
        case .added: out.sort { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
        case .title: out.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .year: out.sort { ($0.year ?? 0, $0.added ?? .distantPast) > ($1.year ?? 0, $1.added ?? .distantPast) }
        case .rating: out.sort { ($0.rating ?? 0) > ($1.rating ?? 0) }
        }
        return out
    }
}
