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
    private var token: Token? {
        didSet {
            if let token, let data = try? JSONEncoder().encode(token) {
                Keychain.set(String(data: data, encoding: .utf8), for: "trakt.token")
            } else {
                Keychain.set(nil, for: "trakt.token")
            }
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
