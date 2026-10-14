import Foundation
import Observation

/// A range the player can offer to skip (intro, recap, credits…).
struct SkipSegment: Identifiable, Hashable {
    enum Kind: String, Hashable { case intro, recap, credits, preview }
    enum Source: String, Hashable { case chapter, aniskip, learned }

    var kind: Kind
    var start: Double
    var end: Double
    var source: Source

    var id: String { "\(kind.rawValue)-\(source.rawValue)-\(Int(start))" }

    var buttonTitle: String {
        switch kind {
        case .intro: return "Skip Intro"
        case .recap: return "Skip Recap"
        case .credits: return "Skip Credits"
        case .preview: return "Skip Preview"
        }
    }

    func contains(_ t: Double) -> Bool { t >= start && t < end - 1 }
}

// MARK: - Chapters

/// Finds intro/recap/credits ranges from chapter titles (several languages, case/diacritic-insensitive).
enum ChapterSkipDetector {
    static func kind(for rawTitle: String) -> SkipSegment.Kind? {
        let title = rawTitle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        let words = Set(title.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        func has(_ needles: String...) -> Bool { needles.contains { title.contains($0) } }
        func word(_ needles: String...) -> Bool { needles.contains { words.contains($0) } }
        func numbered(_ prefix: String) -> Bool {
            words.contains { w in
                guard w.hasPrefix(prefix) else { return false }
                let rest = w.dropFirst(prefix.count)
                return rest.isEmpty || rest.allSatisfy(\.isNumber)
            }
        }

        if has("recap", "previously", "zuvor", "anteriormente", "precedemment", "前回", "あらすじ") { return .recap }
        if has("preview", "next episode", "avance", "vorschau", "予告", "次回") { return .preview }
        if has("intro", "opening", "vorspann", "abertura", "apertura", "sigla iniziale", "オープニング", "theme song", "main title")
            || numbered("op") || word("ouverture") || (has("generique") && !has("fin")) {
            return .intro
        }
        if has("credits", "ending", "outro", "abspann", "creditos", "crediti", "encerramento", "closing", "end title", "エンディング", "generique de fin")
            || numbered("ed") || (has("generique") && has("fin")) {
            return .credits
        }
        return nil
    }

    static func segments(from chapters: [MPVPlayer.Chapter], duration: Double) -> [SkipSegment] {
        guard chapters.count > 1, duration > 60 else { return [] }
        let sorted = chapters.sorted { $0.time < $1.time }
        var out: [SkipSegment] = []
        for (i, c) in sorted.enumerated() {
            guard let kind = Self.kind(for: c.title) else { continue }
            let end = i + 1 < sorted.count ? sorted[i + 1].time : duration
            let length = end - c.time
            let maxLength: Double
            switch kind {
            case .intro, .recap, .preview: maxLength = 360
            case .credits: maxLength = 900
            }
            guard length >= 5, length <= maxLength else { continue }
            // Merge with a directly preceding segment of the same kind ("Opening" + "Opening (cont.)").
            if let last = out.last, last.kind == kind, abs(last.end - c.time) < 1 {
                out[out.count - 1].end = end
            } else {
                out.append(SkipSegment(kind: kind, start: c.time, end: end, source: .chapter))
            }
        }
        return out
    }
}

// MARK: - Learned intros

/// Remembers where a series' intro is, learned from the user skipping it manually.
@MainActor
@Observable
final class IntroMemory {
    static let shared = IntroMemory()

    struct Entry: Codable, Hashable {
        var start: Double
        var end: Double
        var samples: Int
        var updated: Date
    }

    private(set) var entries: [String: Entry] = [:]

    private init() {
        entries = FileStore.load([String: Entry].self, "intro-markers.json") ?? [:]
    }

    static func key(item: MediaItem, season: Int) -> String { "\(item.id)#s\(season)" }

    var count: Int { entries.count }

    func entry(_ key: String) -> Entry? { entries[key] }

    func record(_ key: String, start: Double, end: Double) {
        guard end - start >= 20 else { return }
        if var e = entries[key], abs(e.start - start) < 20, abs(e.end - end) < 25 {
            // Same intro seen again: average it in (weights saturate so it can still drift).
            let w = Double(min(e.samples, 4))
            e.start = (e.start * w + start) / (w + 1)
            e.end = (e.end * w + end) / (w + 1)
            e.samples += 1
            e.updated = Date()
            entries[key] = e
        } else {
            entries[key] = Entry(start: start, end: end, samples: 1, updated: Date())
        }
        save()
    }

    func forget(_ key: String) {
        entries[key] = nil
        save()
    }

    func forgetAll() {
        entries = [:]
        save()
    }

    private func save() {
        // Keep the file small: newest 400 series/seasons.
        if entries.count > 400 {
            let keep = entries.sorted { $0.value.updated > $1.value.updated }.prefix(400)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        FileStore.save(entries, "intro-markers.json", mirrorToDefaults: true)
    }
}

// MARK: - AniSkip

/// Community intro/outro timestamps for anime (api.aniskip.com), keyed by MyAnimeList id.
/// Only used when the item carries a `mal:` or `kitsu:` id (Stremio anime addons); Kitsu ids are
/// mapped to MAL through Kitsu's public mappings endpoint.
actor AniSkipClient {
    static let shared = AniSkipClient()

    private var malForKitsu: [Int: Int] = [:]
    private var cache: [String: [SkipSegment]] = [:]

    private struct IDs { var mal: Int?; var kitsu: Int?; var episode: Int }

    private static func ids(item: MediaItem, episode: EpisodeRef) -> IDs? {
        var candidates: [String] = []
        if let v = episode.stremioVideoID { candidates.append(v) }
        if case .stremio(_, let metaID) = item.origin { candidates.append(metaID) }
        candidates.append(item.id)
        for raw in candidates {
            let parts = raw.split(separator: ":").map(String.init)
            guard parts.count >= 2, let id = Int(parts[1]) else { continue }
            let ep = parts.count >= 3 ? (Int(parts[2]) ?? episode.episode) : episode.episode
            switch parts[0].lowercased() {
            case "mal": return IDs(mal: id, kitsu: nil, episode: ep)
            case "kitsu": return IDs(mal: nil, kitsu: id, episode: ep)
            default: continue
            }
        }
        return nil
    }

    func segments(item: MediaItem, episode: EpisodeRef, duration: Double) async -> [SkipSegment] {
        guard let ids = Self.ids(item: item, episode: episode) else { return [] }
        var mal = ids.mal
        if mal == nil, let kitsu = ids.kitsu { mal = await malID(kitsu: kitsu) }
        guard let mal else { return [] }
        let cacheKey = "\(mal):\(ids.episode)"
        if let hit = cache[cacheKey] { return hit }
        let types = ["op", "ed", "recap", "mixed-op", "mixed-ed"].map { "types%5B%5D=\($0)" }.joined(separator: "&")
        guard let url = URL(string: "https://api.aniskip.com/v2/skip-times/\(mal)/\(ids.episode)?\(types)&episodeLength=\(Int(max(0, duration)))") else { return [] }

        struct Response: Decodable {
            struct Result: Decodable {
                struct Interval: Decodable { var startTime: Double; var endTime: Double }
                var interval: Interval
                var skipType: String
            }
            var found: Bool?
            var results: [Result]?
        }
        guard let data = await Self.fetch(url), let res = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        let list: [SkipSegment] = (res.results ?? []).compactMap { r in
            let kind: SkipSegment.Kind
            switch r.skipType {
            case "op", "mixed-op": kind = .intro
            case "ed", "mixed-ed": kind = .credits
            case "recap": kind = .recap
            default: return nil
            }
            guard r.interval.endTime > r.interval.startTime + 3 else { return nil }
            return SkipSegment(kind: kind, start: r.interval.startTime, end: r.interval.endTime, source: .aniskip)
        }
        cache[cacheKey] = list
        return list
    }

    private func malID(kitsu: Int) async -> Int? {
        if let hit = malForKitsu[kitsu] { return hit }
        guard let url = URL(string: "https://kitsu.app/api/edge/anime/\(kitsu)/mappings?filter%5BexternalSite%5D=myanimelist%2Fanime") else { return nil }
        struct Mappings: Decodable {
            struct Item: Decodable {
                struct Attributes: Decodable { var externalSite: String?; var externalId: String? }
                var attributes: Attributes?
            }
            var data: [Item]?
        }
        guard let data = await Self.fetch(url), let m = try? JSONDecoder().decode(Mappings.self, from: data) else { return nil }
        let id = m.data?.first { $0.attributes?.externalSite == "myanimelist/anime" }?.attributes?.externalId.flatMap { Int($0) }
        if let id { malForKitsu[kitsu] = id }
        return id
    }

    private static func fetch(_ url: URL) async -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let result = try? await URLSession.shared.data(for: req),
              let http = result.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return result.0
    }
}
