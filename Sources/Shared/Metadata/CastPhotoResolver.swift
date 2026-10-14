import Foundation

/// Puts faces on cast lists that arrive as plain names (provider VOD info, Cinemeta links,
/// Trakt): first by matching names against the title's own TMDB credits, then by a TMDB person
/// search per name. Results (including misses) are cached in memory per name, lookups are capped
/// to the first `maxLookups` cast members and run at most `maxConcurrent` at a time.
actor CastPhotoResolver {
    static let shared = CastPhotoResolver()

    static let maxLookups = 20
    static let maxConcurrent = 6
    static let profileSize = "w185"

    struct Match: Hashable, Sendable {
        var id: Int
        var name: String
        var photo: URL?
    }

    /// normalized name → match (nil = TMDB has nobody by that name).
    private var byName: [String: Match?] = [:]
    private var inFlight: [String: Task<Lookup, Never>] = [:]

    /// `answered` is false when the request failed (network/HTTP error), so it isn't cached.
    private struct Lookup: Sendable { var match: Match?; var answered: Bool }
    /// "movie:603" → that title's credits.
    private var credits: [String: [Match]] = [:]
    /// IMDb id → (TMDB id, type).
    private var imdbToTMDB: [String: (Int, MediaType)?] = [:]

    func resolve(cast: [Person], tmdbID: Int?, imdbID: String?, type: MediaType, client: TMDBClient) async -> [Person] {
        guard client.isConfigured, !cast.isEmpty else { return cast }
        // Entries with a positive id came from TMDB itself: a missing photo there is genuinely missing.
        let targets = cast.indices.prefix(Self.maxLookups).filter { cast[$0].photo == nil && cast[$0].id <= 0 }
        guard !targets.isEmpty else { return cast }

        var result = cast
        var usedIDs = Set(cast.map(\.id))
        func apply(_ m: Match, at i: Int) {
            var p = result[i]
            if p.photo == nil { p.photo = m.photo }
            // Two provider names can resolve to one person; keep ids unique for ForEach.
            if p.id <= 0, !usedIDs.contains(m.id) {
                usedIDs.insert(m.id)
                p.id = m.id
            }
            result[i] = p
        }

        // 1. The title's own credits (one request covers the whole list).
        var titleID = tmdbID
        var titleType = type
        if titleID == nil, let imdb = imdbID, imdb.hasPrefix("tt") {
            if let found = await tmdbID(forIMDb: imdb, client: client) { titleID = found.0; titleType = found.1 }
        }
        var pending: [Int] = []
        if let titleID {
            let list = await titleCredits(id: titleID, type: titleType, client: client)
            var index: [String: Match] = [:]
            for m in list where index[Self.normalize(m.name)] == nil { index[Self.normalize(m.name)] = m }
            for i in targets {
                if let m = index[Self.normalize(result[i].name)] { apply(m, at: i) } else { pending.append(i) }
            }
        } else {
            pending = targets
        }
        pending = pending.filter { result[$0].photo == nil }
        guard !pending.isEmpty else { return result }

        // 2. Person search by name, bounded concurrency.
        let names = pending.map { (index: $0, name: result[$0].name) }
        await withTaskGroup(of: (Int, Match?).self) { group in
            var iterator = names.makeIterator()
            var running = 0
            while running < Self.maxConcurrent, let next = iterator.next() {
                group.addTask { (next.index, await self.person(named: next.name, client: client)) }
                running += 1
            }
            while let finished = await group.next() {
                if let m = finished.1 { apply(m, at: finished.0) }
                if let next = iterator.next() {
                    group.addTask { (next.index, await self.person(named: next.name, client: client)) }
                }
            }
        }
        return result
    }

    // MARK: Lookups

    private func tmdbID(forIMDb imdb: String, client: TMDBClient) async -> (Int, MediaType)? {
        if let cached = imdbToTMDB[imdb] { return cached }
        do {
            let found = try await client.find(imdbID: imdb)
            let value: (Int, MediaType)? = found.flatMap { item in item.tmdbID.map { ($0, item.type) } }
            imdbToTMDB[imdb] = value
            return value
        } catch {
            return nil
        }
    }

    private func titleCredits(id: Int, type: MediaType, client: TMDBClient) async -> [Match] {
        let key = "\(type == .series || type == .episode ? "tv" : "movie"):\(id)"
        if let cached = credits[key] { return cached }
        guard let c = try? await client.credits(id: id, type: type) else { return [] }
        let list = (c.cast ?? []).map { Match(id: $0.id, name: $0.name, photo: TMDBClient.image($0.profile_path, size: Self.profileSize)) }
        credits[key] = list
        if credits.count > 200, let first = credits.keys.first { credits[first] = nil }
        return list
    }

    private func person(named name: String, client: TMDBClient) async -> Match? {
        let key = Self.normalize(name)
        guard !key.isEmpty else { return nil }
        if let cached = byName[key] { return cached }
        if let running = inFlight[key] { return await running.value.match }
        let task = Task<Lookup, Never> {
            do {
                let results = try await client.searchPerson(name)
                return Lookup(match: Self.pick(results, for: key), answered: true)
            } catch {
                return Lookup(match: nil, answered: false)
            }
        }
        inFlight[key] = task
        let lookup = await task.value
        inFlight[key] = nil
        // Only cache answers TMDB actually gave (a network error should be retried next time).
        if lookup.answered {
            if byName.count > 3000 { byName.removeAll(keepingCapacity: true) }
            byName[key] = .some(lookup.match)
        }
        return lookup.match
    }

    static func pick(_ results: [TMDBClient.PersonSummary], for normalizedName: String) -> Match? {
        let exact = results.filter { normalize($0.name) == normalizedName }
        func score(_ p: TMDBClient.PersonSummary) -> Double {
            let acting: Double = p.known_for_department == "Acting" ? 1_000_000 : 0
            return acting + (p.popularity ?? 0)
        }
        let withPhoto = exact.filter { $0.profile_path != nil }
        let best: TMDBClient.PersonSummary? = withPhoto.max { score($0) < score($1) }
            ?? exact.first
            ?? (results.count == 1 ? results.first : nil)
        guard let best else { return nil }
        return Match(id: best.id, name: best.name, photo: TMDBClient.image(best.profile_path, size: profileSize))
    }

    /// "Zoë  Saldaña-Perez" → "zoesaldanaperez".
    static func normalize(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}

/// Photos already shown on a cast card, so the person page can show the same face instantly
/// (and at all when TMDB isn't configured or has no profile image).
@MainActor
enum CastPhotoMemory {
    private static var photos: [String: URL] = [:]

    static func remember(_ person: Person) {
        guard let photo = person.photo else { return }
        if photos.count > 500 { photos.removeAll() }
        photos[CastPhotoResolver.normalize(person.name)] = photo
    }

    static func photo(named name: String) -> URL? { photos[CastPhotoResolver.normalize(name)] }
}
