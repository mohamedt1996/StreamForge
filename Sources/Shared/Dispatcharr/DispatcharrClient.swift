import Foundation

/// A configured Dispatcharr server. The XC password is the per-user "XC password" set in
/// Dispatcharr (Users → edit → XC password). The web password is optional and unlocks DVR.
struct DispatcharrServer: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var baseURL: String
    var username: String

    var xcPassword: String {
        get { Keychain.get("dispatcharr.xc.\(id)") ?? "" }
        nonmutating set { Keychain.set(newValue, for: "dispatcharr.xc.\(id)") }
    }
    var webPassword: String {
        get { Keychain.get("dispatcharr.web.\(id)") ?? "" }
        nonmutating set { Keychain.set(newValue, for: "dispatcharr.web.\(id)") }
    }

    var url: URL? { URL.normalizedBase(baseURL) }

    enum CodingKeys: String, CodingKey { case id, name, baseURL, username }
}

/// Client for Dispatcharr's Xtream Codes API: live channels, EPG, movies, series, catch-up.
struct XtreamClient {
    let server: DispatcharrServer
    private let http = HTTPClient.shared

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
        try await http.get(LossyArray<XCCategory>.self, try api("get_live_categories")).elements
    }

    func liveChannels(categoryID: String? = nil) async throws -> [XCChannel] {
        try await http.get(LossyArray<XCChannel>.self, try api("get_live_streams", ["category_id": categoryID]), timeout: 120).elements
    }

    func shortEPG(channelID: Int, limit: Int = 8) async throws -> [XCEPGListing] {
        try await http.get(XCEPGResponse.self, try api("get_short_epg", ["stream_id": String(channelID), "limit": String(limit)])).listings
    }

    /// Full programme table for one channel, including past programmes with catch-up flags.
    func fullEPG(channelID: Int) async throws -> [XCEPGListing] {
        try await http.get(XCEPGResponse.self, try api("get_simple_data_table", ["stream_id": String(channelID)]), timeout: 60).listings
    }

    // MARK: VOD

    func vodCategories() async throws -> [XCCategory] {
        try await http.get(LossyArray<XCCategory>.self, try api("get_vod_categories")).elements
    }

    func movies(categoryID: String? = nil) async throws -> [XCMovie] {
        try await http.get(LossyArray<XCMovie>.self, try api("get_vod_streams", ["category_id": categoryID]), timeout: 180).elements
    }

    func movieInfo(_ id: Int) async throws -> XCVODInfo {
        try await http.get(XCVODInfo.self, try api("get_vod_info", ["vod_id": String(id)]))
    }

    func seriesCategories() async throws -> [XCCategory] {
        try await http.get(LossyArray<XCCategory>.self, try api("get_series_categories")).elements
    }

    func series(categoryID: String? = nil) async throws -> [XCSeries] {
        try await http.get(LossyArray<XCSeries>.self, try api("get_series", ["category_id": categoryID]), timeout: 180).elements
    }

    func seriesInfo(_ id: Int) async throws -> XCSeriesInfo {
        try await http.get(XCSeriesInfo.self, try api("get_series_info", ["series_id": String(id)]))
    }

    // MARK: Playback URLs

    private func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
    }

    func liveURL(_ channelID: Int) -> URL? {
        server.url?.appendingRawPath("live/\(esc(server.username))/\(esc(server.xcPassword))/\(channelID)")
    }

    func movieURL(_ streamID: Int, ext: String) -> URL? {
        server.url?.appendingRawPath("movie/\(esc(server.username))/\(esc(server.xcPassword))/\(streamID).\(ext)")
    }

    func episodeURL(_ episodeID: Int, ext: String) -> URL? {
        server.url?.appendingRawPath("series/\(esc(server.username))/\(esc(server.xcPassword))/\(episodeID).\(ext)")
    }

    /// Catch-up (timeshift) URL. Dispatcharr expects the programme start in UTC as YYYY-MM-DD:HH-MM
    /// and the duration in minutes.
    func catchupURL(channelID: Int, start: Date, end: Date) -> URL? {
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

/// Optional REST client: logs in with the web password and manages DVR recordings.
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

    func login() async throws {
        let body = ["username": server.username, "password": server.webPassword]
        let pair = try await http.send(TokenPair.self, try base().appendingRawPath("api/accounts/token/"), body: body)
        access = pair.access
        refresh = pair.refresh
    }

    private func authorized() async throws -> [String: String] {
        if access == nil { try await login() }
        return ["Authorization": "Bearer \(access ?? "")"]
    }

    private func withAuth<T>(_ work: ([String: String]) async throws -> T) async throws -> T {
        do {
            return try await work(try await authorized())
        } catch HTTPError.unauthorized {
            access = nil
            if let refresh {
                if let pair = try? await http.send(TokenPair.self, try base().appendingRawPath("api/accounts/token/refresh/"), body: ["refresh": refresh]) {
                    access = pair.access
                }
            }
            return try await work(try await authorized())
        }
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
