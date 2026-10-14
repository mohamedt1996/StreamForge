import Foundation
import Observation

/// Trakt: device-code sign-in, scrobbling, watchlist and up-next.
@MainActor
@Observable
final class TraktService {
    static let shared = TraktService()

    struct DeviceCode: Decodable {
        var device_code: String
        var user_code: String
        var verification_url: String
        var expires_in: Int
        var interval: Int
    }

    private struct Token: Codable {
        var access_token: String
        var refresh_token: String
        var created_at: Int
        var expires_in: Int
    }

    private(set) var username: String?
    private(set) var watchlist: [MediaItem] = []
    /// Next unwatched aired episode per show, most recently watched show first.
    var upNext: [UpNextEntry] = []
    @ObservationIgnored var upNextLoadedAt: Date?
    private var token: Token? {
        didSet {
            if let token, let data = try? JSONEncoder().encode(token) {
                Keychain.set(String(data: data, encoding: .utf8), for: "trakt.token")
            } else {
                Keychain.set(nil, for: "trakt.token")
            }
            ServerSync.shared.noteLocalChange()
        }
    }

    var isSignedIn: Bool { token != nil }
    private var clientID: String { AppSettings.shared.traktClientID }
    private var clientSecret: String { AppSettings.shared.traktClientSecret }
    private let base = URL(string: "https://api.trakt.tv")!

    private init() {
        if let s = Keychain.get("trakt.token"), let data = s.data(using: .utf8) {
            token = try? JSONDecoder().decode(Token.self, from: data)
        }
        username = UserDefaults.standard.string(forKey: "trakt.username")
    }

    private var headers: [String: String] {
        var h = ["trakt-api-version": "2", "trakt-api-key": clientID, "Content-Type": "application/json"]
        if let token { h["Authorization"] = "Bearer \(token.access_token)" }
        return h
    }

    // MARK: Auth

    func startDeviceAuth() async throws -> DeviceCode {
        guard !clientID.isEmpty else { throw HTTPError.transport("Add your Trakt client ID in Settings → Metadata first.") }
        return try await HTTPClient.shared.send(DeviceCode.self, base.appendingRawPath("oauth/device/code"),
                                                 body: ["client_id": clientID], headers: headers)
    }

    /// Polls until the user approves the code on trakt.tv/activate.
    func pollDeviceAuth(_ code: DeviceCode) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(code.expires_in))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(max(code.interval, 5)) * 1_000_000_000)
            let body = ["code": code.device_code, "client_id": clientID, "client_secret": clientSecret]
            if let t = try? await HTTPClient.shared.send(Token.self, base.appendingRawPath("oauth/device/token"), body: body, headers: headers) {
                token = t
                await loadProfile()
                await refreshWatchlist()
                return
            }
        }
        throw HTTPError.transport("The Trakt code expired. Try again.")
    }

    func signOut() {
        token = nil
        username = nil
        watchlist = []
        upNext = []
        upNextLoadedAt = nil
        UserDefaults.standard.removeObject(forKey: "trakt.username")
    }

    private func refreshTokenIfNeeded() async {
        guard let t = token else { return }
        let expiry = TimeInterval(t.created_at + t.expires_in)
        guard Date().timeIntervalSince1970 > expiry - 86_400 else { return }
        let body = ["refresh_token": t.refresh_token, "client_id": clientID, "client_secret": clientSecret,
                    "redirect_uri": "urn:ietf:wg:oauth:2.0:oob", "grant_type": "refresh_token"]
        if let new = try? await HTTPClient.shared.send(Token.self, base.appendingRawPath("oauth/token"), body: body, headers: headers) {
            token = new
        }
    }

    private func loadProfile() async {
        struct Settings: Decodable { struct User: Decodable { var username: String }; var user: User }
        if let s = try? await HTTPClient.shared.get(Settings.self, base.appendingRawPath("users/settings"), headers: headers) {
            username = s.user.username
            UserDefaults.standard.set(s.user.username, forKey: "trakt.username")
        }
    }

    // MARK: Watchlist

    private struct Entry: Decodable {
        struct IDs: Decodable { var imdb: String?; var tmdb: Int? }
        struct Item: Decodable { var title: String; var year: Int?; var ids: IDs }
        var type: String
        var movie: Item?
        var show: Item?
    }

    func refreshWatchlist() async {
        guard isSignedIn else { return }
        await refreshTokenIfNeeded()
        guard let list = try? await HTTPClient.shared.get([Entry].self, base.appendingRawPath("sync/watchlist").appendingQuery(["sort": "added"]), headers: headers) else { return }
        watchlist = list.compactMap { e in
            guard let item = e.movie ?? e.show else { return nil }
            let type: MediaType = e.show != nil ? .series : .movie
            let poster: URL? = item.ids.imdb.flatMap { URL(string: "https://images.metahub.space/poster/medium/\($0)/img") }
            return MediaItem(id: item.ids.imdb ?? "tmdb:\(type.rawValue):\(item.ids.tmdb ?? 0)", type: type, title: item.title,
                             year: item.year, poster: poster, imdbID: item.ids.imdb, tmdbID: item.ids.tmdb,
                             origin: item.ids.imdb.map { .stremio(addonID: "com.linvo.cinemeta", metaID: $0) } ?? .tmdb(id: item.ids.tmdb ?? 0))
        }
    }

    // MARK: Scrobble

    enum ScrobbleAction: String { case start, pause, stop }

    func scrobble(_ action: ScrobbleAction, item: MediaItem, episode: EpisodeRef?, progress: Double) async {
        guard isSignedIn, item.imdbID != nil || item.tmdbID != nil else { return }
        await refreshTokenIfNeeded()
        var ids: [String: Any] = [:]
        if let i = item.imdbID { ids["imdb"] = i }
        if let t = item.tmdbID { ids["tmdb"] = t }
        var body: [String: Any] = ["progress": (progress * 100).rounded() / 1, "app_version": "1.0"]
        if let episode {
            body["show"] = ["ids": ids]
            body["episode"] = ["season": episode.season, "number": episode.episode]
        } else {
            body["movie"] = ["ids": ids]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        _ = try? await HTTPClient.shared.data(base.appendingRawPath("scrobble/\(action.rawValue)"), method: "POST", headers: headers, body: data)
    }
}

// MARK: - Playback sync, Up Next, token transfer

struct TraktIDs: Decodable, Hashable {
    var trakt: Int?
    var slug: String?
    var imdb: String?
    var tmdb: Int?
    var tvdb: Int?
}

/// Next episode to watch for a show the user follows on Trakt.
struct UpNextEntry: Identifiable, Hashable {
    var item: MediaItem
    var episode: EpisodeRef
    var lastWatchedAt: Date
    var firstAired: Date?
    var id: String { item.id }

    /// Aired within the last 7 days.
    var isNew: Bool {
        guard let firstAired else { return false }
        let age = Date().timeIntervalSince(firstAired)
        return age >= 0 && age < 7 * 86_400
    }
}

enum TraktDate {
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

extension TraktService {
    private struct PlaybackEntry: Decodable {
        struct Movie: Decodable { var title: String; var year: Int?; var ids: TraktIDs; var runtime: Int? }
        struct Show: Decodable { var title: String; var year: Int?; var ids: TraktIDs; var runtime: Int? }
        struct Episode: Decodable { var season: Int; var number: Int; var title: String?; var ids: TraktIDs?; var runtime: Int? }
        var progress: Double
        var paused_at: String?
        var type: String
        var movie: Movie?
        var show: Show?
        var episode: Episode?
    }

    private struct WatchedShow: Decodable {
        struct Show: Decodable { var title: String; var year: Int?; var ids: TraktIDs }
        var last_watched_at: String?
        var show: Show
    }

    private struct ShowProgress: Decodable {
        struct Episode: Decodable { var season: Int; var number: Int; var title: String?; var first_aired: String?; var overview: String? }
        var aired: Int?
        var completed: Int?
        var next_episode: Episode?
    }

    /// Server item when the user's Dispatcharr has it (so playback uses the server), else a
    /// Cinemeta / TMDB item.
    func mediaItem(type: MediaType, title: String, year: Int?, ids: TraktIDs) -> MediaItem {
        let store = DispatcharrStore.shared
        if let serverID = store.activeServer?.id {
            if type == .movie, let m = store.matchMovie(tmdbID: ids.tmdb, imdbID: ids.imdb, title: title, year: year) {
                return m.mediaItem(serverID: serverID)
            }
            if type == .series, let s = store.matchSeries(tmdbID: ids.tmdb, imdbID: ids.imdb, title: title) {
                return s.mediaItem(serverID: serverID)
            }
        }
        let poster: URL? = ids.imdb.flatMap { URL(string: "https://images.metahub.space/poster/medium/\($0)/img") }
        let backdrop: URL? = ids.imdb.flatMap { URL(string: "https://images.metahub.space/background/medium/\($0)/img") }
        return MediaItem(id: ids.imdb ?? "tmdb:\(type.rawValue):\(ids.tmdb ?? 0)", type: type, title: title, year: year,
                         poster: poster, backdrop: backdrop, imdbID: ids.imdb, tmdbID: ids.tmdb,
                         origin: ids.imdb.map { .stremio(addonID: "com.linvo.cinemeta", metaID: $0) } ?? .tmdb(id: ids.tmdb ?? 0))
    }

    /// Pulls in-progress positions from Trakt (GET /sync/playback) into the active profile.
    @discardableResult
    func syncPlayback() async -> Int {
        guard isSignedIn else { return 0 }
        await refreshTokenIfNeeded()
        let url = base.appendingRawPath("sync/playback").appendingQuery(["extended": "full"])
        guard let list = try? await HTTPClient.shared.get(LossyArray<PlaybackEntry>.self, url, headers: headers).elements else { return 0 }
        let library = LibraryStore.shared
        var merged = 0
        for e in list {
            let pausedAt = TraktDate.parse(e.paused_at) ?? Date()
            let fraction = e.progress / 100
            if let m = e.movie {
                let item = mediaItem(type: .movie, title: m.title, year: m.year, ids: m.ids)
                let runtime = m.runtime ?? 0
                let duration = Double(runtime > 0 ? runtime * 60 : 6000)
                library.mergeRemoteProgress(item: item, episode: nil, fraction: fraction, duration: duration, updatedAt: pausedAt)
                merged += 1
            } else if let s = e.show, let ep = e.episode {
                let item = mediaItem(type: .series, title: s.title, year: s.year, ids: s.ids)
                let episode = EpisodeRef(id: "trakt-\(s.ids.trakt ?? 0)-\(ep.season)-\(ep.number)", season: ep.season, episode: ep.number,
                                         title: ep.title ?? "Episode \(ep.number)",
                                         stremioVideoID: s.ids.imdb.map { "\($0):\(ep.season):\(ep.number)" })
                let runtime = ep.runtime ?? s.runtime ?? 0
                let duration = Double(runtime > 0 ? runtime * 60 : 2700)
                library.mergeRemoteProgress(item: item, episode: episode, fraction: fraction, duration: duration, updatedAt: pausedAt)
                merged += 1
            }
        }
        return merged
    }

    /// Builds Up Next from GET /sync/watched/shows + /shows/{id}/progress/watched.
    func refreshUpNext(force: Bool = false) async {
        guard isSignedIn else {
            upNext = []
            return
        }
        if !force, let upNextLoadedAt, Date().timeIntervalSince(upNextLoadedAt) < 1800 { return }
        upNextLoadedAt = Date()
        await refreshTokenIfNeeded()
        let headers = self.headers
        let base = self.base
        let watchedURL = base.appendingRawPath("sync/watched/shows").appendingQuery(["extended": "noseasons"])
        guard let watched = try? await HTTPClient.shared.get(LossyArray<WatchedShow>.self, watchedURL, headers: headers).elements else { return }
        let recent = Array(watched
            .map { ($0, TraktDate.parse($0.last_watched_at) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(25))

        let requests: [(Int, URL)] = recent.enumerated().compactMap { pair in
            let show = pair.element.0.show
            guard let traktID = show.ids.trakt.map({ String($0) }) ?? show.ids.slug else { return nil }
            let url = base.appendingRawPath("shows/\(traktID)/progress/watched")
                .appendingQuery(["hidden": "false", "specials": "false", "extended": "full"])
            return (pair.offset, url)
        }
        var episodes: [Int: ShowProgress.Episode] = [:]
        await withTaskGroup(of: (Int, ShowProgress.Episode?).self) { group in
            var index = 0
            while index < min(4, requests.count) {
                let r = requests[index]
                index += 1
                group.addTask { (r.0, (try? await HTTPClient.shared.get(ShowProgress.self, r.1, headers: headers))?.next_episode) }
            }
            for await (i, ep) in group {
                if let ep { episodes[i] = ep }
                if index < requests.count {
                    let r = requests[index]
                    index += 1
                    group.addTask { (r.0, (try? await HTTPClient.shared.get(ShowProgress.self, r.1, headers: headers))?.next_episode) }
                }
            }
        }
        var entries: [UpNextEntry] = []
        for i in episodes.keys.sorted() {
            guard let ep = episodes[i] else { continue }
            let show = recent[i].0.show
            let item = mediaItem(type: .series, title: show.title, year: show.year, ids: show.ids)
            let episode = EpisodeRef(id: "trakt-\(show.ids.trakt ?? 0)-\(ep.season)-\(ep.number)", season: ep.season,
                                     episode: ep.number, title: ep.title ?? "Episode \(ep.number)", overview: ep.overview,
                                     airDate: ep.first_aired.map { String($0.prefix(10)) },
                                     stremioVideoID: show.ids.imdb.map { "\($0):\(ep.season):\(ep.number)" })
            entries.append(UpNextEntry(item: item, episode: episode, lastWatchedAt: recent[i].1, firstAired: TraktDate.parse(ep.first_aired)))
        }
        upNext = entries
        NewEpisodeTracker.shared.rebuild()
    }

    /// The raw token, for moving the Trakt sign-in to another device.
    var exportedToken: String? { Keychain.get("trakt.token") }

    func importToken(_ raw: String) async {
        guard let data = raw.data(using: .utf8), let t = try? JSONDecoder().decode(Token.self, from: data) else { return }
        token = t
        await loadProfile()
        await refreshWatchlist()
    }
}
