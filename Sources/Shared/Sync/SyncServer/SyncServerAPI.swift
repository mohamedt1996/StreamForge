import Foundation

// Wire types and HTTP client for the self-hosted StreamForge sync server (server/PROTOCOL.md).

// MARK: - JSON

/// Any JSON value. Record `data` is collection specific, so it is kept untyped on the wire.
enum SyncJSON: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SyncJSON])
    case object([String: SyncJSON])

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: Key.self) {
            var out: [String: SyncJSON] = [:]
            for key in c.allKeys {
                out[key.stringValue] = try c.decode(SyncJSON.self, forKey: key)
            }
            self = .object(out)
            return
        }
        if var c = try? decoder.unkeyedContainer() {
            var out: [SyncJSON] = []
            while !c.isAtEnd { out.append(try c.decode(SyncJSON.self)) }
            self = .array(out)
            return
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case .bool(let b):
            var c = encoder.singleValueContainer()
            try c.encode(b)
        case .number(let d):
            var c = encoder.singleValueContainer()
            if d.isFinite, d == d.rounded(), abs(d) < 9_000_000_000_000_000 {
                try c.encode(Int64(d))
            } else if d.isFinite {
                try c.encode(d)
            } else {
                try c.encodeNil()
            }
        case .string(let s):
            var c = encoder.singleValueContainer()
            try c.encode(s)
        case .array(let a):
            var c = encoder.unkeyedContainer()
            for v in a { try c.encode(v) }
        case .object(let o):
            var c = encoder.container(keyedBy: Key.self)
            for (k, v) in o { try c.encode(v, forKey: Key(k)) }
        }
    }

    // Accessors
    subscript(key: String) -> SyncJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var intValue: Int? {
        guard let d = doubleValue, d.isFinite, abs(d) < 9_000_000_000_000_000 else { return nil }
        return Int(d)
    }
    var int64Value: Int64? {
        guard let d = doubleValue, d.isFinite, abs(d) < 9_000_000_000_000_000 else { return nil }
        return Int64(d)
    }
    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0
        default: return nil
        }
    }
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    static func integer(_ i: Int) -> SyncJSON { .number(Double(i)) }

    /// Deterministic text form (sorted keys) used for change fingerprints.
    func canonical(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let d):
            if d.isFinite, d == d.rounded(), abs(d) < 9_000_000_000_000_000 { out += String(Int64(d)) } else { out += String(d) }
        case .string(let s):
            out += "\""
            out += s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            out += "\""
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.canonical(into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, k) in o.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                out += "\"" + k + "\":"
                o[k]?.canonical(into: &out)
            }
            out += "}"
        }
    }

    var canonicalString: String {
        var s = ""
        canonical(into: &s)
        return s
    }
}

// MARK: - Wire models

private extension KeyedDecodingContainer {
    func lenientInt64(_ key: Key) -> Int64? {
        if let v = try? decodeIfPresent(Int64.self, forKey: key) { return v }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int64(d) }
        return nil
    }
}

struct SyncUser: Codable, Hashable, Sendable {
    var id: String
    var username: String
    var role: String
    var disabled: Bool
    var createdAt: Int64

    enum CodingKeys: String, CodingKey { case id, username, role, disabled, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        username = (try? c.decodeIfPresent(String.self, forKey: .username)) ?? ""
        role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? "member"
        disabled = (try? c.decodeIfPresent(Bool.self, forKey: .disabled)) ?? false
        createdAt = c.lenientInt64(.createdAt) ?? 0
    }
}

struct SyncDevice: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var platform: String
    var scopes: [String]
    var createdAt: Int64
    var lastSeenAt: Int64
    var lastIp: String?
    var current: Bool

    enum CodingKeys: String, CodingKey { case id, name, platform, scopes, createdAt, lastSeenAt, lastIp, current }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Device"
        platform = (try? c.decodeIfPresent(String.self, forKey: .platform)) ?? ""
        scopes = (try? c.decodeIfPresent([String].self, forKey: .scopes)) ?? []
        createdAt = c.lenientInt64(.createdAt) ?? 0
        lastSeenAt = c.lenientInt64(.lastSeenAt) ?? 0
        lastIp = try? c.decodeIfPresent(String.self, forKey: .lastIp)
        current = (try? c.decodeIfPresent(Bool.self, forKey: .current)) ?? false
    }

    var lastSeen: Date? { lastSeenAt > 0 ? Date(timeIntervalSince1970: TimeInterval(lastSeenAt) / 1000) : nil }

    var platformIcon: String {
        switch platform {
        case "tvos", "androidtv": return "appletv"
        case "ipados": return "ipad"
        case "android": return "candybarphone"
        case "web": return "globe"
        default: return "iphone"
        }
    }

    var platformLabel: String {
        switch platform {
        case "ios": return "iPhone"
        case "ipados": return "iPad"
        case "tvos": return "Apple TV"
        case "android": return "Android"
        case "androidtv": return "Android TV"
        case "web": return "Web"
        default: return platform
        }
    }
}

struct SyncRecord: Decodable, Sendable {
    var collection: String
    var id: String
    var data: SyncJSON?
    var deleted: Bool
    var updatedAt: Int64
    var rev: Int64
    /// Set up for this user by the server admin (PROTOCOL.md §5).
    var managed: Bool

    enum CodingKeys: String, CodingKey { case collection, id, data, deleted, updatedAt, rev, managed }

    init(collection: String, id: String, data: SyncJSON?, deleted: Bool, updatedAt: Int64, rev: Int64, managed: Bool) {
        self.collection = collection
        self.id = id
        self.data = data
        self.deleted = deleted
        self.updatedAt = updatedAt
        self.rev = rev
        self.managed = managed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = try c.decode(String.self, forKey: .collection)
        id = try c.decode(String.self, forKey: .id)
        let d = try? c.decodeIfPresent(SyncJSON.self, forKey: .data)
        data = (d?.isNull ?? true) ? nil : d
        deleted = (try? c.decodeIfPresent(Bool.self, forKey: .deleted)) ?? false
        updatedAt = c.lenientInt64(.updatedAt) ?? 0
        rev = c.lenientInt64(.rev) ?? 0
        managed = (try? c.decodeIfPresent(Bool.self, forKey: .managed)) ?? false
    }
}

/// One pending local change (also the push wire format).
struct OutboxEntry: Codable, Sendable {
    var collection: String
    var id: String
    var data: SyncJSON?
    var deleted: Bool
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey { case collection, id, data, deleted, updatedAt }

    init(collection: String, id: String, data: SyncJSON?, deleted: Bool, updatedAt: Int64) {
        self.collection = collection
        self.id = id
        self.data = data
        self.deleted = deleted
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collection = try c.decode(String.self, forKey: .collection)
        id = try c.decode(String.self, forKey: .id)
        let d = try? c.decodeIfPresent(SyncJSON.self, forKey: .data)
        data = (d?.isNull ?? true) ? nil : d
        deleted = (try? c.decodeIfPresent(Bool.self, forKey: .deleted)) ?? false
        updatedAt = c.lenientInt64(.updatedAt) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(collection, forKey: .collection)
        try c.encode(id, forKey: .id)
        if let data, !deleted { try c.encode(data, forKey: .data) } else { try c.encodeNil(forKey: .data) }
        try c.encode(deleted, forKey: .deleted)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

struct SyncPullResponse: Decodable, Sendable {
    var rev: Int64
    var records: [SyncRecord]
    var more: Bool

    enum CodingKeys: String, CodingKey { case rev, records, more }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Required: a missing rev must not read as 0, which the client takes for "server was reset".
        rev = try c.decode(Int64.self, forKey: .rev)
        // One malformed record must not hide the rest of the page.
        records = (try? c.decodeIfPresent(LossyArray<SyncRecord>.self, forKey: .records))?.elements ?? []
        more = (try? c.decodeIfPresent(Bool.self, forKey: .more)) ?? false
    }
}

struct SyncPushResponse: Decodable, Sendable {
    struct Result: Decodable, Sendable {
        var collection: String
        var id: String
        var status: String
        var rev: Int64?
    }
    var rev: Int64?
    var results: [Result]
}

struct SyncAuthResponse: Decodable, Sendable {
    var token: String
    var user: SyncUser
    var device: SyncDevice
}

struct SyncPairStart: Decodable, Sendable {
    var pairId: String
    var code: String
    var expiresIn: Int?
}

struct SyncMeResponse: Decodable, Sendable {
    struct Server: Decodable, Sendable { var name: String?; var version: String? }
    var user: SyncUser
    var device: SyncDevice
    var server: Server?
}

// MARK: - Errors

enum SyncServerError: LocalizedError, Sendable {
    case badURL
    case unauthorized(String?)
    case forbidden(String?)
    case rateLimited(TimeInterval)
    case gone
    case status(Int, String?)
    case transport(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .badURL: return "Enter a valid server address, e.g. http://192.168.1.10:8484"
        case .unauthorized(let m): return m ?? "Wrong username or password"
        case .forbidden(let m): return m ?? "This device isn't allowed to do that"
        case .rateLimited: return "Too many requests — try again in a moment"
        case .gone: return "The code expired"
        case .status(let code, let m): return m ?? "The server returned HTTP \(code)"
        case .transport(let m): return m
        case .decoding: return "Unexpected response from the server"
        }
    }
}

// MARK: - Client

/// Stateless HTTP client; every call is independent and safe to run off the main actor.
struct SyncServerAPI: Sendable {
    let base: URL
    let token: String?

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 75
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    /// Accepts "host:port", "http://host:port/" or "https://sync.example.com/sf".
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    private struct ErrorBody: Decodable { var error: String?; var code: String? }

    /// Performs a request and returns (status, body). Throws for transport errors and for
    /// 401/403/429/5xx; other statuses are returned so callers can handle 202/204/410.
    func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
             timeout: TimeInterval = 30) async throws -> (Int, Data) {
        var url = base
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        if !query.isEmpty {
            guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw SyncServerError.badURL }
            comps.queryItems = query
            guard let u = comps.url else { throw SyncServerError.badURL }
            url = u
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("StreamForge/1.0", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw SyncServerError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { return (200, data) }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
        switch http.statusCode {
        case 401: throw SyncServerError.unauthorized(message)
        case 403: throw SyncServerError.forbidden(message)
        case 429:
            let retry = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init) ?? 10
            throw SyncServerError.rateLimited(retry)
        case 500...599: throw SyncServerError.status(http.statusCode, message)
        default: return (http.statusCode, data)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ status: Int, _ data: Data) throws -> T {
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            if status == 410 { throw SyncServerError.gone }
            throw SyncServerError.status(status, message)
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw SyncServerError.decoding }
    }

    private func json(_ object: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: object) }

    private func ensureOK(_ status: Int, _ data: Data) throws {
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            if status == 410 { throw SyncServerError.gone }
            throw SyncServerError.status(status, message)
        }
    }

    // MARK: Auth

    func login(username: String, password: String, deviceName: String, platform: String) async throws -> SyncAuthResponse {
        let body = json(["username": username, "password": password, "device": ["name": deviceName, "platform": platform]])
        let (s, d) = try await raw("POST", "api/auth/login", body: body)
        return try decode(SyncAuthResponse.self, s, d)
    }

    func pairStart(deviceName: String, platform: String) async throws -> SyncPairStart {
        let body = json(["device": ["name": deviceName, "platform": platform]])
        let (s, d) = try await raw("POST", "api/auth/pair/start", body: body)
        return try decode(SyncPairStart.self, s, d)
    }

    enum PairPoll: Sendable {
        case pending
        case approved(SyncAuthResponse)
        case expired
    }

    func pairPoll(_ pairId: String) async throws -> PairPoll {
        let (s, d) = try await raw("GET", "api/auth/pair/\(pairId)", timeout: 15)
        switch s {
        case 202: return .pending
        case 404, 410: return .expired
        case 200..<300:
            struct Status: Decodable { var status: String? }
            if (try? JSONDecoder().decode(Status.self, from: d))?.status == "pending" { return .pending }
            return .approved(try decode(SyncAuthResponse.self, s, d))
        default:
            try ensureOK(s, d)
            return .pending
        }
    }

    func approvePair(code: String, scopes: [String]) async throws -> SyncDevice {
        struct Res: Decodable { var device: SyncDevice }
        let (s, d) = try await raw("POST", "api/pair/approve", body: json(["code": code, "scopes": scopes]))
        if s == 404 || s == 410 { throw SyncServerError.status(s, "That code is wrong or has expired") }
        return try decode(Res.self, s, d).device
    }

    func me() async throws -> SyncMeResponse {
        let (s, d) = try await raw("GET", "api/me")
        return try decode(SyncMeResponse.self, s, d)
    }

    func logout() async throws {
        let (s, d) = try await raw("POST", "api/auth/logout", body: Data("{}".utf8))
        try ensureOK(s, d)
    }

    func changePassword(current: String, new: String) async throws {
        let (s, d) = try await raw("POST", "api/me/password", body: json(["current": current, "new": new]))
        try ensureOK(s, d)
    }

    // MARK: Devices

    func devices() async throws -> [SyncDevice] {
        struct Res: Decodable { var devices: [SyncDevice] }
        let (s, d) = try await raw("GET", "api/devices")
        return try decode(Res.self, s, d).devices
    }

    func updateDevice(_ id: String, name: String?, scopes: [String]?) async throws -> SyncDevice {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let scopes { body["scopes"] = scopes }
        let (s, d) = try await raw("PATCH", "api/devices/\(id)", body: json(body))
        return try decode(SyncDevice.self, s, d)
    }

    func deleteDevice(_ id: String) async throws {
        let (s, d) = try await raw("DELETE", "api/devices/\(id)")
        try ensureOK(s, d)
    }

    // MARK: Sync

    func pull(since: Int64, wait: Int) async throws -> SyncPullResponse {
        let query = [URLQueryItem(name: "since", value: String(since)),
                     URLQueryItem(name: "limit", value: "1000"),
                     URLQueryItem(name: "wait", value: String(wait))]
        let (s, d) = try await raw("GET", "api/sync", query: query, timeout: TimeInterval(wait) + 20)
        return try decode(SyncPullResponse.self, s, d)
    }

    func push(_ records: [OutboxEntry]) async throws -> SyncPushResponse {
        struct Body: Encodable { var records: [OutboxEntry] }
        let body = try JSONEncoder().encode(Body(records: records))
        let (s, d) = try await raw("POST", "api/sync", body: body, timeout: 60)
        return try decode(SyncPushResponse.self, s, d)
    }
}
