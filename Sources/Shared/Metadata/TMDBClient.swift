import Foundation

/// TMDB v3 client. Accepts either a v3 API key or a v4 read access token.
struct TMDBClient {
    let key: String
    let language: String
    private let http = HTTPClient.shared
    private static let base = URL(string: "https://api.themoviedb.org/3")!
    static let imageBase = "https://image.tmdb.org/t/p/"

    var isConfigured: Bool { !key.isEmpty }

    static func image(_ path: String?, size: String = "w500") -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: imageBase + size + path)
    }

    private func request<T: Decodable>(_ type: T.Type, _ path: String, _ query: [String: String?] = [:]) async throws -> T {
        var q = query
        q["language"] = language
        var headers: [String: String] = [:]
        if key.count > 40 { headers["Authorization"] = "Bearer \(key)" } else { q["api_key"] = key }
        let url = Self.base.appendingRawPath(path).appendingQuery(q)
        return try await http.get(T.self, url, headers: headers)
    }

    // MARK: Models

    struct Page<T: Decodable>: Decodable {
        var results: LossyArray<T>
        var totalPages: Int?
        enum CodingKeys: String, CodingKey { case results, total_pages }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            results = (try? c.decode(LossyArray<T>.self, forKey: .results)) ?? LossyArray<T>()
            totalPages = c.flexInt(.total_pages)
        }
    }

    struct Summary: Decodable, Hashable {
        var id: Int
        var mediaType: String?
        var title: String
        var overview: String?
        var poster: String?
        var backdrop: String?
        var date: String?
        var vote: Double?
        var genreIDs: [Int]

        enum CodingKeys: String, CodingKey {
            case id, media_type, title, name, overview, poster_path, backdrop_path, release_date, first_air_date, vote_average, genre_ids
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            mediaType = c.flexString(.media_type)
            title = c.flexString(.title) ?? c.flexString(.name) ?? ""
            overview = c.flexString(.overview)
            poster = c.flexString(.poster_path)
            backdrop = c.flexString(.backdrop_path)
            date = c.flexString(.release_date) ?? c.flexString(.first_air_date)
            vote = c.flexDouble(.vote_average)
            genreIDs = (try? c.decodeIfPresent([Int].self, forKey: .genre_ids)) ?? []
        }

        func mediaItem(defaultType: MediaType) -> MediaItem {
            let type: MediaType = mediaType == "tv" ? .series : (mediaType == "movie" ? .movie : defaultType)
            return MediaItem(
                id: "tmdb:\(type.rawValue):\(id)", type: type, title: title,
                year: date.flatMap { Int($0.prefix(4)) },
                poster: TMDBClient.image(poster, size: "w342"),
                backdrop: TMDBClient.image(backdrop, size: "w1280"),
                overview: overview, rating: vote.flatMap { $0 > 0 ? $0 : nil },
                genres: genreIDs.compactMap { TMDBClient.genreNames[$0] },
                tmdbID: id, origin: .tmdb(id: id))
        }
    }

    struct Details: Decodable {
        struct Genre: Decodable { var name: String }
        struct Credits: Decodable {
            struct Cast: Decodable { var id: Int; var name: String; var character: String?; var profile_path: String? }
            struct Crew: Decodable { var id: Int; var name: String; var job: String? }
            var cast: [Cast]?
            var crew: [Crew]?
        }
        struct Videos: Decodable {
            struct Video: Decodable { var key: String; var site: String; var type: String; var official: Bool? }
            var results: [Video]
        }
        struct Images: Decodable {
            struct Image: Decodable { var file_path: String; var iso_639_1: String?; var vote_average: Double? }
            var logos: [Image]?
            var backdrops: [Image]?
        }
        struct ExternalIDs: Decodable { var imdb_id: String? }
        struct Season: Decodable {
            var season_number: Int; var name: String?; var poster_path: String?; var episode_count: Int?
        }
        struct Network: Decodable { var name: String }
        struct Recommendations: Decodable { var results: LossyArray<Summary> }
        struct ReleaseDates: Decodable {
            struct Country: Decodable {
                struct Release: Decodable { var certification: String? }
                var iso_3166_1: String; var release_dates: [Release]
            }
            var results: [Country]
        }
        struct ContentRatings: Decodable {
            struct Rating: Decodable { var iso_3166_1: String; var rating: String? }
            var results: [Rating]
        }

        var id: Int
        var title: String?
        var name: String?
        var overview: String?
        var tagline: String?
        var poster_path: String?
        var backdrop_path: String?
        var release_date: String?
        var first_air_date: String?
        var vote_average: Double?
        var runtime: Int?
        var episode_run_time: [Int]?
        var genres: [Genre]?
        var status: String?
        var imdb_id: String?
        var credits: Credits?
        var videos: Videos?
        var images: Images?
        var external_ids: ExternalIDs?
        var seasons: [Season]?
        var networks: [Network]?
        var recommendations: Recommendations?
        var release_dates: ReleaseDates?
        var content_ratings: ContentRatings?
        var belongs_to_collection: CollectionRef?
    }

    struct CollectionRef: Decodable, Hashable {
        var id: Int
        var name: String?
        var poster_path: String?
        var backdrop_path: String?

        var info: CollectionInfo {
            CollectionInfo(id: id, name: name ?? "Collection", poster: TMDBClient.image(poster_path, size: "w342"),
                           backdrop: TMDBClient.image(backdrop_path, size: "w1280"))
        }
    }

    struct CollectionDetails: Decodable {
        var id: Int
        var name: String
        var overview: String?
        var poster_path: String?
        var backdrop_path: String?
        var parts: LossyArray<Summary>?
    }

    /// Just enough of /movie/{id} to know its collection (cheap lookups for the Collections shelf).
    struct MovieBasics: Decodable {
        var id: Int
        var belongs_to_collection: CollectionRef?
    }

    struct PersonSummary: Decodable, Hashable, Identifiable {
        var id: Int
        var name: String
        var profile_path: String?
        var known_for_department: String?
        var popularity: Double?
    }

    struct PersonCredit: Decodable, Hashable, Identifiable {
        var creditID: String
        var tmdbID: Int
        var mediaType: String
        var title: String
        var poster: String?
        var backdrop: String?
        var date: String?
        var popularity: Double
        var vote: Double?
        var role: String?
        var genreIDs: [Int]

        var id: String { creditID }
        var year: Int? { date.flatMap { Int($0.prefix(4)) } }

        enum CodingKeys: String, CodingKey {
            case credit_id, id, media_type, title, name, poster_path, backdrop_path, release_date, first_air_date
            case popularity, vote_average, character, job, genre_ids
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tmdbID = try c.decode(Int.self, forKey: .id)
            creditID = c.flexString(.credit_id) ?? "\(tmdbID)-\(UUID().uuidString)"
            mediaType = c.flexString(.media_type) ?? "movie"
            title = c.flexString(.title) ?? c.flexString(.name) ?? ""
            poster = c.flexString(.poster_path)
            backdrop = c.flexString(.backdrop_path)
            date = c.flexString(.release_date) ?? c.flexString(.first_air_date)
            popularity = c.flexDouble(.popularity) ?? 0
            vote = c.flexDouble(.vote_average)
            role = c.flexString(.character) ?? c.flexString(.job)
            genreIDs = (try? c.decodeIfPresent([Int].self, forKey: .genre_ids)) ?? []
        }

        var mediaItem: MediaItem {
            let type: MediaType = mediaType == "tv" ? .series : .movie
            return MediaItem(id: "tmdb:\(type.rawValue):\(tmdbID)", type: type, title: title, year: year,
                             poster: TMDBClient.image(poster, size: "w342"), backdrop: TMDBClient.image(backdrop, size: "w1280"),
                             rating: vote.flatMap { $0 > 0 ? $0 : nil }, genres: genreIDs.compactMap { TMDBClient.genreNames[$0] },
                             tmdbID: tmdbID, origin: .tmdb(id: tmdbID))
        }
    }

    struct PersonDetails: Decodable {
        struct Credits: Decodable { var cast: LossyArray<PersonCredit>?; var crew: LossyArray<PersonCredit>? }
        struct Images: Decodable { struct Profile: Decodable { var file_path: String }; var profiles: [Profile]? }
        var id: Int
        var name: String
        var biography: String?
        var birthday: String?
        var deathday: String?
        var place_of_birth: String?
        var profile_path: String?
        var known_for_department: String?
        var combined_credits: Credits?
        var images: Images?
    }

    struct SeasonDetails: Decodable {
        struct Episode: Decodable {
            var episode_number: Int; var season_number: Int; var name: String?; var overview: String?
            var still_path: String?; var air_date: String?; var runtime: Int?
        }
        var episodes: [Episode]
    }

    struct FindResult: Decodable {
        var movie_results: LossyArray<Summary>?
        var tv_results: LossyArray<Summary>?
    }

    // MARK: Requests

    func trending(_ type: MediaType, window: String = "week") async throws -> [MediaItem] {
        let path = type == .series ? "trending/tv/\(window)" : "trending/movie/\(window)"
        return try await request(Page<Summary>.self, path).results.elements.map { $0.mediaItem(defaultType: type) }
    }

    func list(_ path: String, type: MediaType, page: Int = 1) async throws -> [MediaItem] {
        try await request(Page<Summary>.self, path, ["page": String(page)]).results.elements.map { $0.mediaItem(defaultType: type) }
    }

    func search(_ query: String) async throws -> [MediaItem] {
        try await request(Page<Summary>.self, "search/multi", ["query": query, "include_adult": "false"])
            .results.elements.filter { $0.mediaType == "movie" || $0.mediaType == "tv" }
            .map { $0.mediaItem(defaultType: .movie) }
    }

    func searchBest(title: String, year: Int?, type: MediaType) async throws -> Summary? {
        let path = type == .series ? "search/tv" : "search/movie"
        var q: [String: String?] = ["query": title]
        if let year { q[type == .series ? "first_air_date_year" : "year"] = String(year) }
        var results = try await request(Page<Summary>.self, path, q).results.elements
        if results.isEmpty, year != nil {
            results = try await request(Page<Summary>.self, path, ["query": title]).results.elements
        }
        let lower = title.lowercased()
        return results.first { $0.title.lowercased() == lower } ?? results.first
    }

    func find(imdbID: String) async throws -> MediaItem? {
        let r = try await request(FindResult.self, "find/\(imdbID)", ["external_source": "imdb_id"])
        if let m = r.movie_results?.elements.first { return m.mediaItem(defaultType: .movie) }
        if let t = r.tv_results?.elements.first { return t.mediaItem(defaultType: .series) }
        return nil
    }

    func details(id: Int, type: MediaType) async throws -> Details {
        let isTV = type == .series || type == .episode
        let append = isTV
            ? "credits,videos,images,external_ids,recommendations,content_ratings"
            : "credits,videos,images,external_ids,recommendations,release_dates"
        let langs = "\(language),en,null"
        return try await request(Details.self, (isTV ? "tv/" : "movie/") + String(id),
                                 ["append_to_response": append, "include_image_language": langs, "include_video_language": langs])
    }

    func collection(id: Int) async throws -> CollectionDetails {
        try await request(CollectionDetails.self, "collection/\(id)")
    }

    func movieBasics(id: Int) async throws -> MovieBasics {
        try await request(MovieBasics.self, "movie/\(id)")
    }

    func person(id: Int) async throws -> PersonDetails {
        var p = try await request(PersonDetails.self, "person/\(id)", ["append_to_response": "combined_credits,images"])
        if (p.biography ?? "").isEmpty, !language.hasPrefix("en") {
            let en = TMDBClient(key: key, language: "en")
            if let bio = try? await en.request(PersonDetails.self, "person/\(id)").biography, !bio.isEmpty { p.biography = bio }
        }
        return p
    }

    func searchPerson(_ name: String) async throws -> [PersonSummary] {
        try await request(Page<PersonSummary>.self, "search/person", ["query": name, "include_adult": "false"]).results.elements
    }

    func season(tvID: Int, season: Int) async throws -> SeasonDetails {
        try await request(SeasonDetails.self, "tv/\(tvID)/season/\(season)")
    }

    static let genreNames: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime", 99: "Documentary",
        18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History", 27: "Horror", 10402: "Music",
        9648: "Mystery", 10749: "Romance", 878: "Science Fiction", 10770: "TV Movie", 53: "Thriller",
        10752: "War", 37: "Western", 10759: "Action & Adventure", 10762: "Kids", 10763: "News",
        10764: "Reality", 10765: "Sci-Fi & Fantasy", 10766: "Soap", 10767: "Talk", 10768: "War & Politics",
    ]
}

extension LossyArray {
    init() { elements = [] }
}
