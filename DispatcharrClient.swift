import Foundation

/// How the app signs in to a Dispatcharr server.
enum DispatcharrAuthMode: String, Codable, CaseIterable, Identifiable {
    /// Dispatcharr username + web password. The app gets a JWT for the REST API and reads the
    /// user's XC password from /api/accounts/users/me/ (none: REST streaming, see `usesRESTStreaming`).
    case account
    /// A Dispatcharr API key (X-API-Key). The username and XC password (if any) come from /me.
    case apiKey
    /// Username + XC password only (Xtream Codes API). An optional web password unlocks DVR.
    case xc

    var id: String { rawValue }
    var label: String {
        switch self {
        case .account: return "Account login (recommended)"
        case .apiKey: return "API key"
        case .xc: return "XC credentials (advanced)"
        }
    }
    var shortLabel: String {
        switch self {
        case .account: return "Account"
        case .apiKey: return "API key"
        case .xc: return "XC"
        }
    }
}

/// A configured Dispatcharr server. Streaming uses the Xtream Codes API with the user's XC password
/// (Users → edit → XC Password in Dispatcharr) when there is one; account / API-key servers fetch it
/// automatically. Account / API-key users without an XC password stream through Dispatcharr's REST
/// API and stream proxy instead (`usesRESTStreaming`). Secrets live in the Keychain.
struct DispatcharrServer: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var baseURL: String
    var username: String
    var authMode: DispatcharrAuthMode = .xc
    /// Dispatcharr channel profile to show (nil = every channel the account can see).
    var channelProfileID: Int?

    var xcPassword: String {
        get { Keychain.get("dispatcharr.xc.\(id)") ?? "" }
        nonmutating set { Keychain.set(newValue, for: "dispatcharr.xc.\(id)") }
    }
    /// The Dispatcharr web (login) password: account mode, or DVR in XC mode.
    var webPassword: String {
        get { Keychain.get("dispatcharr.web.\(id)") ?? "" }
        nonmutating set { Keychain.set(newValue, for: "dispatcharr.web.\(id)") }
    }
    var apiKey: String {
        get { Keychain.get("dispatcharr.apikey.\(id)") ?? "" }
        nonmutating set { Keychain.set(newValue.trimmed, for: "dispatcharr.apikey.\(id)") }
    }

    var url: URL? { URL.normalizedBase(baseURL) }

    /// Whether the REST API (DVR, profiles, /me) can be used.
    var hasRESTAccess: Bool {
        switch authMode {
        case .apiKey: return !apiKey.isEmpty
        case .account, .xc: return !webPassword.isEmpty && !username.isEmpty
        }
    }

    /// Account / API-key servers whose Dispatcharr user has no XC password: channels, guide and VOD
    /// come from the REST API and playback goes through Dispatcharr's proxy (/proxy/ts, /proxy/vod),
    /// which needs no XC password. Catch-up (XC timeshift) isn't available in this mode.
    var usesRESTStreaming: Bool { authMode != .xc && xcPassword.isEmpty }

    func clearSecrets() {
        DispatcharrUUIDs.shared.remove(server: id)
        xcPassword = ""
        webPassword = ""
        apiKey = ""
    }

    enum CodingKeys: String, CodingKey { case id, name, baseURL, username, authMode, channelProfileID }
}

extension DispatcharrServer {
    // In an extension so the memberwise initializer stays available.
    // Servers saved by 1.0 have no authMode: they keep working as XC servers (with DVR if a web
    // password was saved), exactly as before.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        baseURL = (try? c.decodeIfPresent(String.self, forKey: .baseURL)) ?? ""
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        authMode = (try? c.decodeIfPresent(DispatcharrAuthMode.self, forKey: .authMode)) ?? .xc
        channelProfileID = try? c.decodeIfPresent(Int.self, forKey: .channelProfileID)
    }
}

/// Client for Dispatcharr's Xtream Codes API: live channels, EPG, movies, series, catch-up.
/// For servers in REST streaming mode (no XC password) every call is answered from the REST API
/// instead, in the same XC models, so the rest of the app doesn't need to know the difference.
struct XtreamClient {
    let server: DispatcharrServer
    /// Needed for REST streaming mode (shared, so JWT refreshes are shared too).
    let rest: DispatcharrREST?
    private let http = HTTPClient.shared

    init(server: DispatcharrServer, rest: DispatcharrREST? = nil) {
        self.server = server
        self.rest = rest
    }

    /// Non-nil when this server streams without an XC password.
    private var catalog: DispatcharrRESTCatalog? {
        guard server.usesRESTStreaming else { return nil }
        return DispatcharrRESTCatalog(server: server, rest: rest ?? DispatcharrREST(server: server))
    }

    private var base: URL {
        get throws {
            guard let u = server.url else { throw HTTPError.badURL(server.baseURL) }
            return u
        }
    }

    private func api(_ action: String?, _ params: [String: String?] = [:]) throws -> URL {
        var q: [String: String?] = ["username": server.username, "password": server.xcPassword]
        if let action { q["action"] = action }
        for (k, v) in params { q[k] = v }
        return try base.appendingRawPath("player_api.php").appendingQuery(q)
    }

    // MARK: Account

    func authenticate() async throws -> XCAuthResponse {
        let res = try await http.get(XCAuthResponse.self, try api(nil), timeout: 15)
        guard res.userInfo?.auth == true else { throw HTTPError.unauthorized }
        return res
    }

    // MARK: Live

    func liveCategories() async throws -> [XCCategory] {
        if let catalog { return try await catalog.liveCategories() }
        return try await http.get(LossyArray<XCCategory>.self, try api("get_live_categories")).elements
    }

    func liveChannels(categoryID: String? = nil) async throws -> [XCChannel] {
        if let catalog {
            let all = try await catalog.liveChannels()
            return categoryID.map { id in all.filter { $0.categoryID == id } } ?? all
        }
        return try await http.get(LossyArray<XCChannel>.self, try api("get_live_streams", ["category_id": categoryID]), timeout: 120).elements
    }

    func shortEPG(channelID: Int, limit: Int = 8) async throws -> [XCEPGListing] {
        if let catalog { return try await catalog.programmes(channelID: channelID, limit: limit, includePast: false) }
        return try await http.get(XCEPGResponse.self, try api("get_short_epg", ["stream_id": String(channelID), "limit": String(limit)])).listings
    }

    /// Full programme table for one channel, including past programmes with catch-up flags.
    func fullEPG(channelID: Int) async throws -> [XCEPGListing] {
        if let catalog { return try await catalog.programmes(channelID: channelID, limit: 200, includePast: true) }
        return try await http.get(XCEPGResponse.self, try api("get_simple_data_table", ["stream_id": String(channelID)]), timeout: 60).listings
    }

    // MARK: VOD

    func vodCategories() async throws -> [XCCategory] {
        if let catalog { return try await catalog.vodLibrary().movieCategories }
        return try await http.get(LossyArray<XCCategory>.self, try api("get_vod_categories")).elements
    }

    func movies(categoryID: String? = nil) async throws -> [XCMovie] {
        if let catalog {
            let all = try await catalog.vodLibrary().movies
            return categoryID.map { id in all.filter { $0.categoryID == id } } ?? all
        }
        return try await http.get(LossyArray<XCMovie>.self, try api("get_vod_streams", ["category_id": categoryID]), timeout: 180).elements
    }

    func movieInfo(_ id: Int) async throws -> XCVODInfo {
        if let catalog { return try await catalog.movieInfo(id) }
        return try await http.get(XCVODInfo.self, try api("get_vod_info", ["vod_id": String(id)]))
    }

    func seriesCategories() async throws -> [XCCategory] {
        if let catalog { return try await catalog.vodLibrary().seriesCategories }
        return try await http.get(LossyArray<XCCategory>.self, try api("get_series_categories")).elements
    }

    func series(categoryID: String? = nil) async throws -> [XCSeries] {
        if let catalog {
            let all = try await catalog.vodLibrary().series
            return categoryID.map { id in all.filter { $0.categoryID == id } } ?? all
        }
        return try await http.get(LossyArray<XCSeries>.self, try api("get_series", ["category_id": categoryID]), timeout: 180).elements
    }

    func seriesInfo(_ id: Int) async throws -> XCSeriesInfo {
        if let catalog { return try await catalog.seriesInfo(id) }
        return try await http.get(XCSeriesInfo.self, try api("get_series_info", ["series_id": String(id)]))
    }

    // MARK: Guide

    /// Dispatcharr's XMLTV export for this XC user. `days` / `prev_days` are honoured by Dispatcharr
    /// (capped server-side at 365 / 30). In REST streaming mode it's the public /output/epg export
    /// (no credentials; Dispatcharr only checks its "M3U / EPG" network access setting), whose
    /// channel ids are the channel numbers, as in the XC export.
    func xmltvURL(days: Int, prevDays: Int) throws -> URL {
        if server.usesRESTStreaming {
            var q: [String: String?] = ["days": String(max(1, days))]
            if prevDays > 0 { q["prev_days"] = String(prevDays) }
            return try base.appendingRawPath("output/epg").appendingQuery(q)
        }
        var q: [String: String?] = ["username": server.username, "password": server.xcPassword, "days": String(max(1, days))]
        if prevDays > 0 { q["prev_days"] = String(prevDays) }
        return try base.appendingRawPath("xmltv.php").appendingQuery(q)
    }

    // MARK: Playback URLs

    /// REST streaming mode: makes sure the UUIDs behind these ids are known, so `movieURL` /
    /// `episodeURL` can build proxy URLs. A no-op for XC servers.
    func preparePlayback(movieID: Int? = nil, episodeID: Int? = nil) async {
        guard let catalog else { return }
        await catalog.resolveUUIDs(movieID: movieID, episodeID: episodeID)
    }

    private func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
    }

    // REST streaming mode plays through Dispatcharr's proxy, addressed by UUID. Those endpoints are
    // open (AllowAny; only the "Streams" network access setting applies), so no auth header is sent:
    // an expired JWT on a reconnect would otherwise get the stream rejected.

    func liveURL(_ channelID: Int) -> URL? {
        if server.usesRESTStreaming {
            guard let uuid = DispatcharrUUIDs.shared.uuid(.channel, channelID, server: server.id) else { return nil }
            return server.url?.appendingRawPath("proxy/ts/stream/\(uuid)")
        }
        return server.url?.appendingRawPath("live/\(esc(server.username))/\(esc(server.xcPassword))/\(channelID)")
    }

    func movieURL(_ streamID: Int, ext: String) -> URL? {
        if server.usesRESTStreaming {
            guard let uuid = DispatcharrUUIDs.shared.uuid(.movie, streamID, server: server.id) else { return nil }
            return server.url?.appendingRawPath("proxy/vod/movie/\(uuid)")
        }
        return server.url?.appendingRawPath("movie/\(esc(server.username))/\(esc(server.xcPassword))/\(streamID).\(ext)")
    }

    func episodeURL(_ episodeID: Int, ext: String) -> URL? {
        if server.usesRESTStreaming {
            guard let uuid = DispatcharrUUIDs.shared.uuid(.episode, episodeID, server: server.id) else { return nil }
            return server.url?.appendingRawPath("proxy/vod/episode/\(uuid)")
        }
        return server.url?.appendingRawPath("series/\(esc(server.username))/\(esc(server.xcPassword))/\(episodeID).\(ext)")
    }

    /// Catch-up (timeshift) URL. Dispatcharr expects the programme start in UTC as YYYY-MM-DD:HH-MM
    /// and the duration in minutes. Not available in REST streaming mode (it's an XC endpoint).
    func catchupURL(channelID: Int, start: Date, end: Date) -> URL? {
        if server.usesRESTStreaming { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd:HH-mm"
        let minutes = max(1, Int(ceil(end.timeIntervalSince(start) / 60)))
        return server.url?.appendingRawPath(
            "timeshift/\(esc(server.username))/\(esc(server.xcPassword))/\(minutes)/\(f.string(from: start))/\(channelID).ts")
    }
}

// MARK: - REST API (JWT) for DVR

struct DispatcharrRecording: Decodable, Identifiable, Hashable {
    var id: Int
    var channelID: Int?
    var start: Date
    var end: Date
    var title: String
    var description: String?
    var status: String?
    var poster: URL?

    enum CodingKeys: String, CodingKey { case id, channel, start_time, end_time, custom_properties }
    enum PropKeys: String, CodingKey { case program, status, poster_url, poster }
    enum ProgramKeys: String, CodingKey { case title, description, sub_title }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.id) ?? 0
        channelID = c.flexInt(.channel)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        func parse(_ s: String?) -> Date? { s.flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) } }
        start = parse(c.flexString(.start_time)) ?? .distantPast
        end = parse(c.flexString(.end_time)) ?? .distantPast
        var t = "Recording"
        if let props = try? c.nestedContainer(keyedBy: PropKeys.self, forKey: .custom_properties) {
            status = props.flexString(.status)
            poster = props.flexURL(.poster_url) ?? props.flexURL(.poster)
            if let p = try? props.nestedContainer(keyedBy: ProgramKeys.self, forKey: .program) {
                t = p.flexString(.title) ?? t
                if let sub = p.flexString(.sub_title) { t += " – \(sub)" }
                description = p.flexString(.description)
            }
        }
        title = t
    }

    var isUpcoming: Bool { start > Date() }
    var isRecording: Bool { let n = Date(); return start <= n && n < end }
}

/// The Dispatcharr user returned by /api/accounts/users/me/.
struct DispatcharrUser: Hashable {
    var id: Int?
    var username: String
    var xcPassword: String?
    var epgDays: Int?
    var userLevel: Int?
    var channelProfileIDs: [Int]
    /// Whether the response carried `custom_properties` (so a missing xc_password really means none).
    var hasCustomProperties = false

    /// Parsed with JSONSerialization because `custom_properties` is free-form JSON (sometimes
    /// even a JSON string).
    static func parse(_ data: Data) throws -> DispatcharrUser {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw HTTPError.decoding("users/me: not a JSON object")
        }
        var props = obj["custom_properties"] as? [String: Any]
        if props == nil, let raw = obj["custom_properties"] as? String, let d = raw.data(using: .utf8) {
            props = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        let profiles = (obj["channel_profiles"] as? [Any] ?? []).compactMap { JSONValue.int($0) ?? JSONValue.int(($0 as? [String: Any])?["id"]) }
        return DispatcharrUser(
            id: JSONValue.int(obj["id"]),
            username: JSONValue.string(obj["username"]) ?? "",
            xcPassword: JSONValue.string(props?["xc_password"]),
            epgDays: JSONValue.int(props?["epg_days"]),
            userLevel: JSONValue.int(obj["user_level"]),
            channelProfileIDs: profiles,
            hasCustomProperties: props != nil)
    }
}

/// A Dispatcharr channel profile. `channelIDs` is nil when the API response didn't expose
/// membership in a shape we understand (then no client-side filtering happens).
struct DispatcharrChannelProfile: Hashable, Identifiable {
    var id: Int
    var name: String
    var channelIDs: Set<Int>?

    static func parseList(_ data: Data) -> [DispatcharrChannelProfile] {
        let root = (try? JSONSerialization.jsonObject(with: data))
        let items: [[String: Any]]
        if let list = root as? [[String: Any]] {
            items = list
        } else if let page = root as? [String: Any], let list = page["results"] as? [[String: Any]] {
            items = list
        } else {
            return []
        }
        return items.compactMap { obj in
            guard let id = JSONValue.int(obj["id"]) else { return nil }
            let name = JSONValue.string(obj["name"]) ?? "Profile \(id)"
            var ids: Set<Int>?
            if let channels = obj["channels"] as? [Any] {
                var set = Set<Int>()
                var understood = true
                for entry in channels {
                    if let n = JSONValue.int(entry) {
                        set.insert(n)
                    } else if let d = entry as? [String: Any] {
                        if let enabled = d["enabled"] as? Bool, !enabled { continue }
                        if let n = JSONValue.int(d["channel_id"]) ?? JSONValue.int(d["channel"]) ?? JSONValue.int(d["id"]) {
                            set.insert(n)
                        } else {
                            understood = false
                        }
                    } else {
                        understood = false
                    }
                }
                ids = understood ? set : nil
            }
            return DispatcharrChannelProfile(id: id, name: name, channelIDs: ids)
        }
    }
}

/// Loose JSON value helpers for JSONSerialization output.
enum JSONValue {
    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s.trimmed) }
        return nil
    }
}

/// Dispatcharr REST API client. Authenticates with an API key (X-API-Key) or with the web
/// password (JWT access token, refreshed automatically). Used for DVR, /me and channel profiles.
actor DispatcharrREST {
    let server: DispatcharrServer
    private var access: String?
    private var refresh: String?
    private let http = HTTPClient.shared

    init(server: DispatcharrServer) { self.server = server }

    private struct TokenPair: Decodable { var access: String; var refresh: String? }

    private func base() throws -> URL {
        guard let u = server.url else { throw HTTPError.badURL(server.baseURL) }
        return u
    }

    private var usesAPIKey: Bool { server.authMode == .apiKey }

    /// Gets a JWT pair with the username + web password. A no-op for API-key servers.
    func login() async throws {
        if usesAPIKey {
            guard !server.apiKey.isEmpty else { throw HTTPError.transport("No API key saved for this server.") }
            return
        }
        guard !server.webPassword.isEmpty else {
            throw HTTPError.transport("Add your Dispatcharr password in Settings → Dispatcharr.")
        }
        let body = ["username": server.username, "password": server.webPassword]
        let pair = try await http.send(TokenPair.self, try base().appendingRawPath("api/accounts/token/"), body: body)
        access = pair.access
        if let r = pair.refresh { refresh = r }
    }

    private func authorized() async throws -> [String: String] {
        if usesAPIKey { return ["X-API-Key": server.apiKey] }
        if access == nil { try await login() }
        return ["Authorization": "Bearer \(access ?? "")"]
    }

    /// Exchanges the refresh token for a new access token; falls back to a full login.
    private func renew() async {
        access = nil
        guard !usesAPIKey else { return }
        if let refresh,
           let pair = try? await http.send(TokenPair.self, try base().appendingRawPath("api/accounts/token/refresh/"), body: ["refresh": refresh]) {
            access = pair.access
            if let r = pair.refresh { self.refresh = r }
        }
    }

    private func withAuth<T>(_ work: ([String: String]) async throws -> T) async throws -> T {
        do {
            return try await work(try await authorized())
        } catch HTTPError.unauthorized {
            if usesAPIKey { throw HTTPError.transport("Dispatcharr rejected the API key.") }
            await renew()
            return try await work(try await authorized())
        }
    }

    // MARK: Account

    func me() async throws -> DispatcharrUser {
        let data = try await withAuth { headers in
            try await http.data(try base().appendingRawPath("api/accounts/users/me/"), headers: headers)
        }
        return try DispatcharrUser.parse(data)
    }

    /// Authenticated GET on any REST path (used by REST streaming mode).
    func get(_ path: String, query: [String: String?] = [:], timeout: TimeInterval? = nil) async throws -> Data {
        try await withAuth { headers in
            try await http.data(try base().appendingRawPath(path).appendingQuery(query), headers: headers, timeout: timeout)
        }
    }

    /// Sets the XC password of a Dispatcharr user. Only admins may do this: Dispatcharr's
    /// PATCH /api/accounts/users/{id}/ requires IsAdmin, and /users/me/ strips `xc_password` for
    /// everyone. Dispatcharr merges `custom_properties` on update, so other properties are kept.
    func setXCPassword(userID: Int, password: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["custom_properties": ["xc_password": password]])
        _ = try await withAuth { headers in
            try await http.data(try base().appendingRawPath("api/accounts/users/\(userID)/"), method: "PATCH", headers: headers, body: body)
        }
    }

    /// For admins whose user has no XC password: generates a strong one, saves it in Dispatcharr and
    /// returns it. Returns nil for other users or when Dispatcharr refuses.
    func createXCPasswordIfAllowed(for me: DispatcharrUser) async -> String? {
        guard (me.userLevel ?? 0) >= 10, let userID = me.id else { return nil }
        let password = Self.generateXCPassword()
        do {
            try await setXCPassword(userID: userID, password: password)
            // Read it back: only trust it once Dispatcharr actually stored it.
            let check = try await self.me()
            return check.xcPassword == password ? password : nil
        } catch {
            return nil
        }
    }

    /// 20 characters from Dispatcharr's allowed XC password set (^[A-Za-z0-9._@-]+$), using the
    /// system CSPRNG.
    static func generateXCPassword(length: Int = 20) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int(rng.next(upperBound: UInt64(alphabet.count)))] })
    }

    func channelProfiles() async throws -> [DispatcharrChannelProfile] {
        let data = try await withAuth { headers in
            try await http.data(try base().appendingRawPath("api/channels/profiles/"), headers: headers)
        }
        return DispatcharrChannelProfile.parseList(data)
    }

    var playbackHeaders: [String: String] {
        get async { (try? await authorized()) ?? [:] }
    }

    func recordings() async throws -> [DispatcharrRecording] {
        try await withAuth { headers in
            let data = try await http.data(try base().appendingRawPath("api/channels/recordings/"), headers: headers)
            if let list = try? JSONDecoder().decode(LossyArray<DispatcharrRecording>.self, from: data) {
                return list.elements
            }
            struct Page: Decodable { var results: LossyArray<DispatcharrRecording> }
            return try JSONDecoder().decode(Page.self, from: data).results.elements
        }
        .sorted { $0.start > $1.start }
    }

    func scheduleRecording(channelID: Int, programme: XCEPGListing) async throws {
        struct Program: Encodable { var title: String; var description: String }
        struct Props: Encodable { var program: Program }
        struct Body: Encodable { var channel: Int; var start_time: String; var end_time: String; var custom_properties: Props }
        let iso = ISO8601DateFormatter()
        let body = Body(
            channel: channelID,
            start_time: iso.string(from: programme.start),
            end_time: iso.string(from: programme.end),
            custom_properties: Props(program: Program(title: programme.title, description: programme.description)))
        _ = try await withAuth { headers in
            try await http.data(try base().appendingRawPath("api/channels/recordings/"), method: "POST", headers: headers,
                                body: try JSONEncoder().encode(body))
        }
    }

    func deleteRecording(_ id: Int) async throws {
        _ = try await withAuth { headers in
            try await http.data(try base().appendingRawPath("api/channels/recordings/\(id)/"), method: "DELETE", headers: headers)
        }
    }

    func recordingURL(_ id: Int) throws -> URL {
        try base().appendingRawPath("api/channels/recordings/\(id)/file/")
    }
}
