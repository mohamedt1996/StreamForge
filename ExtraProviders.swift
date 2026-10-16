import Foundation

/// OMDb: IMDb, Rotten Tomatoes and Metacritic ratings.
struct OMDbClient {
    let key: String
    var isConfigured: Bool { !key.isEmpty }

    struct Response: Decodable {
        struct Rating: Decodable { var Source: String; var Value: String }
        var Ratings: [Rating]?
        var imdbRating: String?
        var Rated: String?
        var Awards: String?
    }

    func ratings(imdbID: String) async throws -> (badges: [RatingBadge], rated: String?, awards: String?) {
        let url = URL(string: "https://www.omdbapi.com/")!.appendingQuery(["i": imdbID, "apikey": key])
        let r = try await HTTPClient.shared.get(Response.self, url)
        var badges: [RatingBadge] = []
        for rating in r.Ratings ?? [] {
            switch rating.Source {
            case "Internet Movie Database": badges.append(RatingBadge(source: "IMDb", value: rating.Value.replacingOccurrences(of: "/10", with: "")))
            case "Rotten Tomatoes": badges.append(RatingBadge(source: "Rotten Tomatoes", value: rating.Value))
            case "Metacritic": badges.append(RatingBadge(source: "Metacritic", value: rating.Value.replacingOccurrences(of: "/100", with: "")))
            default: break
            }
        }
        if badges.isEmpty, let i = r.imdbRating, i != "N/A" { badges.append(RatingBadge(source: "IMDb", value: i)) }
        return (badges, r.Rated.flatMap { $0 == "N/A" ? nil : $0 }, r.Awards.flatMap { $0 == "N/A" ? nil : $0 })
    }
}

/// Fanart.tv: transparent title logos and extra backdrops.
struct FanartClient {
    let key: String
    var isConfigured: Bool { !key.isEmpty }

    struct Art: Decodable { var url: String; var lang: String?; var likes: String? }
    struct MovieResponse: Decodable { var hdmovielogo: [Art]?; var movielogo: [Art]?; var moviebackground: [Art]? }
    struct TVResponse: Decodable { var hdtvlogo: [Art]?; var clearlogo: [Art]?; var showbackground: [Art]? }

    private func best(_ arts: [Art]?, lang: String) -> URL? {
        guard let arts, !arts.isEmpty else { return nil }
        let sorted = arts.sorted { (Int($0.likes ?? "0") ?? 0) > (Int($1.likes ?? "0") ?? 0) }
        let pick = sorted.first { $0.lang == lang } ?? sorted.first { $0.lang == "en" } ?? sorted.first
        return pick.flatMap { URL(string: $0.url) }
    }

    func logo(tmdbID: Int, type: MediaType, tvdbOrTMDB: Int? = nil, lang: String) async -> URL? {
        do {
            if type == .series {
                // Fanart's TV endpoint is keyed by TVDB id; TMDB ids work for most shows via the v3.2 API.
                let url = URL(string: "https://webservice.fanart.tv/v3.2/tv/\(tvdbOrTMDB ?? tmdbID)")!.appendingQuery(["api_key": key])
                let r = try await HTTPClient.shared.get(TVResponse.self, url)
                return best(r.hdtvlogo, lang: lang) ?? best(r.clearlogo, lang: lang)
            }
            let url = URL(string: "https://webservice.fanart.tv/v3.2/movies/\(tmdbID)")!.appendingQuery(["api_key": key])
            let r = try await HTTPClient.shared.get(MovieResponse.self, url)
            return best(r.hdmovielogo, lang: lang) ?? best(r.movielogo, lang: lang)
        } catch {
            return nil
        }
    }
}
